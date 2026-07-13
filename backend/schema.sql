-- ============================================================================
-- STOCK360 — SCHEMA DE BANCO (Supabase / PostgreSQL)
-- ============================================================================
-- PRINCÍPIO CENTRAL: duas fontes de verdade diferentes.
--
--   • QUANTIDADE (saldo)  → o Protheus é o mestre. As tabelas abaixo marcadas
--     como "CACHE" nunca devem ser editadas manualmente nem pelo Stock360 —
--     só a função de sincronização (sync-saldo-protheus) escreve nelas.
--
--   • ENDEREÇO             → o Supabase é o mestre, porque o Protheus ainda
--     não tem esse cadastro. Aqui o Stock360 cria e mantém o dado de verdade.
--
-- Rode este arquivo com: supabase db push  (ou cole no SQL Editor do painel)
-- ============================================================================

create extension if not exists pgcrypto; -- para gen_random_uuid()

-- ---------------------------------------------------------------------------
-- USUÁRIOS
-- ---------------------------------------------------------------------------
create table usuarios (
  id uuid primary key default gen_random_uuid(),
  nome text not null,
  usuario text unique not null,
  email text,
  perfil text not null check (perfil in ('operador','lider','admin')),
  status text not null default 'ativo' check (status in ('ativo','bloqueado','deve_definir_senha')),
  criado_em timestamptz not null default now()
);
-- Senha em si fica no Supabase Auth (auth.users), não nesta tabela — esta
-- tabela guarda só os dados de perfil/permissão do Stock360.

-- ---------------------------------------------------------------------------
-- CATÁLOGO — espelho do cadastro de produto do Protheus (SB1).
-- Muda pouco: sincronizar 1x por dia é suficiente.
-- [CACHE — não editar manualmente]
-- ---------------------------------------------------------------------------
create table produtos (
  codigo text primary key,
  descricao text not null,
  unidade text,
  grupo text,
  custo_unitario numeric(14,4),
  sincronizado_em timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- SALDO — espelho do saldo em estoque do Protheus (SB2).
-- Muda o tempo todo (toda entrada/saída de estoque). É um CACHE por design:
-- o Stock360 nunca é a fonte de verdade da quantidade, só reflete o Protheus.
-- [CACHE — não editar manualmente]
-- ---------------------------------------------------------------------------
create table estoque_saldo (
  produto_codigo text not null references produtos(codigo),
  almoxarifado text not null,
  saldo numeric(14,3) not null,
  valor_financeiro numeric(14,2),
  data_ultima_saida date,
  sincronizado_em timestamptz not null default now(),
  primary key (produto_codigo, almoxarifado)
);
create index idx_estoque_saldo_almox on estoque_saldo(almoxarifado);

-- Log de cada rodada de sincronização — auditoria e depuração.
create table sync_log (
  id uuid primary key default gen_random_uuid(),
  origem text not null,              -- 'protheus_saldo' | 'protheus_produtos'
  status text not null default 'em_andamento', -- 'em_andamento' | 'sucesso' | 'erro'
  itens_processados int,
  erro text,
  iniciado_em timestamptz not null default now(),
  concluido_em timestamptz
);

-- ---------------------------------------------------------------------------
-- ENDEREÇOS — cadastro próprio do Stock360 (Protheus não tem isso ainda).
-- [MESTRE — o Stock360 é dono deste dado]
-- ---------------------------------------------------------------------------
create table enderecos (
  id uuid primary key default gen_random_uuid(),
  almoxarifado text not null,
  codigo text unique not null,        -- ex: A-03-02-04
  corredor text,
  rua text,
  prateleira text,
  nivel text,
  qr_code text unique,
  criado_por uuid references usuarios(id),
  criado_em timestamptz not null default now()
);

create table estoque_enderecos (
  produto_codigo text not null references produtos(codigo),
  endereco_id uuid not null references enderecos(id),
  saldo_no_endereco numeric(14,3) not null default 0,
  primary key (produto_codigo, endereco_id)
);

-- Fila de endereços informados por operadores durante a contagem, aguardando
-- confirmação do líder — é a versão persistida do que hoje roda só em
-- memória no protótipo (painel "Endereços Pendentes de Cadastro").
create table endereco_propostas (
  id uuid primary key default gen_random_uuid(),
  produto_codigo text not null references produtos(codigo),
  endereco_informado text not null,
  usuario_id uuid not null references usuarios(id),
  status text not null default 'pendente' check (status in ('pendente','confirmado','rejeitado')),
  criado_em timestamptz not null default now(),
  resolvido_por uuid references usuarios(id),
  resolvido_em timestamptz
);

-- ---------------------------------------------------------------------------
-- INVENTÁRIOS + SNAPSHOT DE SALDO
--
-- Ao criar um inventário, o saldo de cada item do almoxarifado é COPIADO
-- (congelado) para inventario_itens. A contagem cega compara contra essa
-- foto, nunca contra estoque_saldo "ao vivo" — assim uma movimentação no
-- Protheus no meio da janela de contagem não muda o alvo debaixo do
-- operador.
-- ---------------------------------------------------------------------------
create table inventarios (
  id uuid primary key default gen_random_uuid(),
  nome text not null,
  almoxarifado text not null,
  responsavel_id uuid references usuarios(id),
  data date not null,
  tipo text not null check (tipo in ('aleatoria','curva_abc','manual','rota_endereco')),
  status text not null default 'pendente' check (status in ('pendente','em_andamento','concluido')),
  criado_em timestamptz not null default now()
);

create table inventario_itens (
  id uuid primary key default gen_random_uuid(),
  inventario_id uuid not null references inventarios(id),
  produto_codigo text not null references produtos(codigo),
  endereco_id uuid references enderecos(id),   -- null se o item ainda não tem endereço cadastrado
  saldo_congelado numeric(14,3) not null,       -- cópia de estoque_saldo.saldo no momento da criação
  congelado_em timestamptz not null default now()
);
create index idx_inventario_itens_inv on inventario_itens(inventario_id);

-- Função que congela o saldo ao criar um inventário — chame isso logo depois
-- de inserir a linha em `inventarios`.
create or replace function congelar_saldo_inventario(p_inventario_id uuid)
returns int as $$
declare
  v_almoxarifado text;
  v_qtd int;
begin
  select almoxarifado into v_almoxarifado from inventarios where id = p_inventario_id;

  insert into inventario_itens (inventario_id, produto_codigo, saldo_congelado)
  select p_inventario_id, es.produto_codigo, es.saldo
  from estoque_saldo es
  where es.almoxarifado = v_almoxarifado;

  get diagnostics v_qtd = row_count;
  return v_qtd; -- quantidade de itens congelados
end;
$$ language plpgsql;

-- ---------------------------------------------------------------------------
-- CONTAGENS — histórico completo, nunca sobrescrito. Cada rodada (1ª, 2ª...)
-- é uma linha nova, encadeada por contagem_anterior_id.
-- ---------------------------------------------------------------------------
create table contagens (
  id uuid primary key default gen_random_uuid(),
  inventario_id uuid references inventarios(id),
  produto_codigo text not null references produtos(codigo),
  endereco_texto text,                    -- endereço confirmado por QR OU informado manualmente
  usuario_id uuid not null references usuarios(id),
  numero_contagem int not null default 1,
  contagem_anterior_id uuid references contagens(id),
  quantidade numeric(14,3) not null,
  saldo_sistema numeric(14,3) not null,   -- vem de inventario_itens.saldo_congelado, NUNCA de estoque_saldo direto
  diferenca numeric(14,3) generated always as (quantidade - saldo_sistema) stored,
  status_aprovacao text not null,          -- aprovado_auto | aguardando_segunda | aguardando_analise_lider | aprovado_lider
  motivo text,
  foto_url text,
  observacao text,
  aprovado_por uuid references usuarios(id),
  aprovado_em timestamptz,
  criado_em timestamptz not null default now()
);
create index idx_contagens_inventario on contagens(inventario_id);
create index idx_contagens_produto on contagens(produto_codigo);

-- ---------------------------------------------------------------------------
-- RLS (Row Level Security) — esboço. Ajuste conforme o modelo de auth real.
-- ---------------------------------------------------------------------------
alter table estoque_saldo enable row level security;
alter table enderecos enable row level security;
alter table contagens enable row level security;

-- Leitura liberada para qualquer usuário autenticado do Stock360:
create policy "leitura autenticada" on estoque_saldo for select using (auth.role() = 'authenticated');
create policy "leitura autenticada" on enderecos for select using (auth.role() = 'authenticated');
create policy "leitura autenticada" on contagens for select using (auth.role() = 'authenticated');

-- Escrita em estoque_saldo SÓ pela service role (usada pela Edge Function de
-- sincronização) — nenhum usuário do app escreve aqui diretamente.
create policy "escrita só service role" on estoque_saldo for all
  using (auth.role() = 'service_role') with check (auth.role() = 'service_role');
