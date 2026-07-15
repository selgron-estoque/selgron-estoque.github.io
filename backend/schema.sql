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
--
-- Sem sync automática com o Protheus ainda (a Edge Function
-- sync-saldo-protheus continua só desenhada, não aplicada — ver
-- backend/README.md). Enquanto isso, o admin sobe a planilha SB2 manualmente
-- pelo app (painel "Atualizar Saldo em Estoque" em Configurações) sempre que
-- precisar atualizar — tipicamente todo dia. Cada upload faz um REPLACE
-- completo da tabela (apaga tudo, insere de novo com o snapshot da planilha),
-- não um upsert incremental — mais simples e evita linha órfã de produto que
-- saiu do almoxarifado ou zerou.
--
-- Sem FK pra produtos(codigo) de propósito: a planilha SB2 de saldo é um
-- export separado do catálogo (produtos), e um código com formatação
-- ligeiramente diferente entre os dois exports não pode travar o upload
-- inteiro — mesma razão já documentada pra contagens/inventarios.
-- ---------------------------------------------------------------------------
create table estoque_saldo (
  produto_codigo text not null,
  almoxarifado text not null,
  saldo numeric(14,3) not null,
  valor_financeiro numeric(14,2),
  data_ultima_saida date,
  sincronizado_em timestamptz not null default now(),
  primary key (produto_codigo, almoxarifado)
);
create index idx_estoque_saldo_almox on estoque_saldo(almoxarifado);

-- Soma valor/saldo por armazém — usado pelos cards de "Valor em Estoque" no
-- Dashboard, evita trazer as 12 mil+ linhas pro navegador só pra somar.
create or replace function estoque_valor_por_almoxarifado()
returns table(almoxarifado text, valor_total numeric, saldo_total numeric, itens bigint) as $$
  select almoxarifado, sum(valor_financeiro), sum(saldo), count(*)
  from estoque_saldo
  group by almoxarifado
  order by almoxarifado;
$$ language sql stable;

-- Resumo geral pros mini-cards do Dashboard (armazéns ativos, itens
-- distintos, % do catálogo com saldo carregado). "Cobertura" compara contra
-- o total de `produtos` (catálogo, 85 mil+ códigos) — mostra honestamente
-- que só uma fração do catálogo tem saldo importado até agora, não inventa
-- um número. Não inclui tendência/comparação com período anterior: cada
-- upload da SB2 SUBSTITUI o snapshot anterior (ver replaceEstoqueSaldoInSupabase),
-- não existe histórico guardado pra calcular "vs. mês passado" de verdade.
create or replace function estoque_resumo_geral()
returns table(armazens_ativos bigint, itens_distintos bigint, cobertura_pct numeric) as $$
  select
    (select count(distinct almoxarifado) from estoque_saldo),
    (select count(distinct produto_codigo) from estoque_saldo),
    (select round(100.0 * count(distinct produto_codigo) / nullif((select count(*) from produtos), 0), 1) from estoque_saldo);
$$ language sql stable;

-- Gera a lista priorizada de itens pra contagem "Aleatória"/"Curva ABC" e
-- "Rota de Endereço" — substitui o cache local estático de 300 SKUs que o
-- app usava antes (RAW_SB2_PRODUCTS/PRODUCTS, removido do index.html) pela
-- base real do Supabase. Reproduz a mesma prioridade que o app já aplicava
-- no navegador: item sem saída recente primeiro, depois por valor financeiro
-- decrescente (curva A) — só que como ORDER BY de duas chaves em vez do hack
-- antigo "(semMovimentoRecente?50000:0) + valorFinanceiro" (que corria risco
-- de um item de alta rotação só de valor muito alto "furar" a prioridade de
-- um item parado; o ORDER BY de duas chaves não tem essa falha).
--
-- "Sem movimento recente" = sem saída há 90+ dias (ou nunca teve saída
-- registrada). Esse limiar não existia documentado em lugar nenhum antes —
-- o campo equivalente no cache local antigo era só um valor fixo, sem regra
-- visível — 90 dias é uma escolha razoável de "giro lento", ajustável se
-- o cliente pedir outro número.
--
-- LEFT JOIN com estoque_enderecos/enderecos porque a MAIORIA dos itens ainda
-- não tem endereço cadastrado (essas tabelas seguem praticamente vazias) —
-- INNER JOIN esconderia quase tudo. `corredor`/`rua`/`endereco_codigo` vêm
-- null até o cadastro de endereços avançar de verdade.
create or replace function contagem_itens_prioritarios(p_limit int default 50)
returns table(
  codigo text, descricao text, grupo text, almoxarifado text, saldo numeric,
  valor_financeiro numeric, data_ultima_saida date, sem_movimento_recente boolean,
  endereco_codigo text, corredor text, rua text
) as $$
  select
    p.codigo, p.descricao, p.grupo, es.almoxarifado, es.saldo, es.valor_financeiro,
    es.data_ultima_saida,
    (es.data_ultima_saida is null or es.data_ultima_saida < current_date - interval '90 days'),
    e.codigo, e.corredor, e.rua
  from estoque_saldo es
  join produtos p on p.codigo = es.produto_codigo
  left join estoque_enderecos ee on ee.produto_codigo = es.produto_codigo
  left join enderecos e on e.id = ee.endereco_id
  order by
    (es.data_ultima_saida is null or es.data_ultima_saida < current_date - interval '90 days') desc,
    es.valor_financeiro desc
  limit p_limit;
$$ language sql stable;

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
-- INVENTÁRIOS — VERSÃO DENORMALIZADA (mesma decisão já tomada pra `contagens`:
-- login continua 100% local, sem Supabase Auth, então nada de FK pra
-- `usuarios`). Existia uma versão anterior aqui pensada pra congelar saldo por
-- item numa tabela `inventario_itens` — nunca foi usada de verdade, porque o
-- app não guarda a lista de itens de um inventário: pra Aleatória/Curva
-- ABC/Manual/Rota, a lista é recalculada a partir do catálogo a cada vez
-- (determinística, ordenada, ver RandomCountFlow no index.html), e só o
-- CONTADOR `contados` precisa persistir pra saber por onde retomar. Só o tipo
-- "Lista Importada (Excel)" tem uma lista de itens real — guardada como jsonb
-- aqui mesmo, mais simples que uma tabela filha pra um dado que é só lido, não
-- consultado por item.
-- ---------------------------------------------------------------------------
create table inventarios (
  id text primary key,              -- 'INV-XXX', gerado no app
  nome text not null,
  almoxarifado text,
  responsavel text,                 -- nome em texto puro, sem FK (login continua local)
  data date,
  tipo text not null,               -- string livre igual ao NewInventory, não é enum
  qtd_itens int not null default 0,
  status text not null default 'pendente',
  contados int not null default 0,
  itens_importados jsonb,           -- só preenchido quando tipo = 'Lista Importada (Excel)'
  criado_em timestamptz not null default now()
);

-- Increment atômico de `contados` — evita perder incremento se dois
-- aparelhos completarem uma contagem quase ao mesmo tempo (um update comum de
-- "lê o valor, soma 1, grava" tem essa corrida; rodando dentro do banco não).
create or replace function increment_contados(p_id text)
returns void as $$
begin
  update inventarios set contados = contados + 1 where id = p_id;
end;
$$ language plpgsql;

-- ---------------------------------------------------------------------------
-- CONTAGENS — histórico completo, nunca sobrescrito. Cada rodada (1ª, 2ª...)
-- é uma linha nova, encadeada por contagem_anterior_id.
--
-- VERSÃO DENORMALIZADA (decisão do cliente: "só as contagens por enquanto").
-- Login, usuários e inventários continuam 100% locais (localStorage) — o app
-- ainda não usa Supabase Auth nem tem inventários no Supabase. Por isso esta
-- tabela NÃO tem FK pra usuarios/inventarios: `usuario` e `inventario_id`
-- gravam o texto que o app já tem localmente (nome do usuário logado, id do
-- inventário tipo "INV-XXXXXX"), sem exigir que essas linhas existam em
-- nenhuma outra tabela. `produto_codigo` também não tem FK pra `produtos`,
-- porque a contagem pode ser de um item fora do catálogo/cache local
-- (`fora_do_cache_local`) — travar com FK bloquearia exatamente o caso mais
-- comum hoje (catálogo com 85 mil códigos, cache local só com 300).
--
-- Colunas espelham 1:1 o objeto `count` montado em `CountStep.finalize()` no
-- index.html — ver ali antes de alterar este schema, pra não desalinhar.
-- `foto_url` (que assumia upload real) virou `tem_foto boolean`: o app hoje
-- só gera um `blob:` local via URL.createObjectURL, nunca envia a foto pra
-- lugar nenhum — não existe URL real pra guardar ainda.
--
-- `aprovado_por`/`aprovado_em`/`recontagem_solicitada_*` e `atualizado_em`
-- foram adicionadas depois (ver seção "Histórico único e centralizado" no
-- CLAUDE.md) — as ações do líder de aprovar/rejeitar uma divergência
-- (`approveDivergence`/`requestRecountFromOperator` no index.html) só
-- mudavam o estado local até então, nunca eram gravadas aqui; por isso um
-- líder aprovando num tablet nunca aparecia nos outros. `atualizado_em`
-- existe especificamente pra sincronização saber qual lado (local vs.
-- remoto) é mais recente ao reconciliar — mesmo papel que `contados` já
-- cumpre pra `inventarios`, só que por timestamp em vez de contador.
-- ---------------------------------------------------------------------------
create table contagens (
  id text primary key,                     -- 'CNT-XXXXXX', gerado no app
  inventario_id text,                      -- id do inventário local, ou '—' pra contagem avulsa
  produto_codigo text not null,
  descricao text,
  endereco text,                           -- endereço cadastrado (ou informado, se ainda não tinha)
  endereco_contado text,                   -- endereço que o operador de fato leu/informou na hora
  endereco_pendente_validacao boolean not null default false,
  usuario text not null,                   -- nome do usuário logado, texto puro (sem FK)
  numero_contagem int not null default 1,
  contagem_anterior_id text references contagens(id),
  qtd_contada numeric(14,3) not null,
  saldo_sistema numeric(14,3),             -- null quando o item está fora do cache local e sem saldo na planilha
  diferenca numeric(14,3),
  percentual numeric(10,2),
  valor_divergente numeric(14,2),
  fora_do_cache_local boolean not null default false,
  classificacao text,                      -- label da classificação de divergência (ex: "Dentro da tolerância")
  status_aprovacao text,                   -- aprovado_auto | aguardando_segunda | aguardando_analise_lider | aprovado_lider
  motivo text,
  tem_foto boolean not null default false,
  observacao text,
  data date not null,
  hora text,
  aprovado_por text,                       -- nome de quem aprovou a divergência (líder/admin), se houver
  aprovado_em text,
  recontagem_solicitada_pelo_lider boolean not null default false, -- true quando o líder REJEITOU a divergência (ver requestRecountFromOperator)
  recontagem_solicitada_por text,
  recontagem_solicitada_em text,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
create index idx_contagens_inventario on contagens(inventario_id);
create index idx_contagens_produto on contagens(produto_codigo);

-- ---------------------------------------------------------------------------
-- RLS (Row Level Security) — esboço. Ajuste conforme o modelo de auth real.
--
-- IMPORTANTE: o Inventário 360 ainda NÃO usa Supabase Auth (login próprio,
-- ver App() no index.html) — toda chamada ao Supabase hoje sai com a
-- publishable key "anon", nunca "authenticated". Por isso políticas do tipo
-- `auth.role() = 'authenticated'` bloqueiam o próprio app (foi exatamente o
-- que aconteceu com `produtos`: criado sem policy nenhuma, RLS bloqueou
-- geral até adicionar "leitura pública"). Enquanto não migrar pro Supabase
-- Auth de verdade, use `using (true)` pra leitura de tabelas sem dado
-- sigiloso — não `auth.role()='authenticated'`, que nunca bate hoje.
-- ---------------------------------------------------------------------------
alter table produtos enable row level security;
alter table estoque_saldo enable row level security;
alter table enderecos enable row level security;
alter table estoque_enderecos enable row level security;
alter table contagens enable row level security;

-- Catálogo e endereços: sem dado sigiloso, leitura pública liberada.
create policy "leitura pública" on produtos for select using (true);
create policy "leitura pública" on enderecos for select using (true);
create policy "leitura pública" on estoque_enderecos for select using (true);
create policy "leitura pública" on estoque_saldo for select using (true);

-- Contagens: o app grava direto daqui sem Supabase Auth (ver comentário na
-- definição da tabela acima), então a policy de INSERT precisa aceitar a
-- publishable key "anon" — `auth.role()='authenticated'` bloquearia a
-- própria gravação, mesmo erro que já aconteceu com `produtos`. Leitura
-- também liberada por ora (nenhuma tela do app lê daqui ainda, mas quando
-- ler, vai ser sem Auth do mesmo jeito). Reavaliar quando o Supabase Auth
-- entrar de verdade — hoje qualquer um com a publishable key pode inserir,
-- aceitável pro protótipo, não pra produção.
create policy "leitura pública" on contagens for select using (true);
create policy "inserção pública" on contagens for insert with check (true);
-- UPDATE: necessária pra `approveDivergence`/`requestRecountFromOperator`
-- (aprovar/rejeitar divergência) gravarem a decisão do líder aqui — sem
-- essa policy, essas ações continuam só locais e nunca aparecem em outro
-- aparelho (era exatamente esse o buraco antes desta policy existir).
create policy "atualização pública" on contagens for update using (true) with check (true);

-- Inventários: mesma razão de contagens acima, mas aqui também precisa de
-- UPDATE público — é como o app incrementa `contados` (via increment_contados)
-- e atualiza `status` conforme o progresso avança em qualquer aparelho.
alter table inventarios enable row level security;
create policy "leitura pública" on inventarios for select using (true);
create policy "inserção pública" on inventarios for insert with check (true);
create policy "atualização pública" on inventarios for update using (true) with check (true);
-- DELETE: necessária pra excluir um inventário (InventoryList, só admin)
-- propagar de verdade — sem isso a exclusão era só local e a sincronização
-- aditiva podia "ressuscitar" o inventário excluído em outro aparelho.
create policy "exclusão pública" on inventarios for delete using (true);

-- Escrita em estoque_saldo: originalmente pensada só pra service role (via
-- Edge Function de sincronização automática), mas essa sync nunca foi
-- aplicada — o upload manual da planilha SB2 acontece direto do navegador
-- (painel "Atualizar Saldo em Estoque", sem Supabase Auth ainda), então
-- precisa aceitar a publishable key "anon" como qualquer outra tabela de
-- escrita do app hoje. Mesma ressalva de sempre: aceitável pro protótipo,
-- reavaliar (restringir a admin de verdade) junto da migração pro Supabase Auth.
create policy "escrita pública" on estoque_saldo for all using (true) with check (true);

-- ---------------------------------------------------------------------------
-- CONTAGENS_HISTORICO — importação em lote da planilha de análise que o
-- cliente já usava ANTES do Inventário 360 (aba "BD_Contagens" de
-- Base_Analise_Contagens_2026.xlsx) — 3.659 linhas reais, fev/2026-jul/2026.
--
-- TABELA SEPARADA DE PROPÓSITO, não é a mesma `contagens` que o app grava ao
-- vivo. Motivo: `contagens` é consultada por `getOpenCountForProduct` pra
-- bloquear lançar uma contagem NOVA de um item que já tem um "documento em
-- aberto" (status aguardando_segunda/aguardando_analise_lider). Se as linhas
-- históricas (que têm status tipo "Recontar"/"Pendente"/"Ajustar" — já
-- resolvidos há meses na vida real, só não no formato que o app entende)
-- fossem misturadas ali, um item já bloqueado ontem por muito tempo antes do app
-- existir apareceria como "em aberto" hoje e travaria o operador de contar um
-- item real. `contagens_historico` é só leitura/relatório — nenhuma tela do
-- app consulta essa tabela pra decidir nada ainda.
--
-- Colunas espelham as da planilha original (`BD_Contagens`), só traduzidas
-- pra snake_case — não normalizado/mapeado pro vocabulário de status do app
-- (aprovado_auto, aguardando_segunda, etc.), porque são conceitos de
-- workflow DIFERENTES: o Status daquela planilha tem 6 estados (OK,
-- Recontar, Ajustado, Sem Ajuste, Pendente, Ajustar) — mais granular que o
-- do app hoje (não distingue "ajuste já aplicado no Protheus" de "aprovado,
-- sem ajuste necessário"). Fica como texto cru da planilha (`status`,
-- `classe`, `causa`, `solicitacao_ajuste`) — se um dia o app ganhar esses
-- mesmos conceitos no fluxo ao vivo, aí sim faz sentido normalizar.
--
-- `unique(produto_codigo, data, endereco)` existe pra tornar o upload
-- IDEMPOTENTE: o cliente provavelmente vai re-subir o arquivo master (que
-- cresce com novas rodadas) mais de uma vez ao longo do tempo, não só uma —
-- o painel de upload faz `upsert` nessa chave composta em vez de inserir
-- direto, então re-subir o mesmo arquivo não duplica as linhas já
-- importadas antes. Assunção: não existem duas contagens do MESMO item, no
-- MESMO endereço, no MESMO dia, na planilha original — plausível (uma
-- contagem por item por rodada diária), mas não 100% garantido pela fonte.
-- ---------------------------------------------------------------------------
create table contagens_historico (
  id uuid primary key default gen_random_uuid(),
  produto_codigo text not null,
  descricao text,
  endereco text,
  saldo_sistema numeric(14,3),
  qtd_contada numeric(14,3),
  diferenca numeric(14,3),
  valor_divergente numeric(14,2),        -- "Custo" na planilha original — COM sinal (diferença × custo unitário)
  acuracidade numeric(5,4),              -- "Acc" — max(0, 1 - abs(diferença)/sistema), entre 0 e 1
  data date,
  semana int,                            -- "Sem." — número da semana ISO (mesma regra já usada nos gráficos do Dashboard)
  status text,                           -- texto cru: OK | Recontar | Ajustado | Sem Ajuste | Pendente | Ajustar
  classe text,                           -- classificação ABC do item (A/B/C/NA), como veio na planilha
  causa text,                            -- motivo da divergência, vocabulário próprio da planilha original
  observacao text,
  solicitacao_ajuste text,               -- "SA" — nº da solicitação de ajuste no Protheus, texto (pode vir número ou "Dev.")
  dias_sem_movimento int,
  documento text,                        -- "Doc" — data reformatada DDMMYY, como veio na planilha (não é um ID à parte)
  importado_em timestamptz not null default now(),
  unique (produto_codigo, data, endereco)
);
create index idx_contagens_historico_produto on contagens_historico(produto_codigo);
create index idx_contagens_historico_data on contagens_historico(data);

alter table contagens_historico enable row level security;
create policy "leitura pública" on contagens_historico for select using (true);
create policy "escrita pública" on contagens_historico for all using (true) with check (true);

-- ---------------------------------------------------------------------------
-- MIGRAÇÃO — rodar isto no projeto Supabase REAL já existente (as tabelas
-- `contagens`/`inventarios` acima já foram criadas antes desta mudança; use
-- este bloco em vez de re-rodar os `create table`, que falhariam por já
-- existir). Ver seção "Histórico único e centralizado" no CLAUDE.md.
-- ---------------------------------------------------------------------------
alter table contagens add column if not exists aprovado_por text;
alter table contagens add column if not exists aprovado_em text;
alter table contagens add column if not exists recontagem_solicitada_pelo_lider boolean not null default false;
alter table contagens add column if not exists recontagem_solicitada_por text;
alter table contagens add column if not exists recontagem_solicitada_em text;
alter table contagens add column if not exists atualizado_em timestamptz not null default now();

create policy "atualização pública" on contagens for update using (true) with check (true);
create policy "exclusão pública" on inventarios for delete using (true);
