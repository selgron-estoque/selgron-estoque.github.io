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
-- USUÁRIOS — VERSÃO LEVE (mesmo espírito de `contagens`/`inventarios`: sync
-- sem Supabase Auth de verdade). A versão original desta tabela (comentário
-- "senha fica no Supabase Auth") nunca chegou a ser usada — o app sempre
-- autenticou 100% contra o `localStorage` (ver `attemptLogin` no index.html),
-- e migrar login pra Supabase Auth de verdade foi adiado explicitamente (ver
-- CLAUDE.md, "Terceiro pedaço do backend real") porque resetar senha de
-- OUTRO usuário via Auth exigiria a service role key no navegador — falha de
-- segurança grave. Essa tabela aqui NÃO é isso: é só um espelho da lista de
-- usuários (mesma senha em texto puro do protótipo, mesma limitação já
-- documentada no README) pra resolver um problema concreto — excluir/criar/
-- editar um usuário num aparelho não propagava pra os outros, porque `users`
-- só existia no `localStorage` de cada um.
--
-- `id` é `text` (não `uuid`) porque o app já gera seus próprios ids
-- (`'u'+Math.random()...`, ver `createUser` no index.html) — mesmo padrão já
-- usado em `inventarios`/`contagens` (`'INV-XXX'`/`'CNT-XXX'`).
-- `atualizado_em` cumpre o mesmo papel que já cumpre em `contagens`: decidir
-- qual lado (local vs. remoto) é mais recente ao reconciliar no sync de 30s.
-- ---------------------------------------------------------------------------
create table usuarios (
  id text primary key,
  nome text not null,
  usuario text not null,
  email text,
  senha text,                       -- texto puro, mesma limitação já documentada no README
  perfil text not null check (perfil in ('operador','lider','admin')),
  status text not null default 'ativo' check (status in ('ativo','bloqueado','deve_definir_senha')),
  -- Exceção de acesso por usuário, independente do perfil cadastrado (ex.:
  -- dar acesso a "Indicadores"/"Relatórios" pra um operador específico sem
  -- promovê-lo a líder) — ver ACESSOS_RESTRITOS/hasAccess no index.html.
  -- Só ADICIONA acesso além do que o perfil já libera, nunca remove.
  acessos_extras jsonb not null default '[]'::jsonb,
  -- Data/hora do último login bem-sucedido (attemptLogin/selfSetNewPassword
  -- no index.html) — exibido na tela "Usuários", pedido do cliente. `null`
  -- = usuário criado mas nunca fez login ainda.
  ultimo_acesso timestamptz,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
create unique index idx_usuarios_login on usuarios (lower(usuario));

-- ---------------------------------------------------------------------------
-- ENDEREÇOS PROPOSTOS — fila de validação do líder (Módulo 5/6): operador
-- conta um item sem endereço cadastrado, informa onde encontrou, e essa
-- proposta fica pendente até o líder confirmar ou rejeitar (ver
-- `AddressValidationPanel`/`addAddressProposal`/`resolveAddressProposal` no
-- index.html). Mesma versão leve/denormalizada de sempre — sem FK pra
-- `usuarios` (login continua local), `produto_codigo` sem FK pra `produtos`
-- pelo mesmo motivo já documentado em `contagens` (item pode estar fora do
-- catálogo). Nunca é deletada, só muda de `status` — por isso não precisa de
-- policy de DELETE.
-- ---------------------------------------------------------------------------
create table enderecos_propostos (
  id text primary key,              -- 'END-XXXXX', gerado no app
  produto_codigo text not null,
  descricao text,
  endereco_informado text not null,
  usuario text not null,            -- nome de quem propôs, texto puro (sem FK)
  data date,
  status text not null default 'pendente' check (status in ('pendente','confirmado','rejeitado')),
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);

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
--
-- `p_grupos` (opcional, default null = comportamento de sempre, sem filtro)
-- foi acrescentado pro tipo de inventário "Contagem por Grupo" — quando
-- informado, filtra só os itens de QUALQUER um dos grupos/famílias de
-- produto na lista (`grupo` em `produtos`, SB2 — permite selecionar mais de
-- um grupo na mesma contagem, pedido do cliente), mantendo a mesma
-- prioridade (sem movimento recente primeiro, depois valor financeiro).
--
-- `p_almoxarifados` (opcional, default null = sem filtro) — cliente
-- reportou que um item com saldo em MAIS de um armazém nunca batia na
-- contagem, porque o app comparava contra o saldo somado de todos os
-- armazéns, e fisicamente só existe saldo de UM armazém no local onde o
-- item está sendo contado. Cada linha de `estoque_saldo` já é por armazém
-- (não precisa somar nada aqui) — só faltava poder RESTRINGIR a busca ao(s)
-- armazém(ns) do inventário, em vez de trazer o item de qualquer armazém.
-- `drop function` primeiro porque a assinatura mudou de `p_grupo text` (uma
-- rodada anterior, texto único) pra `p_grupos text[]` (lista) — Postgres
-- trata assinaturas diferentes como funções SOBRECARREGADAS distintas, não
-- substitui sozinho; sem o drop, a versão antiga ficaria "fantasma" no banco.
drop function if exists contagem_itens_prioritarios(int, text);
drop function if exists contagem_itens_prioritarios(int, text[]);
create or replace function contagem_itens_prioritarios(p_limit int default 50, p_grupos text[] default null, p_almoxarifados text[] default null)
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
  where (p_grupos is null or p.grupo = any(p_grupos))
    and (p_almoxarifados is null or es.almoxarifado = any(p_almoxarifados))
  order by
    (es.data_ultima_saida is null or es.data_ultima_saida < current_date - interval '90 days') desc,
    es.valor_financeiro desc
  limit p_limit;
$$ language sql stable;

-- Lista os grupos que realmente têm algum item com saldo carregado (não os
-- 248 grupos possíveis do catálogo inteiro, a maioria sem saldo ainda) —
-- alimenta o seletor de grupo em "Contagem por Grupo", pra líder/admin não
-- escolher um grupo vazio sem querer. `qtd_itens` ajuda a decidir o
-- tamanho da contagem antes de criar o inventário.
create or replace function grupos_com_estoque()
returns table(grupo text, qtd_itens bigint) as $$
  select p.grupo, count(*)
  from estoque_saldo es
  join produtos p on p.codigo = es.produto_codigo
  where p.grupo is not null
  group by p.grupo
  order by count(*) desc;
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
  grupo text,                       -- só preenchido quando tipo = 'Contagem por Grupo' (código do grupo/família, tabela produtos)
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
  almoxarifado text,                       -- armazém onde o item foi contado (null pra contagens antigas, de antes desta coluna)
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
-- DELETE: usada por `deleteCountEverywhere` (App()) — exclusão definitiva de
-- uma contagem lançada por engano (líder/admin), sem deixar rastro nem em
-- outro aparelho.
create policy "exclusão pública" on contagens for delete using (true);

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

-- Usuários: mesma ressalva de sempre (sem Supabase Auth, `using(true)` em
-- tudo). Precisa das 4 operações — criar/editar/bloquear E excluir um
-- usuário só propagam de verdade pra outros aparelhos com SELECT+INSERT+
-- UPDATE+DELETE liberados, mesmo padrão já usado em `inventarios`. Aceitável
-- pro protótipo (qualquer um com a publishable key vê a lista de usuários,
-- incluindo senha em texto puro) — reforça, de novo, a necessidade de
-- Supabase Auth real antes de produção (ver README.md).
alter table usuarios enable row level security;
create policy "leitura pública" on usuarios for select using (true);
create policy "inserção pública" on usuarios for insert with check (true);
create policy "atualização pública" on usuarios for update using (true) with check (true);
create policy "exclusão pública" on usuarios for delete using (true);

-- Endereços propostos: só SELECT+INSERT+UPDATE — nunca são deletados (só
-- mudam de status pendente→confirmado/rejeitado, ver comentário na tabela).
alter table enderecos_propostos enable row level security;
create policy "leitura pública" on enderecos_propostos for select using (true);
create policy "inserção pública" on enderecos_propostos for insert with check (true);
create policy "atualização pública" on enderecos_propostos for update using (true) with check (true);

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
create policy "exclusão pública" on contagens for delete using (true);

-- Tipo de inventário novo "Contagem por Grupo" (ver CLAUDE.md) — grava o
-- grupo/família escolhido pra filtrar a busca de itens.
alter table inventarios add column if not exists grupo text;

-- Armazém onde cada contagem foi feita (ver CLAUDE.md "considerar saldo de
-- armazéns em separado") — sem isso, recontagem não sabia contra qual
-- armazém comparar quando o item tem saldo em mais de um.
alter table contagens add column if not exists almoxarifado text;

-- USUÁRIOS — o projeto real já tem uma tabela `usuarios` desde a aplicação
-- inicial do schema, mas com a estrutura ANTIGA (id uuid, sem coluna de
-- senha, pensada pra um Supabase Auth que nunca chegou a ser aplicado — ver
-- comentário na definição nova, mais acima neste arquivo). Como essa tabela
-- nunca foi populada de verdade (login sempre autenticou 100% contra o
-- localStorage), é seguro dropar e recriar do zero em vez de fazer `alter
-- table add column` em cima da estrutura errada.
--
-- `cascade` é necessário aqui: o projeto real tinha objetos criados direto
-- no painel do Supabase, fora deste schema.sql (`enderecos.criado_por` e
-- uma tabela `endereco_propostas`, singular — nomes/colunas que não existem
-- em lugar nenhum deste arquivo), ambos com FK pra `usuarios`. Confirmado
-- via `select count(*)` que as três tabelas envolvidas estavam com ZERO
-- linhas antes desta migração — `cascade` só remove as CONSTRAINTS de FK
-- que dependem de `usuarios`, não apaga a tabela `enderecos` nem dado
-- nenhum (não que houvesse dado pra perder). Se um dia isso rodar de novo
-- num projeto com dado real nessas colunas, conferir antes com
-- `select count(*) from enderecos where criado_por is not null` — se vier
-- >0, não rode isto sem decidir antes o que fazer com esse vínculo.
drop table if exists usuarios cascade;

-- `endereco_propostas` (singular) é o mesmo objeto órfão mencionado acima —
-- ficaria duplicando o papel de `enderecos_propostos` (plural, a tabela que
-- o app de fato lê/escreve, criada logo abaixo). Também confirmada vazia
-- antes de dropar.
drop table if exists endereco_propostas;

create table usuarios (
  id text primary key,
  nome text not null,
  usuario text not null,
  email text,
  senha text,
  perfil text not null check (perfil in ('operador','lider','admin')),
  status text not null default 'ativo' check (status in ('ativo','bloqueado','deve_definir_senha')),
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
create unique index idx_usuarios_login on usuarios (lower(usuario));
alter table usuarios enable row level security;
create policy "leitura pública" on usuarios for select using (true);
create policy "inserção pública" on usuarios for insert with check (true);
create policy "atualização pública" on usuarios for update using (true) with check (true);
create policy "exclusão pública" on usuarios for delete using (true);

-- ENDEREÇOS PROPOSTOS — tabela nova, não existia antes (com este nome); só o
-- `create table enderecos_propostos` de verdade (mais acima neste arquivo,
-- junto das RLS logo depois) precisa ser rodado — nada mais pra migrar aqui.

-- ACESSOS EXTRAS POR USUÁRIO — pedido do cliente: "posso dar acesso a abas
-- diferentes pra qualquer operador independente do perfil cadastrado". A
-- tabela `usuarios` do projeto real já existe e está populada (migração
-- acima já foi aplicada) — `add column if not exists` em vez de recriar,
-- mesmo padrão já usado pra `inventarios.grupo`/`contagens.almoxarifado`.
alter table usuarios add column if not exists acessos_extras jsonb not null default '[]'::jsonb;

-- ÚLTIMO ACESSO — pedido do cliente ("incluir abaixo de cada um o último
-- acesso, data e hora", tela Usuários). Mesmo padrão de migração aditiva.
alter table usuarios add column if not exists ultimo_acesso timestamptz;

-- =============================================================================
-- MIGRAÇÃO — LOGIN VIA SUPABASE AUTH DE VERDADE (substitui o localStorage
-- puro, ver comentário no topo da definição original de `usuarios` mais
-- acima neste arquivo — essa migração já tinha sido adiada duas vezes por
-- causa do problema abaixo).
--
-- Motivo de ter ficado pra depois até agora: qualquer ação do admin sobre
-- OUTRO usuário (criar, redefinir senha, bloquear, excluir) exige a Admin
-- API do Supabase Auth, que só funciona com a service role key — uma chave
-- que nunca pode existir no navegador. A partir de agora essas ações vivem
-- na Edge Function `usuarios-admin` (supabase/functions/usuarios-admin/
-- index.ts), que guarda essa chave só no servidor.
--
-- PASSO 0 — RODAR ANTES DE QUALQUER COISA ABAIXO: confirmar que não sobrou
-- nenhuma foreign key apontando pra `usuarios` no projeto REAL (o arquivo
-- schema.sql nem sempre reflete o estado exato do banco ao vivo — já
-- aconteceu antes, ver migração de `usuarios` mais acima, que precisou de
-- `cascade` por causa de objetos criados direto no painel). Rodar:
--
--   select conname, conrelid::regclass, confrelid::regclass
--   from pg_constraint
--   where confrelid = 'usuarios'::regclass;
--
-- Se vier alguma linha, resolver (normalmente dropar a constraint — o app
-- nunca escreve nesses campos, confirmado por grep em index.html) ANTES de
-- seguir pro restante deste bloco.
--
-- Diferente da migração anterior de `usuarios` (que fazia `drop table
-- cascade` com segurança porque a tabela real estava ZERADA), desta vez a
-- tabela tem linhas reais — por isso RENOMEIA em vez de dropar, preservando
-- o dado pra reconciliar depois de criar os usuários de verdade no Supabase
-- Auth (ver backend/README.md, seção "Migrar login pro Supabase Auth").
--
-- `senha` sai de vez daqui — a partir de agora mora só no `auth.users` do
-- Supabase, gerenciada via Admin API pela Edge Function `usuarios-admin`,
-- nunca mais em texto puro numa tabela nossa. `id` vira `uuid` igual ao
-- `auth.users.id` (era `text`, gerado pelo próprio app) — seguro depois de
-- confirmado o Passo 0 acima.
-- =============================================================================
alter table usuarios rename to usuarios_pre_auth_backup;
-- Renomear a TABELA não renomeia o ÍNDICE junto (Postgres mantém o nome
-- original do índice) — sem isso, o `create unique index idx_usuarios_login`
-- da tabela nova colide com o nome que já existe na tabela renomeada.
alter index idx_usuarios_login rename to idx_usuarios_pre_auth_backup_login;

create table usuarios (
  id uuid primary key references auth.users(id) on delete cascade,
  nome text not null,
  usuario text not null,             -- login por username continua existindo (UX preservada), só não é mais a chave de auth
  email text not null,               -- agora obrigatório: Supabase Auth exige e-mail real por conta
  perfil text not null check (perfil in ('operador','lider','admin')),
  status text not null default 'ativo' check (status in ('ativo','bloqueado','deve_definir_senha')),
  acessos_extras jsonb not null default '[]'::jsonb,
  ultimo_acesso timestamptz,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
create unique index idx_usuarios_login on usuarios (lower(usuario));
create unique index idx_usuarios_email on usuarios (lower(email));

-- ---- Funções de apoio ao login (rodam ANTES de autenticar) ----

-- Resolve "usuário ou e-mail" (a tela de login aceita os dois, ver
-- `identifier` em `attemptLogin` no index.html) pro e-mail real que o
-- Supabase Auth precisa pra `signInWithPassword` — sem isso, precisaríamos
-- expor a tabela inteira via SELECT público de novo (senão a UX de "logar
-- com usuário" quebra). `security definer` funciona mesmo com a tabela
-- travada por RLS pra admin/dono da linha só (ver policies abaixo). Devolve
-- só o mínimo necessário (id/email/status) — nunca perfil, acessos_extras.
create or replace function public.resolver_login(p_identifier text)
returns table(id uuid, email text, status text) as $$
  select u.id, u.email, u.status
  from usuarios u
  where lower(u.usuario) = lower(p_identifier) or lower(u.email) = lower(p_identifier)
  limit 1;
$$ language sql stable security definer set search_path = public;
revoke all on function public.resolver_login(text) from public;
grant execute on function public.resolver_login(text) to anon, authenticated;

-- Helper de autorização — evita RLS recursiva ("select da própria tabela
-- usuarios dentro de uma policy de usuarios"). `security definer` deixa a
-- intenção clara e não depende de RLS dentro da própria checagem de RLS.
-- Espelha EXATAMENTE o `hasAccess(user, 'usuarios')` do index.html — o
-- perfil admin já libera por padrão, e um líder/operador pode ganhar a
-- mesma exceção via `acessos_extras` (ver ACESSOS_RESTRITOS/hasAccess, e
-- checkboxes "Acessos extras" no UserForm) sem precisar virar admin. Sem
-- espelhar essa segunda condição aqui, a funcionalidade de "acessos
-- extras" quebraria silenciosamente pra esta tela específica assim que o
-- RLS entrasse em vigor: o usuário continuaria vendo o item no menu (isso
-- é decidido no client), mas a lista viria sempre vazia/só a própria linha.
create or replace function public.pode_gerenciar_usuarios(p_uid uuid)
returns boolean as $$
  select exists(
    select 1 from usuarios
    where id = p_uid and status <> 'bloqueado'
      and (perfil = 'admin' or acessos_extras ? 'usuarios')
  );
$$ language sql stable security definer set search_path = public;
revoke all on function public.pode_gerenciar_usuarios(uuid) from public;
grant execute on function public.pode_gerenciar_usuarios(uuid) to authenticated;

alter table usuarios enable row level security;

-- Leitura: cada usuário só vê a própria linha; quem tem acesso à tela
-- "Usuários" (admin, ou exceção via acessos_extras) vê todas.
create policy "leitura própria ou com acesso a usuários" on usuarios for select
  using (auth.uid() = id or public.pode_gerenciar_usuarios(auth.uid()));

-- Única escrita que o CLIENTE (navegador) ainda faz direto, sem passar pela
-- Edge Function: gravar o próprio "último acesso" no login bem-sucedido
-- (ver attemptLogin no index.html) — self-only E restrita à coluna
-- `ultimo_acesso` via GRANT de coluna (RLS sozinha só filtra LINHA, não
-- coluna; sem esse grant restrito, qualquer usuário autenticado poderia se
-- autopromover a admin via um PATCH direto na própria linha).
create policy "atualizar próprio último acesso" on usuarios for update
  using (auth.uid() = id) with check (auth.uid() = id);
revoke update on usuarios from authenticated;
grant update (ultimo_acesso) on usuarios to authenticated;

-- Sem policy de INSERT/DELETE pra authenticated/anon: criar, editar perfil/
-- senha/acessos_extras, bloquear e excluir usuário passam a ser só a Edge
-- Function `usuarios-admin` (roda com a service role key, ignora RLS).

-- =============================================================================
-- RECONCILIAÇÃO DOS USUÁRIOS REAIS — rodar DEPOIS de criar cada usuário de
-- verdade em Authentication → Add User no painel do Supabase (ver
-- backend/README.md). Não dá pra fazer isso automaticamente por e-mail (a
-- coluna `email` era OPCIONAL na tabela antiga — pode estar vazia pra algum
-- usuário) — cole o UUID gerado pelo Auth pra cada pessoa, casando com o
-- `usuario` (login) que já existia. Rodar 1x por usuário, trocando os
-- valores entre <> :
--
-- insert into usuarios (id, nome, usuario, email, perfil, status, acessos_extras, ultimo_acesso, criado_em)
-- select '<uuid-do-auth-users-aqui>', nome, usuario, '<email-real-aqui>', perfil, status, acessos_extras, ultimo_acesso, criado_em
-- from usuarios_pre_auth_backup where usuario = '<login-antigo-aqui>';
--
-- Depois de confirmar que os logins novos funcionam de ponta a ponta (com o
-- index.html já publicado com o novo fluxo), esta tabela de backup pode ser
-- removida — só rodar isto depois, não faz parte deste bloco:
--   drop table usuarios_pre_auth_backup;
-- =============================================================================

-- =============================================================================
-- ENDURECIMENTO DE RLS — rodar SÓ DEPOIS de confirmar que o novo login
-- (Supabase Auth) está funcionando em produção (ver backend/README.md,
-- ordem de deploy). Trocar essas policies pra `authenticated` ANTES disso
-- bloquearia o próprio app enquanto ele ainda estivesse logando localmente/
-- como anon. Fora de escopo deste bloco (fica pra um endurecimento
-- separado, não é o que motivou esta migração): RLS por papel (ex: só
-- líder/admin resolver endereço proposto) e apertar `produtos`/`enderecos`/
-- `estoque_enderecos`/`contagens_historico` (sem dado sensível).
-- =============================================================================
drop policy "leitura pública" on contagens;
drop policy "inserção pública" on contagens;
drop policy "atualização pública" on contagens;
drop policy "exclusão pública" on contagens;
create policy "leitura autenticada" on contagens for select using (auth.role() = 'authenticated');
create policy "inserção autenticada" on contagens for insert with check (auth.role() = 'authenticated');
create policy "atualização autenticada" on contagens for update using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy "exclusão autenticada" on contagens for delete using (auth.role() = 'authenticated');

drop policy "leitura pública" on inventarios;
drop policy "inserção pública" on inventarios;
drop policy "atualização pública" on inventarios;
drop policy "exclusão pública" on inventarios;
create policy "leitura autenticada" on inventarios for select using (auth.role() = 'authenticated');
create policy "inserção autenticada" on inventarios for insert with check (auth.role() = 'authenticated');
create policy "atualização autenticada" on inventarios for update using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy "exclusão autenticada" on inventarios for delete using (auth.role() = 'authenticated');

drop policy "leitura pública" on enderecos_propostos;
drop policy "inserção pública" on enderecos_propostos;
drop policy "atualização pública" on enderecos_propostos;
create policy "leitura autenticada" on enderecos_propostos for select using (auth.role() = 'authenticated');
create policy "inserção autenticada" on enderecos_propostos for insert with check (auth.role() = 'authenticated');
create policy "atualização autenticada" on enderecos_propostos for update using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');

drop policy "escrita pública" on estoque_saldo;
create policy "escrita autenticada" on estoque_saldo for all using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');

-- =============================================================================
-- SINCRONIZAÇÃO EM TEMPO REAL (Supabase Realtime) — substitui o polling de
-- 30s que o front-end usava antes pra saber que outro aparelho gravou algo
-- novo. Cliente confirmou que prefere sincronização instantânea (próximo
-- passo do produto é um inventário geral, com mais aparelhos contando ao
-- mesmo tempo — 30s de atraso vira um problema real nesse cenário: dois
-- operadores podem pegar o mesmo item "na vez" antes do outro aparelho
-- saber que já foi contado).
--
-- Só precisa habilitar a REPLICAÇÃO dessas 4 tabelas na publicação padrão
-- do Supabase (`supabase_realtime`) — nenhuma policy de RLS nova, o
-- Realtime já respeita as policies `auth.role() = 'authenticated'` (ver
-- bloco "ENDURECIMENTO DE RLS" logo acima) pra decidir o que cada cliente
-- conectado pode receber.
--
-- Rodar a introspecção abaixo ANTES, pra confirmar que a publicação já
-- existe e nenhuma dessas tabelas já está nela (evita erro de "already
-- member of publication" se alguém já tiver habilitado antes):
--   select schemaname, tablename from pg_publication_tables where pubname = 'supabase_realtime';
-- =============================================================================
alter publication supabase_realtime add table contagens, inventarios, enderecos_propostos, usuarios;

-- =============================================================================
-- CONFIGURAÇÕES DO APP COMPARTILHADAS ENTRE APARELHOS (`app_config`) —
-- cliente pediu explicitamente: "toda alteração que envolva configuração...
-- reflita em todos os aparelhos de imediato, não quero ter que alterar
-- manualmente em cada aparelho" — e adotou isso como regra permanente pra
-- qualquer configuração futura, não só as 3 de hoje. Antes disso,
-- `operadorVeSaldo`/`gruposExcluidos`/`sessionTimeoutMin` moravam em
-- `localStorage` (por aparelho, ver index.html `usePersistedState`) — um
-- admin configurando no próprio tablet não tinha NENHUM efeito nos tablets
-- dos operadores. Migrado pra uma linha ÚNICA (`id` fixo = 1, não é uma
-- tabela de N linhas) sincronizada por Realtime, mesmo padrão já usado pra
-- usuarios/contagens/inventarios/enderecos_propostos.
create table app_config (
  id int primary key default 1,
  operador_ve_saldo boolean not null default false,
  grupos_excluidos text[] not null default '{}',
  session_timeout_min int not null default 15,
  atualizado_em timestamptz not null default now(),
  atualizado_por text,           -- nome de quem mexeu por último, só pra auditoria visual
  constraint app_config_singleton check (id = 1)
);
insert into app_config (id) values (1);

alter table app_config enable row level security;

-- Helper de autorização — mesmo raciocínio do `pode_gerenciar_usuarios`
-- acima (security definer evita RLS recursiva ao consultar `usuarios`
-- dentro da policy de outra tabela). Aqui é só perfil admin mesmo, sem a
-- exceção de `acessos_extras` — configuração de sistema (visibilidade de
-- saldo, grupos excluídos, timeout de sessão) é mais sensível que
-- gerenciar usuários, então não estende a mesma exceção.
create or replace function public.eh_admin(p_uid uuid)
returns boolean as $$
  select exists(
    select 1 from usuarios where id = p_uid and perfil = 'admin' and status <> 'bloqueado'
  );
$$ language sql stable security definer set search_path = public;
revoke all on function public.eh_admin(uuid) from public;
grant execute on function public.eh_admin(uuid) to authenticated;

-- Leitura: qualquer autenticado — todo operador precisa ler
-- operador_ve_saldo/grupos_excluidos/session_timeout_min no PRÓPRIO
-- aparelho pra aplicar a regra, não só o admin que configurou.
create policy "leitura autenticada" on app_config for select
  using (auth.role() = 'authenticated');

-- Escrita: só admin. Sem policy de INSERT/DELETE — a linha única já é
-- inserida uma vez acima (`insert into app_config (id) values (1)`), nunca
-- de novo.
create policy "escrita só admin" on app_config for update
  using (public.eh_admin(auth.uid()));

-- Realtime — mesmo motivo/mecanismo da seção anterior: sem isso, a
-- atualização só chegaria nos outros aparelhos no próximo fetch manual
-- (login/reload), não "de imediato" como pedido.
alter publication supabase_realtime add table app_config;

-- =============================================================================
-- MARCAR ITEM COMO URGENTE (Recontagens / Itens Divergentes) — cliente pediu
-- pra destacar itens marcados como urgentes e que apareçam primeiro nas duas
-- filas de recontagem/divergência pendente. Só mais uma coluna em `contagens`
-- (a tabela já existe, já sincroniza por Realtime) — nenhuma tabela nova.
-- Rodar só se ainda não tiver rodado (introspecção antes evita erro de coluna
-- já existente):
--   select column_name from information_schema.columns where table_name = 'contagens' and column_name = 'urgente';
-- =============================================================================
alter table contagens add column if not exists urgente boolean not null default false;

-- =============================================================================
-- APROVAÇÃO POR VALOR (R$), NÃO MAIS POR % — cliente pediu pra remover a
-- aprovação automática baseada em percentual: R$ 0 (contagem exata) continua
-- aprovando sozinho; diferença até R$ 49,99 vai direto pra análise do líder;
-- R$ 50 ou mais primeiro passa por segunda contagem. Regra em si é só
-- código (`classifyDivergence`/`computeStatus` em index.html), não precisa
-- de coluna nova pra isso — mas a recontagem cuja diferença bate EXATA com a
-- rodada anterior ("Diferença confirmada, seguir com ajuste") precisa de um
-- campo pra persistir esse sinal e sincronizar entre aparelhos.
-- Mesma introspecção de sempre antes de rodar:
--   select column_name from information_schema.columns where table_name = 'contagens' and column_name = 'diferenca_confirmada';
-- =============================================================================
alter table contagens add column if not exists diferenca_confirmada boolean not null default false;

-- =============================================================================
-- VISIBILIDADE DE VALORES EM RECONTAGENS/DIVERGENTES — configuração SEPARADA
-- de `operador_ve_saldo`. Essa última controla só a tela de CONTAGEM em si
-- (CountStep); a Diretoria pediu explicitamente que a operação não tenha
-- acesso a valores nas telas de REVISÃO ("Recontagens Pendentes"/"Itens
-- Divergentes") como política própria, independente de como
-- `operador_ve_saldo` estiver configurado — por isso não reaproveita a
-- mesma coluna, precisa de uma trava independente. Default `false` (oculto
-- pra operação), mesmo critério já usado em `operador_ve_saldo`: começar
-- restritivo, admin libera se quiser.
-- Introspecção antes de rodar:
--   select column_name from information_schema.columns where table_name = 'app_config' and column_name = 'operador_ve_valores_recontagem';
-- =============================================================================
alter table app_config add column if not exists operador_ve_valores_recontagem boolean not null default false;
