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
-- USUÁRIOS — via Supabase Auth de verdade (não mais senha em texto puro numa
-- tabela nossa). `id` é `uuid`, o MESMO id de `auth.users` — criar/editar
-- perfil/definir senha/bloquear/excluir sempre passa pela Edge Function
-- `usuarios-admin` (roda com a service role key, nunca no navegador).
--
-- Definida logo aqui no topo (não mais espalhada em 3 gerações sucessivas ao
-- longo do arquivo, como era antes desta limpeza de segurança) porque
-- `enderecos`/`estoque_enderecos`/`endereco_propostas` mais abaixo já têm FK
-- `uuid references usuarios(id)` — precisa existir na forma final ANTES
-- delas, senão o schema não roda numa base nova (erro de tipo incompatível
-- na FK). O histórico de como se chegou a este formato (tabela local antiga
-- com senha em texto puro → tentativa intermediária → Supabase Auth) fica
-- só no `git log -p -- backend/schema.sql` e no CLAUDE.md — não faz sentido
-- reexecutar essa transição numa base de dados nova, que nunca teve as
-- formas antigas pra começar.
-- ---------------------------------------------------------------------------
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

-- ATENÇÃO — endurecimento de segurança: esta função NÃO é mais chamável por
-- `anon`/`authenticated`. Ela devolvia `id`/`email`/`status` pra QUALQUER
-- identifier tentado, mesmo antes de validar senha nenhuma — um oráculo de
-- enumeração de usuários (dá pra descobrir quem tem conta, quem está
-- bloqueado, e o `id` devolvido já foi, no passado, aceito como credencial
-- sozinho por `auto_definir_senha`, permitindo tomar conta de qualquer
-- usuário sem saber a senha). A resolução "usuário OU e-mail → e-mail real"
-- continua existindo, mas migrou pra dentro da Edge Function pública
-- `auth-publico` (ação `login`), que roda com a SERVICE ROLE key (ignora
-- RLS, não depende de nenhuma função `security definer` chamável por anon) e
-- funde a resolução com a verificação de senha no mesmo passo — "usuário não
-- existe" e "senha errada" ficam indistinguíveis pra quem está tentando
-- adivinhar, o que uma RPC de resolução isolada nunca conseguiria garantir
-- sozinha, não importa quão pouco ela devolvesse.
--
-- A função continua definida aqui só por referência/histórico — sem grant
-- pra `anon`/`authenticated`, ninguém além do dono (postgres) consegue
-- chamá-la. Se algum dia precisar de novo por algum motivo (ex.: um painel
-- administrativo interno), conceda a `service_role` explicitamente, nunca a
-- `anon`.
create or replace function public.resolver_login(p_identifier text)
returns table(id uuid, email text, status text) as $$
  select u.id, u.email, u.status
  from usuarios u
  where lower(u.usuario) = lower(p_identifier) or lower(u.email) = lower(p_identifier)
  limit 1;
$$ language sql stable security definer set search_path = public;
revoke all on function public.resolver_login(text) from public, anon, authenticated;

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

-- `contagem_itens_prioritarios()` morava aqui originalmente, mas o corpo
-- dela faz LEFT JOIN com `estoque_enderecos`/`enderecos` — tabelas que só
-- são criadas mais abaixo neste arquivo. Numa base NOVA (schema.sql rodado
-- do zero, sem nenhuma dessas tabelas ainda existindo), isso fazia o
-- `create or replace function` falhar aqui com "relation estoque_enderecos
-- does not exist" — confirmado rodando o arquivo inteiro contra um Postgres
-- vazio (ver CLAUDE.md). Como as 2 gerações seguintes da mesma função (que
-- ganham a coluna `unidade` e depois `custo_unitario_fallback`) já ficam
-- corretamente posicionadas DEPOIS dessas tabelas, a correção foi só mover
-- esta 1ª definição pra logo depois de `estoque_enderecos` (perto da seção
-- "ENDEREÇOS" mais abaixo) — sem mudar uma linha do SQL em si, só a posição
-- no arquivo. As 2 redefinições seguintes (`drop function`+`create or
-- replace`) continuam exatamente onde já estavam.

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

-- NOTA — `endereco_propostas` (singular) NÃO é criada aqui de propósito: foi
-- um objeto órfão, criado uma vez direto no painel do Supabase (fora deste
-- schema.sql) num projeto real, nunca usado pelo app (que sempre leu/gravou
-- em `enderecos_propostos`, PLURAL, criada mais abaixo) — já foi removida do
-- banco real (ver histórico) e não faz sentido recriá-la numa base nova.

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
-- (Definição original desta função ficava lá em cima, perto de `estoque_
-- saldo` — movida pra cá porque referencia `estoque_enderecos`/`enderecos`,
-- que só existem a partir daqui; ver comentário no lugar antigo.)
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
  atribuido_a text,                 -- nome do operador destinado a este inventário, sem FK — null = aberto pra qualquer um
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
  custo_unitario numeric(14,4),            -- custo unitário capturado na hora da contagem (não só o valor do
                                            -- ajuste, que é 0 quando não há divergência) — usado pelo Relatório
                                            -- Semanal de Inventário Cíclico (Custo Total Sistema/Físico). Só
                                            -- contagens feitas a partir desta coluna existir têm esse dado.
  fora_do_cache_local boolean not null default false,
  classificacao text,                      -- label da classificação de divergência (ex: "Dentro da tolerância")
  status_aprovacao text,                   -- aprovado_auto | aguardando_segunda | aguardando_analise_lider | aprovado_lider
  motivo text,
  tem_foto boolean not null default false,
  observacao text,
  almoxarifado text,                       -- armazém onde o item foi contado (null pra contagens antigas, de antes desta coluna)
  familia text,                            -- família/grupo do produto (ex: "MAT EXPEDIENTE"), null pra contagens antigas
  ultima_saida date,                       -- data da última saída registrada em estoque_saldo, capturada no momento da contagem (null se o item não tiver esse dado)
  data date not null,
  hora text,
  aprovado_por text,                       -- nome de quem aprovou a divergência (líder/admin), se houver
  aprovado_em text,
  recontagem_solicitada_pelo_lider boolean not null default false, -- true quando o líder REJEITOU a divergência (ver requestRecountFromOperator)
  recontagem_solicitada_por text,
  recontagem_solicitada_em text,
  recontagem_liberada_para_original boolean not null default false, -- true = o líder liberou o MESMO operador que já contou (usuario) pra recontar também (ver toggleLiberarRecontagemOriginal)
  atribuido_a text,                        -- nome do operador destinado a recontar este item, sem FK — null = aberto pra qualquer um (ver atribuirContagem)
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
  endereco text,                          -- parser (index.html) grava "-" em vez de null quando a
                                           -- planilha não traz endereço — Postgres trata NULL como
                                           -- sempre distinto de outro NULL, então linha sem endereço
                                           -- nunca conflitava com a unique abaixo e reimportação
                                           -- duplicava. Ver comentário em parseHistoricoContagensRows.
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
-- Colunas adicionadas depois da criação inicial de `contagens`/`inventarios`
-- neste projeto (histórico completo no `git log -p`/CLAUDE.md) — mantidas
-- aqui como `add column if not exists` porque são seguras/idempotentes tanto
-- numa base nova (a tabela já as tem desde o `create table` acima, então
-- este bloco não faz nada) quanto num projeto real mais antigo que ainda não
-- rodou esta atualização.
-- ---------------------------------------------------------------------------
alter table contagens add column if not exists aprovado_por text;
alter table contagens add column if not exists aprovado_em text;
alter table contagens add column if not exists recontagem_solicitada_pelo_lider boolean not null default false;
alter table contagens add column if not exists recontagem_solicitada_por text;
alter table contagens add column if not exists recontagem_solicitada_em text;
alter table contagens add column if not exists atualizado_em timestamptz not null default now();
alter table inventarios add column if not exists grupo text;
alter table contagens add column if not exists almoxarifado text;

-- NOTA — endurecimento de segurança (limpeza deste arquivo): as 3
-- `create policy "atualização pública"/"exclusão pública"` que existiam
-- aqui foram REMOVIDAS por serem duplicatas exatas das mesmas policies já
-- criadas mais acima, junto da definição de `contagens`/`inventarios` — a
-- duplicata fazia o script inteiro falhar com `policy already exists` ao
-- rodar contra uma base nova (ou reaplicar contra uma já migrada). E o
-- bloco de migração de `usuarios` que também vivia aqui (drop/recreate da
-- versão antiga em texto puro, depois rename+recreate pro formato uuid do
-- Supabase Auth) foi consolidado: a tabela `usuarios` agora é definida UMA
-- única vez, já no formato final, perto do topo deste arquivo — ver o
-- comentário lá pra explicação completa. O histórico das 3 gerações
-- anteriores continua disponível via `git log -p -- backend/schema.sql` e
-- no CLAUDE.md, não foi apagado, só não é mais SQL executável aqui.

-- =============================================================================
-- RECUPERAÇÃO DE SENHA — token de uso único, hash em repouso, expiração curta
-- =============================================================================
-- Suporta o fluxo novo de "esqueci minha senha"/"definir nova senha" (ver
-- supabase/functions/auth-publico/index.ts, ações `recuperar_solicitar` e
-- `recuperar_confirmar`). Antes disso, `auto_definir_senha` aceitava
-- `userId` sozinho como se fosse uma credencial — qualquer um que soubesse
-- (ou adivinhasse, ver o oráculo de `resolver_login` acima) o UUID de outra
-- pessoa conseguia definir a senha dela. Agora:
--   1. o ADMIN autenticado libera a conta (`usuarios-admin`, ação
--      `definir_senha` modo `liberar`) — só ele consegue gerar um token novo;
--   2. o token é um segredo aleatório de 256 bits, entregue ao admin (mesmo
--      canal de confiança já usado pra "senha temporária", fora de banda —
--      verbal/WhatsApp, mesmo padrão que este projeto já documentava antes);
--   3. só o HASH (SHA-256) do token fica gravado aqui — nunca o valor em si,
--      mesmo raciocínio de nunca guardar senha em texto puro, aplicado a um
--      segredo de uso único;
--   4. `expires_at` (30 min) + `used_at` (uso único, marcado na confirmação)
--      fecham a janela de ataque — um token vazado/interceptado tem vida
--      curta e só serve uma vez.
-- Sem NENHUMA policy de select/insert/update/delete pra `anon`/
-- `authenticated` — só a Edge Function (service role, ignora RLS) toca esta
-- tabela. Mesmo um SELECT liberado pra `anon` já seria perigoso (um invasor
-- poderia usá-lo pra checar em massa se algum `token_hash` "existe", um
-- oráculo por si só) — o cliente nunca consulta isso diretamente, só manda o
-- token de volta pra Edge Function validar.
create table if not exists password_reset_tokens (
  id uuid primary key default gen_random_uuid(),
  usuario_id uuid not null references usuarios(id) on delete cascade,
  token_hash text not null,
  expires_at timestamptz not null,
  used_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists idx_password_reset_tokens_hash on password_reset_tokens (token_hash);
create index if not exists idx_password_reset_tokens_usuario on password_reset_tokens (usuario_id);
alter table password_reset_tokens enable row level security;
-- (proposital: nenhuma policy criada — RLS ligado + zero grant = bloqueado
-- por padrão pra qualquer role que não seja o dono/service_role)

-- Fila de "esqueci minha senha" pendente de aprovação do admin — mesmo
-- conceito que já existia como o array `passwordRequests` guardado em
-- `localStorage` no index.html (bug real já documentado: nunca sincronizava
-- entre aparelhos, uma solicitação feita num tablet era invisível pro admin
-- usando outro). Agora centralizado aqui, lido pelo admin via a ação
-- `listar_solicitacoes_senha` de `usuarios-admin` (autenticada) — nunca
-- exposto a `anon` diretamente (mesmo raciocínio de `password_reset_tokens`:
-- mesmo um SELECT aqui revelaria quais contas pediram recuperação
-- recentemente, um vazamento de informação desnecessário).
create table if not exists password_reset_requests (
  id uuid primary key default gen_random_uuid(),
  usuario_id uuid not null references usuarios(id) on delete cascade,
  criado_em timestamptz not null default now(),
  resolvido boolean not null default false,
  resolvido_em timestamptz,
  resolvido_por text
);
create index if not exists idx_password_reset_requests_pendentes
  on password_reset_requests (usuario_id) where not resolvido;
alter table password_reset_requests enable row level security;
-- (proposital: nenhuma policy criada — mesmo critério acima)

-- =============================================================================
-- RECONCILIAÇÃO DOS USUÁRIOS REAIS — histórico/referência. Já foi aplicada
-- por completo no projeto Supabase real deste cliente (ver CLAUDE.md,
-- "Migração pro Supabase Auth confirmada em produção") — não faz parte do
-- fluxo normal pra uma base nova (que nunca tem `usuarios_pre_auth_backup`
-- pra reconciliar) nem precisa ser rodada de novo no projeto já migrado.
-- Preservada aqui só como referência de COMO foi feito, caso um dia outro
-- projeto precise do mesmo tipo de migração. Nenhum comando abaixo roda
-- sozinho — é tudo comentário com SQL de exemplo, a colar manualmente.
--
-- Rodar DEPOIS de criar cada usuário de
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

-- =============================================================================
-- FAMÍLIA/GRUPO NA CONTAGEM — indicador "Divergência por Família/Grupo" em
-- Indicadores ("Resumo da Operação"). O produto já tem `grupo` (código) em
-- `produtos`, mas a CONTAGEM em si nunca guardava a família/descrição do
-- grupo — precisava de uma consulta extra ao catálogo pra cruzar toda vez
-- que o indicador fosse calculado. Grava direto na contagem (mesmo raciocínio
-- já usado pra `almoxarifado`: evita ambiguidade/consulta extra depois),
-- como texto legível (ex: "MAT EXPEDIENTE"), não o código cru do grupo.
-- Contagens já existentes (antes desta coluna) ficam com `familia = null` —
-- o indicador só soma o que tem esse dado, sem inventar família nenhuma.
-- Introspecção antes de rodar:
--   select column_name from information_schema.columns where table_name = 'contagens' and column_name = 'familia';
-- =============================================================================
alter table contagens add column if not exists familia text;

-- =============================================================================
-- CATÁLOGO GANHA UNIDADE DE MEDIDA E ENDEREÇO EM MASSA — cliente mandou uma
-- planilha "Descrição de Produtos" (export do Protheus, mesma base SB2 de
-- sempre — 85.357 códigos, batendo com o catálogo já importado) trazendo
-- Unidade e Localização (endereço) por produto, algo que ele vai reenviar
-- de novo no futuro (mesmo padrão do saldo SB2/histórico de contagens) —
-- por isso ganhou um painel de upload dedicado em Configurações
-- (`CatalogoDescricaoSyncPanel`), não foi só uma correção pontual via SQL.
--
-- `produtos.unidade` JÁ EXISTIA no schema (linha da definição da tabela,
-- bem acima) mas nunca tinha sido populada nem selecionada em NENHUMA
-- consulta do front-end — ficava sempre null/"não informado" na tela. Não
-- precisa de `alter table` pra essa coluna, só passou a ser preenchida e
-- lida de verdade agora (ver index.html: searchSupabaseCatalog/
-- fetchProdutosByCodigos/estoqueRowToProduct).
--
-- `contagem_itens_prioritarios` precisou mudar de assinatura de retorno
-- (ganhou a coluna `unidade`) — mesmo padrão de sempre pra isso
-- (`drop function` primeiro, já que o Postgres não deixa trocar o formato
-- de retorno de uma função existente com `create or replace`).
-- =============================================================================
drop function if exists contagem_itens_prioritarios(int, text[], text[]);
create or replace function contagem_itens_prioritarios(p_limit int default 50, p_grupos text[] default null, p_almoxarifados text[] default null)
returns table(
  codigo text, descricao text, unidade text, grupo text, almoxarifado text, saldo numeric,
  valor_financeiro numeric, data_ultima_saida date, sem_movimento_recente boolean,
  endereco_codigo text, corredor text, rua text
) as $$
  select
    p.codigo, p.descricao, p.unidade, p.grupo, es.almoxarifado, es.saldo, es.valor_financeiro,
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

-- `produtos`/`enderecos`/`estoque_enderecos` só tinham policy de SELECT até
-- aqui (ver "leitura pública" mais acima) — o painel de upload roda com o
-- usuário já autenticado (Supabase Auth, ver "Quinto pedaço do backend
-- real"), então a escrita usa `auth.role()='authenticated'`, mesmo padrão
-- já aplicado em `estoque_saldo`/`contagens`/`inventarios` na rodada de
-- endurecimento de RLS — sem policy nenhuma de escrita, o INSERT/UPSERT do
-- painel bateria na parede do RLS (mesmo susto silencioso já documentado
-- várias vezes neste arquivo).
create policy "escrita autenticada" on produtos for all using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy "escrita autenticada" on enderecos for all using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy "escrita autenticada" on estoque_enderecos for all using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');

-- =============================================================================
-- FLUXO REAL DE AJUSTE DE ESTOQUE DA SELGRON — SA de Ajuste + aprovação da
-- Diretoria. O cliente revelou o processo de verdade: contagem → análise do
-- líder → (opcional) recontagem → se a divergência se confirma, o líder gera
-- uma SA de Ajuste e manda pra aprovação da Diretoria → só depois de aprovada
-- o ajuste é efetivado e o item conta como resolvido. Se a Diretoria reprovar,
-- volta pra fila de recontagem, com um destaque visual próprio (diferente da
-- rejeição do líder).
--
-- Hoje a aprovação da Diretoria é MANUAL, dentro do próprio app (o admin
-- representa a Diretoria) — não existe perfil "diretoria" novo nem integração
-- externa. `numero_sa` é digitado pelo líder no momento de encaminhar pra
-- aprovação (antes da decisão, não depois).
--
-- Dois valores novos de `status_aprovacao` (índice/RLS/policies já cobrem
-- qualquer valor de texto, não precisam de mudança):
--   aguardando_aprovacao_diretoria — SA gerada, aguardando decisão (estado
--     aberto, tratado como tal em OPEN_STATUSES no index.html).
--   ajuste_aprovado_diretoria — Diretoria aprovou, ajuste efetivado (estado
--     final, aparece em "Contagens Concluídas" como "Ajustado").
-- Se reprovado, o status volta pra `aguardando_segunda` (mesmo valor já usado
-- por "Solicitar nova contagem") — reaproveita 100% a fila/tela existente,
-- só com `reprovado_pela_diretoria=true` pra diferenciar visualmente o card.
--
-- Sem policy nova — a de UPDATE já existente em `contagens`
-- (`auth.role()='authenticated'`, ver "ENDURECIMENTO DE RLS" mais acima) já
-- cobre gravar essas colunas novas, mesmo padrão de toda migração de coluna
-- anterior nesta tabela.
--
-- Introspecção sugerida antes de rodar, mesma cautela de sempre:
--   select column_name from information_schema.columns where table_name = 'contagens' and column_name = 'numero_sa';
-- =============================================================================
alter table contagens add column if not exists numero_sa text;
alter table contagens add column if not exists sa_gerada_por text;
alter table contagens add column if not exists sa_gerada_em text;
alter table contagens add column if not exists reprovado_pela_diretoria boolean not null default false;
alter table contagens add column if not exists reprovado_por text;
alter table contagens add column if not exists reprovado_em text;

-- =============================================================================
-- MOTIVO DA REPROVAÇÃO DE AJUSTE — pedido do cliente, reaproveitada por 2 fluxos
--
-- Ao reprovar uma SA de Ajuste (tela "Aprovação de Ajustes"), o admin agora
-- precisa digitar POR QUE o ajuste não foi aceito — antes só ficava registrado
-- QUE foi reprovado (`reprovado_pela_diretoria`/`reprovado_por`/`reprovado_em`),
-- sem nenhum motivo. O campo é exibido no card do item reaberto em
-- "Recontagens Pendentes"/"Itens Divergentes", junto do aviso "A Diretoria
-- reprovou a SA...".
--
-- MESMA coluna também reaproveitada pelo "Reprovar ajuste" de "Contagens
-- Concluídas" (item "Ajustado" do histórico revertido pra "Ajustar",
-- reprovarAjusteHistoricoNaLinha) — apesar do nome ("...diretoria"), guarda o
-- motivo de QUALQUER reprovação de ajuste, não só a via SA/Diretoria; manter
-- uma coluna só em vez de criar uma 2ª evita duplicar o mesmo conceito. Nesse
-- 2º fluxo o motivo NÃO fica mais embutido dentro de `observacao` (era assim
-- antes; cliente achou poluído) — cada informação na sua própria coluna.
--
-- Sem policy nova — mesma UPDATE já existente em `contagens` cobre.
-- =============================================================================
alter table contagens add column if not exists motivo_reprovacao_diretoria text;

-- =============================================================================
-- ACESSO POR TELA — todos os menus configuráveis por usuário, não só extras
--
-- Até aqui, `acessos_extras` só CONCEDIA acesso além do que o perfil já
-- libera por padrão (ex.: dar "Indicadores" a um operador), e só 4 telas
-- (Indicadores/Relatórios/Endereços Pendentes/Usuários) tinham essa opção na
-- tela de edição de usuário — o resto do menu (Inventários, Nova Contagem,
-- Recontagens, Itens Divergentes, Aprovação de Ajustes, Contagens Concluídas,
-- Configurações) sempre ficou liberado pra todo mundo, sem nenhuma forma de
-- restringir. Cliente pediu pra poder escolher, por operador, se ele tem
-- acesso ou não a QUALQUER menu — incluindo tirar acesso de uma tela que o
-- perfil normalmente libera, não só conceder uma a mais.
--
-- `acessos_removidos` é o complemento de `acessos_extras`: uma lista de telas
-- que esse usuário NÃO pode acessar, mesmo que o perfil dele normalmente
-- liberasse (ver `hasAccess`/`TODOS_OS_MENUS` no index.html). Administrador
-- nunca é afetado por nenhuma das duas listas — sempre tem acesso a tudo,
-- decisão deliberada pra não correr risco de um admin se autobloquear de uma
-- tela crítica sem querer.
--
-- Sem policy nova — mesma UPDATE já existente em `usuarios` cobre.
-- =============================================================================
alter table usuarios add column if not exists acessos_removidos jsonb not null default '[]'::jsonb;

-- =============================================================================
-- MARCAR INVENTÁRIO COMO URGENTE ("Inventários Pendentes") — cliente pediu pra
-- estender o mesmo "marcar urgente" já usado em Recontagens/Itens Divergentes/
-- Aprovação de Ajustes (que marca uma CONTAGEM) pra também marcar um
-- INVENTÁRIO inteiro como urgente na tela "Inventários Pendentes" — sinaliza
-- pro operador qual documento priorizar antes dos outros. Mesmo padrão:
-- só mais uma coluna, sem tabela nova, sem policy nova (`inventarios` já tem
-- UPDATE liberado pra `authenticated`).
-- Introspecção antes de rodar:
--   select column_name from information_schema.columns where table_name = 'inventarios' and column_name = 'urgente';
-- =============================================================================
alter table inventarios add column if not exists urgente boolean not null default false;

-- =============================================================================
-- RESERVA DE ITEM DURANTE A CONTAGEM — trava real pra evitar dois operadores
-- contando o MESMO item ao mesmo tempo. Já tinha sido discutida antes (ver
-- CLAUDE.md, seção "Sincronização em tempo real... Segunda pergunta do
-- cliente") e na época ele decidiu resolver só por processo/treinamento, sem
-- reserva de verdade — voltou a pedir agora, escolhendo: reserva real no
-- servidor, expiração de 5 minutos (se o operador abandonar a tela sem
-- terminar), valendo pra TODOS os tipos de contagem (avulsa, fila e
-- recontagem, não só os com fila).
--
-- Uma linha por CÓDIGO DE PRODUTO (chave primária) — a reserva é GLOBAL por
-- código, não por inventário: o mesmo item não pode ser contado ao mesmo
-- tempo em lugar nenhum do app, esteja ele numa lista, avulso, ou em
-- recontagem. `usuario_id` é a chave de propriedade de verdade (comparada
-- via `auth.uid()`, nunca por nome — nome é só pra EXIBIÇÃO, "reservado por
-- Fulano").
create table if not exists item_reservas (
  produto_codigo text primary key,
  inventario_id text,
  usuario text not null,
  usuario_id uuid,
  criado_em timestamptz not null default now(),
  expira_em timestamptz not null
);

alter table item_reservas enable row level security;
-- drop antes de recriar: `create policy` não aceita `if not exists` no Postgres —
-- sem isso, rodar este bloco de novo (ex.: reimportar o schema inteiro depois de
-- já ter criado a tabela numa tentativa anterior) falha com "policy already exists"
drop policy if exists "leitura autenticada" on item_reservas;
drop policy if exists "escrita autenticada" on item_reservas;
create policy "leitura autenticada" on item_reservas for select using (auth.role() = 'authenticated');
create policy "escrita autenticada" on item_reservas for all using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');

-- Reserva o item pro usuário que chama — só sucede (retorna uma linha com
-- `reservado_por_mim = true`) se NINGUÉM MAIS tiver uma reserva ATIVA (não
-- expirada) pro mesmo código. Uma reserva EXPIRADA é tratada como livre — o
-- UPSERT sobrescreve sozinho, sem precisar de nenhum job de limpeza externo
-- (a linha `delete ... expira_em < now() - interval '1 hour'` faz uma faxina
-- leve a cada chamada, só pra tabela não crescer sem limite ao longo do
-- tempo). Reentrar no MESMO item por quem já é o dono da reserva também
-- sucede (renova o prazo) — cobre o caso de o componente remontar sem o
-- item ter de fato mudado.
--
-- SEMPRE devolve o estado ATUAL da reserva daquele código (de quem for) —
-- é assim que o cliente sabe "quem está contando agora" quando é recusado,
-- sem precisar de uma segunda consulta.
create or replace function reservar_item(p_produto_codigo text, p_inventario_id text, p_minutos int default 5)
returns table(produto_codigo text, inventario_id text, usuario text, usuario_id uuid, criado_em timestamptz, expira_em timestamptz, reservado_por_mim boolean)
language plpgsql
as $$
#variable_conflict use_column
-- BUG REAL corrigido aqui (achado testando contra um Postgres de verdade,
-- ver CLAUDE.md): `returns table(produto_codigo text, ...)` cria uma
-- variável PL/pgSQL implícita chamada `produto_codigo` — colidindo com a
-- COLUNA `produto_codigo` referenciada sem qualificação em
-- `on conflict (produto_codigo)` logo abaixo. Sem este pragma, TODA chamada
-- desta função falhava com "column reference produto_codigo is ambiguous",
-- sempre, em qualquer Postgres (não é specífico deste sandbox) — a função
-- nunca funcionou de verdade. `use_column` resolve a ambiguidade a favor da
-- COLUNA da tabela nesse ponto específico, sem mudar nenhum outro
-- comportamento (o resto do corpo já qualifica tudo explicitamente com
-- `ir.`/`r.`/`v_`).
declare
  v_uid uuid := auth.uid();
  v_nome text;
begin
  select u.nome into v_nome from usuarios u where u.id = v_uid;

  delete from item_reservas ir2 where ir2.expira_em < now() - interval '1 hour';

  insert into item_reservas as r (produto_codigo, inventario_id, usuario, usuario_id, criado_em, expira_em)
  values (p_produto_codigo, p_inventario_id, coalesce(v_nome, 'Desconhecido'), v_uid, now(), now() + (p_minutos || ' minutes')::interval)
  on conflict (produto_codigo) do update
    set inventario_id = excluded.inventario_id,
        usuario = excluded.usuario,
        usuario_id = excluded.usuario_id,
        criado_em = excluded.criado_em,
        expira_em = excluded.expira_em
    where r.expira_em < now() or r.usuario_id = v_uid;

  return query
    select ir.produto_codigo, ir.inventario_id, ir.usuario, ir.usuario_id, ir.criado_em, ir.expira_em,
           (ir.usuario_id = v_uid) as reservado_por_mim
    from item_reservas ir where ir.produto_codigo = p_produto_codigo;
end;
$$;

-- Libera a reserva (contagem finalizada, item pulado, ou operador saiu da
-- tela) — só remove se for a reserva de quem está chamando (protege contra
-- um aparelho liberar por engano a reserva de outro operador).
create or replace function liberar_item_reserva(p_produto_codigo text)
returns void
language sql
as $$
  delete from item_reservas where produto_codigo = p_produto_codigo and usuario_id = auth.uid();
$$;

-- =============================================================================
-- "ÚLTIMA MOVIMENTAÇÃO" + "DIAS PARADO" EM ITENS DIVERGENTES — cliente pediu
-- pra ver, junto do Valor Divergente, quando foi a última saída do item e há
-- quanto tempo ele está parado, pra ajudar a decidir a tratativa da
-- divergência. A data em si (`ultima_saida`) é capturada no momento da
-- CONTAGEM (a partir de `estoque_saldo.data_ultima_saida`, via
-- `estoqueRowToProduct`/`product.ultimaSaida`) e congelada na própria linha —
-- "quantos dias parado" é sempre calculado no front-end em cima de "hoje" (não
-- uma coluna própria), pra continuar crescendo enquanto a divergência
-- permanecer em aberto sem ser resolvida.
-- Contagens já existentes (antes desta coluna) ficam com `ultima_saida = null`
-- — a tela só mostra a linha quando esse dado existir, sem inventar nada.
-- Introspecção antes de rodar:
--   select column_name from information_schema.columns where table_name = 'contagens' and column_name = 'ultima_saida';
-- =============================================================================
alter table contagens add column if not exists ultima_saida date;

-- =============================================================================
-- "LIBERAR PARA O MESMO OPERADOR" EM RECONTAGENS — pedido do cliente: por
-- padrão, um item enviado pra recontagem (`aguardando_segunda`) some da
-- tela do PRÓPRIO operador que já contou (`usuario`), forçando uma segunda
-- pessoa conferir de verdade — o líder pode liberar essa exceção item a
-- item, pelo menu "⋮" de "Recontagens Pendentes" (ver toggleLiberarRecontagemOriginal
-- em App(), RecountsPanel no index.html). A checagem em si é feita no
-- FRONT-END (comparando `usuario` com o nome de quem está logado) — esta
-- coluna só guarda a decisão do líder, sem RLS por linha (mesma ressalva de
-- sempre, sem Supabase Auth por papel granular ainda).
-- Introspecção antes de rodar:
--   select column_name from information_schema.columns where table_name = 'contagens' and column_name = 'recontagem_liberada_para_original';
-- =============================================================================
alter table contagens add column if not exists recontagem_liberada_para_original boolean not null default false;

-- =============================================================================
-- "ATRIBUIR INVENTÁRIO A UM OPERADOR" — pedido do cliente: líder/admin pode
-- destinar um inventário inteiro a um operador específico (botão "Atribuir
-- a..." no menu "⋮" de cada card, ver InventoryList no index.html). Enquanto
-- o operador tiver QUALQUER inventário pendente atribuído especificamente a
-- ele, a tela "Em Execução" dele mostra SÓ esse(s) — os demais (mesmo os
-- sem dono nenhum, abertos pra qualquer um) ficam ocultos até ele concluir
-- o que foi destinado (ver `inventariosPendentesVisiveis` no index.html).
-- Guarda o NOME em texto puro (mesmo padrão de `responsavel`/`usuario` em
-- outras tabelas, sem FK — login continua local, sem Supabase Auth por
-- papel granular). `null`/vazio = aberto pra qualquer operador, sem dono.
-- Introspecção antes de rodar:
--   select column_name from information_schema.columns where table_name = 'inventarios' and column_name = 'atribuido_a';
-- =============================================================================
alter table inventarios add column if not exists atribuido_a text;

-- =============================================================================
-- "ATRIBUIR RECONTAGEM A UM OPERADOR" — mesma ideia da atribuição de
-- inventário acima, só que no nível de uma CONTAGEM individual em
-- "Recontagens Pendentes" (item aguardando segunda contagem, ver
-- RecountsPanel no index.html). Enquanto o operador tiver QUALQUER item
-- pendente atribuído especificamente a ele, a tela de Recontagens dele
-- mostra SÓ esse(s) (mesma função `filtrarPorAtribuicao`, reaproveitada do
-- caso de inventário). Mesma convenção: nome em texto puro, sem FK; null/
-- vazio = aberto pra qualquer operador.
-- Introspecção antes de rodar:
--   select column_name from information_schema.columns where table_name = 'contagens' and column_name = 'atribuido_a';
-- =============================================================================
alter table contagens add column if not exists atribuido_a text;

-- =============================================================================
-- DEVOLUÇÃO (item com sobra) NÃO GERA SA — pula direto pra Diretoria
--
-- Cliente esclareceu que o fluxo de SA/Armazém (ver bloco "FLUXO REAL DE
-- AJUSTE..." acima) só se aplica a item com FALTA (diferença negativa —
-- contagem física menor que o sistema). Item com SOBRA (diferença positiva)
-- não gera número de SA nenhum — é só uma devolução física, sem
-- protocolo/documento próprio — mas AINDA precisa da aprovação da Diretoria
-- (confirmado via `AskUserQuestion`), só que pula por completo a etapa
-- "Aguardando Armazém": o líder registra a devolução em "Itens Divergentes"
-- e o item já entra direto em `aguardando_aprovacao_diretoria`, sem passar
-- por `aguardando_solicitacao_armazem`.
--
-- `eh_devolucao` marca esse caso de forma EXPLÍCITA — não é inferido por
-- `numero_sa` estar vazio (mesma lição já aprendida várias vezes neste
-- projeto: inferir por ausência de dado é frágil, sempre que possível grava
-- um campo real e explícito). `sa_gerada_por`/`sa_gerada_em` (colunas já
-- existentes) são reaproveitadas aqui também, com o sentido mais genérico de
-- "quem iniciou o processo de ajuste" — SA ou devolução, os dois casos.
--
-- Introspecção antes de rodar:
--   select column_name from information_schema.columns where table_name = 'contagens' and column_name = 'eh_devolucao';
-- =============================================================================
alter table contagens add column if not exists eh_devolucao boolean not null default false;

-- =============================================================================
-- "CONTAGEM POR ROTA DE ENDEREÇO" NÃO CONSIDERAVA TODOS OS ITENS DO ENDEREÇO
--
-- Bug real reportado pelo cliente. `RouteCountFlow` (index.html) reaproveitava
-- `contagem_itens_prioritarios` (a mesma RPC de Aleatória/Curva ABC/Grupo) —
-- ela ordena por (sem_movimento_recente desc, valor_financeiro desc) e CORTA
-- em `p_limit` (200, ou até 2000 com grupos excluídos) ANTES de qualquer
-- filtro por endereço. Como o LEFT JOIN inclui QUALQUER item do armazém (com
-- ou sem endereço), um item de baixo valor que JÁ TEM endereço cadastrado
-- podia nunca aparecer na rota — perdia a "corrida de prioridade" contra
-- milhares de outros itens do mesmo armazém sem endereço nenhum, mesmo o
-- armazém tendo bem menos de 200 itens endereçados no total.
--
-- Rota de Endereço precisa de cobertura EXAUSTIVA — o operador percorre uma
-- posição física e precisa ver TODO item que está ali, não uma amostra por
-- prioridade (que faz sentido só pra Aleatória/Curva ABC/Grupo, onde a ideia
-- é justamente NÃO contar tudo). Função nova, dedicada:
--   - INNER JOIN em vez de LEFT JOIN em estoque_enderecos/enderecos — toda
--     linha devolvida já tem endereço de verdade, sem precisar competir por
--     prioridade com item sem endereço.
--   - SEM nenhum LIMIT — paginada no cliente via fetchTodasPaginado (mesmo
--     padrão já usado em toda busca "não pode ter limite" deste projeto,
--     ver comentário de fetchTodasPaginado no index.html).
--   - Ordenação com tiebreaker (e.codigo, p.codigo) — paginação estável.
-- =============================================================================
create or replace function contagem_itens_por_endereco(p_grupos text[] default null, p_almoxarifados text[] default null)
returns table(
  codigo text, descricao text, unidade text, grupo text, almoxarifado text, saldo numeric,
  valor_financeiro numeric, data_ultima_saida date, sem_movimento_recente boolean,
  endereco_codigo text, corredor text, rua text
) as $$
  select
    p.codigo, p.descricao, p.unidade, p.grupo, es.almoxarifado, es.saldo, es.valor_financeiro,
    es.data_ultima_saida,
    (es.data_ultima_saida is null or es.data_ultima_saida < current_date - interval '90 days'),
    e.codigo, e.corredor, e.rua
  from estoque_saldo es
  join produtos p on p.codigo = es.produto_codigo
  join estoque_enderecos ee on ee.produto_codigo = es.produto_codigo
  join enderecos e on e.id = ee.endereco_id
  where (p_grupos is null or p.grupo = any(p_grupos))
    and (p_almoxarifados is null or es.almoxarifado = any(p_almoxarifados))
  order by e.codigo, p.codigo;
$$ language sql stable;

-- =============================================================================
-- "CONFIRMAR" UM ENDEREÇO PROPOSTO PASSA A CORRIGIR O CADASTRO DE VERDADE
-- =============================================================================
-- Até aqui, "Confirmar" em "Endereços Pendentes de Cadastro" só marcava a
-- proposta como resolvida (status='confirmado' em enderecos_propostos) —
-- nunca escrevia em `enderecos`/`estoque_enderecos`. Resultado: nas PRÓXIMAS
-- contagens do mesmo item, o app continuava puxando o endereço cadastrado
-- de sempre (ou "sem endereço cadastrado", se nunca tinha nenhum) — a
-- correção nunca "pegava" de verdade, cliente perguntou e a resposta era
-- essa. Pedido do cliente (opção 2 de duas propostas): confirmar passa a
-- gravar o endereço de verdade no catálogo, valendo já na próxima contagem.
--
-- Duas colunas novas em `enderecos_propostos`:
--   - `almoxarifado` — precisa saber em qual armazém gravar o endereço
--     (`enderecos.almoxarifado` é NOT NULL); vem de `product.almoxarifado`
--     no momento em que a proposta é criada (índice/CountStep).
--   - `endereco_anterior` — só preenchido quando o item JÁ TINHA um
--     endereço cadastrado (a correção veio de escanear/digitar um endereço
--     DIFERENTE do cadastro, não de um item sem cadastro nenhum) — deixa a
--     tela do líder mostrar os dois lados ("cadastrado como X, encontrado em
--     Y") em vez de só "informado como Y".
alter table enderecos_propostos add column if not exists almoxarifado text;
alter table enderecos_propostos add column if not exists endereco_anterior text;

-- Nenhuma policy nova necessária pra gravar em `enderecos`/`estoque_enderecos`
-- — as duas já têm "escrita autenticada" desde a migração do catálogo (ver
-- "Catálogo ganha Unidade de Medida e Endereço em massa" acima). A ação em
-- si continua restrita pela UI (só líder/admin alcançam o botão "Confirmar"
-- em "Endereços Pendentes de Cadastro"), mesmo critério já usado no resto
-- do app (RLS permissivo pra `authenticated`, tela que dispara a ação é que
-- é gated por perfil).

-- =============================================================================
-- "VALOR DO AJUSTE" SEMPRE R$ 0,00 QUANDO O ARMAZÉM CONTADO TINHA SALDO 0
--
-- Bug real reportado pelo cliente com um caso concreto (000.48741, contado no
-- Armazém 01 com saldo 0, físico 2 — "Valor do ajuste" saiu R$ 0,00 mesmo o
-- item TENDO custo conhecido, só que registrado no saldo de OUTRO armazém).
-- Causa: toda função que resolve produto+saldo (`estoqueRowToProduct` no
-- index.html, e as duas RPCs abaixo que a alimentam) sempre calculava
-- `custoUnit = valor_financeiro/saldo` a partir de UMA ÚNICA linha de
-- `estoque_saldo` — a do armazém sendo contado. Quando esse armazém
-- especificamente tem saldo 0 (cenário real: item zerado ali, mas com saldo
-- em outro armazém), a divisão colapsa pra 0 e nenhum fallback existia —
-- mesmo o item tendo custo unitário perfeitamente conhecido via outro
-- armazém. `classifyDivergence` não depende de custo pra rotear (decisão já
-- tomada antes, "toda divergência vai pro líder"), mas `valorDivergente`
-- ("Valor do ajuste", mostrado em Contagens Concluídas/Itens Divergentes,
-- usado pela severidade visual e pelo relatório Excel) precisa do valor
-- certo — cliente confirmou: "esse item tem custo só precisa multiplicar
-- pela divergência".
--
-- `contagem_itens_prioritarios`/`contagem_itens_por_endereco` ganharam uma
-- coluna nova, `custo_unitario_fallback` — via LATERAL join em
-- `estoque_saldo`, pega o custo unitário (valor_financeiro/saldo) de
-- QUALQUER armazém do mesmo produto que tenha saldo<>0 e valor_financeiro
-- conhecido, preferindo o PRÓPRIO armazém da linha quando ele já serve
-- (`order by (es2.almoxarifado = es.almoxarifado) desc`) — só cai pra outro
-- armazém quando o próprio não tem custo derivável. `saldo`/`valor_financeiro`
-- da linha principal continuam representando só o armazém físico de
-- verdade (nunca mudam de significado) — só o custo unitário passou a ter
-- essa segunda fonte possível. index.html (`estoqueRowToProduct`) usa essa
-- coluna nova só quando o cálculo direto (valor_financeiro/saldo da própria
-- linha) dá 0/indisponível — sem mudança nenhuma pro caso comum (armazém
-- com saldo>0 já resolve sozinho, como sempre).
--
-- `searchSupabaseCatalog` (busca manual de item, "Nova Contagem" avulsa) já
-- tinha sido corrigida direto no index.html numa rodada anterior, com a
-- mesma lógica de fallback calculada em JS (não passa por RPC nenhuma) — só
-- as 2 RPCs abaixo (usadas por Aleatória/Curva ABC/Grupo/Rota de Endereço)
-- e `fetchProdutosByCodigos` (Lista Importada/Itens Específicos/Recontagem,
-- corrigida em JS no mesmo commit desta migração) precisavam do mesmo
-- tratamento.
--
-- `drop function` necessário nas duas — o formato de RETORNO muda (coluna
-- nova), e Postgres não deixa `create or replace` trocar isso.
-- =============================================================================
drop function if exists contagem_itens_prioritarios(int, text[], text[]);
create or replace function contagem_itens_prioritarios(p_limit int default 50, p_grupos text[] default null, p_almoxarifados text[] default null)
returns table(
  codigo text, descricao text, unidade text, grupo text, almoxarifado text, saldo numeric,
  valor_financeiro numeric, data_ultima_saida date, sem_movimento_recente boolean,
  endereco_codigo text, corredor text, rua text, custo_unitario_fallback numeric
) as $$
  select
    p.codigo, p.descricao, p.unidade, p.grupo, es.almoxarifado, es.saldo, es.valor_financeiro,
    es.data_ultima_saida,
    (es.data_ultima_saida is null or es.data_ultima_saida < current_date - interval '90 days'),
    e.codigo, e.corredor, e.rua,
    custo.valor_unitario
  from estoque_saldo es
  join produtos p on p.codigo = es.produto_codigo
  left join estoque_enderecos ee on ee.produto_codigo = es.produto_codigo
  left join enderecos e on e.id = ee.endereco_id
  left join lateral (
    select es2.valor_financeiro / es2.saldo as valor_unitario
    from estoque_saldo es2
    where es2.produto_codigo = es.produto_codigo
      and es2.saldo <> 0
      and es2.valor_financeiro is not null
    order by (es2.almoxarifado = es.almoxarifado) desc, es2.saldo desc
    limit 1
  ) custo on true
  where (p_grupos is null or p.grupo = any(p_grupos))
    and (p_almoxarifados is null or es.almoxarifado = any(p_almoxarifados))
  order by
    (es.data_ultima_saida is null or es.data_ultima_saida < current_date - interval '90 days') desc,
    es.valor_financeiro desc
  limit p_limit;
$$ language sql stable;

drop function if exists contagem_itens_por_endereco(text[], text[]);
create or replace function contagem_itens_por_endereco(p_grupos text[] default null, p_almoxarifados text[] default null)
returns table(
  codigo text, descricao text, unidade text, grupo text, almoxarifado text, saldo numeric,
  valor_financeiro numeric, data_ultima_saida date, sem_movimento_recente boolean,
  endereco_codigo text, corredor text, rua text, custo_unitario_fallback numeric
) as $$
  select
    p.codigo, p.descricao, p.unidade, p.grupo, es.almoxarifado, es.saldo, es.valor_financeiro,
    es.data_ultima_saida,
    (es.data_ultima_saida is null or es.data_ultima_saida < current_date - interval '90 days'),
    e.codigo, e.corredor, e.rua,
    custo.valor_unitario
  from estoque_saldo es
  join produtos p on p.codigo = es.produto_codigo
  join estoque_enderecos ee on ee.produto_codigo = es.produto_codigo
  join enderecos e on e.id = ee.endereco_id
  left join lateral (
    select es2.valor_financeiro / es2.saldo as valor_unitario
    from estoque_saldo es2
    where es2.produto_codigo = es.produto_codigo
      and es2.saldo <> 0
      and es2.valor_financeiro is not null
    order by (es2.almoxarifado = es.almoxarifado) desc, es2.saldo desc
    limit 1
  ) custo on true
  where (p_grupos is null or p.grupo = any(p_grupos))
    and (p_almoxarifados is null or es.almoxarifado = any(p_almoxarifados))
  order by e.codigo, p.codigo;
$$ language sql stable;

-- =============================================================================
-- BACKFILL: "Valor do ajuste" (contagens.valor_divergente) de contagens JÁ
-- SALVAS antes da correção acima — pedido explícito do cliente ("corrigir
-- todas as contagens novas e antigas"). Só a correção de código (acima)
-- vale pra contagem NOVA a partir de agora; contagem já gravada com
-- valor_divergente=0 (por saldo 0 no armazém contado, custo perdido) precisa
-- ser recalculada manualmente, uma vez, rodando o bloco abaixo.
--
-- MESMA lógica de fallback (armazém da própria contagem primeiro, senão
-- qualquer outro com saldo<>0 e valor_financeiro conhecido) — só que em cima
-- da quantidade (`diferenca`) já salva na contagem, não recalculando nada
-- de saldo/diferença.
--
-- Subquery escalar CORRELACIONADA no próprio SET (não `FROM LATERAL`, que
-- daria erro 42P10 — Postgres não deixa uma subquery no FROM de um UPDATE
-- referenciar a tabela ALVO do próprio UPDATE, mesmo com LATERAL; só uma
-- subquery no SET/WHERE pode). O `exists(...)` no WHERE evita gravar NULL
-- em `valor_divergente` quando não existe custo derivável em NENHUM
-- armazém — sem essa guarda, a subquery escalar retornaria NULL e a linha
-- ficaria pior do que estava (0 vira NULL em vez de continuar 0).
--
-- Escopo do UPDATE, todo deliberado:
--   - só `contagens` (a tabela AO VIVO do app) — `contagens_historico` é o
--     espelho da planilha `BD_Contagens` do próprio cliente, um dado de
--     origem diferente e já confiável (a coluna "Custo" de lá não foi
--     calculada pelo nosso código, veio pronta da planilha) — NUNCA tocar.
--   - só `diferenca is not null and diferenca <> 0` — contagem sem
--     divergência não tem "valor do ajuste" nenhum pra corrigir (já é 0 por
--     definição, não por bug).
--   - só sobrescreve quando o custo encontrado é REALMENTE diferente/maior
--     que o já salvo (`coalesce(contagens.valor_divergente,0) = 0`) — não
--     mexe em nenhuma linha que já tinha um valor gravado corretamente.
--
-- Rodar no SQL Editor do Supabase, no projeto real, DEPOIS de já ter as
-- funções acima atualizadas (não depende delas, mas documentado junto por
-- serem a mesma correção).
-- =============================================================================
update contagens c
set valor_divergente = round(abs(c.diferenca) * (
  select es.valor_financeiro / es.saldo
  from estoque_saldo es
  where es.produto_codigo = c.produto_codigo
    and es.saldo <> 0
    and es.valor_financeiro is not null
  order by (es.almoxarifado = c.almoxarifado) desc, es.saldo desc
  limit 1
), 2)
where c.diferenca is not null
  and c.diferenca <> 0
  and coalesce(c.valor_divergente, 0) = 0
  and exists (
    select 1 from estoque_saldo es
    where es.produto_codigo = c.produto_codigo
      and es.saldo <> 0
      and es.valor_financeiro is not null
  );

-- =============================================================================
-- FILA DE IMPRESSÃO DE ETIQUETAS — cliente perguntou se dava pra imprimir
-- direto pela web numa TSC ligada em OUTRO PC da rede (compartilhada via
-- Windows) — resposta é não, WebUSB só enxerga impressora ligada no MESMO
-- aparelho que roda o navegador, não alcança nada compartilhado por outro PC.
-- Solução que ele mesmo propôs: montar a etiqueta de qualquer lugar (celular,
-- outro PC), ela fica pendente numa fila, e quem está no PC que REALMENTE
-- enxerga a impressora (o do recebimento) abre a mesma tela e dispara a
-- impressão de lá.
--
-- Sem FK pra usuarios/produtos (mesmo padrão denormalizado de sempre nesse
-- app — `criado_por`/`impresso_por` gravam o NOME em texto puro, não o id).
-- `status` só tem 2 valores por enquanto: 'pendente'/'impressa' — sem
-- "cancelar" pedido ainda (não foi pedido).
-- =============================================================================
create table if not exists etiquetas_fila (
  id uuid primary key default gen_random_uuid(),
  tipo text not null,                 -- 'endereco' | 'produto'
  codigo text not null,
  descricao text,                     -- só 'produto'
  quantidade text,                    -- só 'produto', opcional
  data_recebimento date,              -- só 'produto', opcional
  endereco text,                      -- só 'produto', opcional — endereço cadastrado do material, mostrado na etiqueta abaixo de QTD
  unidade text,                       -- só 'produto', opcional — unidade de medida do cadastro (PC/KG/M/L/etc.), mostrada em "QTD: {quantidade} {unidade}"
  status text not null default 'pendente',
  criado_por text,
  criado_em timestamptz not null default now(),
  impresso_por text,
  impresso_em timestamptz
);

-- Migração pro projeto já aplicado (a tabela acima já existia sem essa
-- coluna) — endereço do material na etiqueta impressa, pedido do cliente.
alter table etiquetas_fila add column if not exists endereco text;

-- Migração pro projeto já aplicado — unidade de medida do cadastro em vez de
-- "PC" fixo na etiqueta (ver comentário em `buildEtiquetaItemHtml` no
-- index.html).
alter table etiquetas_fila add column if not exists unidade text;

alter table etiquetas_fila enable row level security;
drop policy if exists "leitura autenticada" on etiquetas_fila;
drop policy if exists "escrita autenticada" on etiquetas_fila;
create policy "leitura autenticada" on etiquetas_fila for select using (auth.role() = 'authenticated');
create policy "escrita autenticada" on etiquetas_fila for all using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');

-- Realtime — é o que faz o PC da impressora ver um pedido novo na hora, sem
-- precisar recarregar a tela (mesmo mecanismo já usado em contagens/
-- inventarios/usuarios/app_config). Introspecção antes, mesmo motivo de
-- sempre (evita erro de "already member of publication"):
--   select schemaname, tablename from pg_publication_tables where pubname = 'supabase_realtime';
alter publication supabase_realtime add table etiquetas_fila;

-- =============================================================================
-- CUSTO UNITÁRIO CAPTURADO NA CONTAGEM — Relatório Semanal de Inventário
-- Cíclico (Diretoria)
--
-- Cliente mandou como referência o relatório real que já manda toda semana
-- pra Diretoria (PDF "INVENTÁRIO CÍCLICO - ALMOX 01", cabeçalho SELGRON
-- INDUSTRIAL LTDA., caixa de Acuracidade, tabela Sistema TOTVS × Físico ×
-- Diferenças com Custo Unitário/Custo Total dos DOIS lados, ordenada por
-- endereço, com Motivo/Ação e assinatura de 3 papéis) e pediu algo nesse
-- estilo. Escopo confirmado via `AskUserQuestion`: Excel (não PDF fiel ao
-- pixel), só itens de fato contados pelo app (não o armazém inteiro, contado
-- ou não — o PDF de referência parece vir de um export direto do TOTVS,
-- listando até item sem nenhum movimento), Motivo/Ação digitados a cada
-- geração (não texto fixo).
--
-- `valor_divergente` (coluna já existente) não serve pra reconstruir "Custo
-- Unitário"/"Custo Total" — ele já sai 0 quando não há divergência, mesmo
-- que o item tenha custo unitário real (é |diferença|×custo, não o custo em
-- si) — a maioria dos itens de um inventário cíclico NÃO diverge (85%+ no
-- PDF de exemplo do cliente), então sem esta coluna nova a tabela do
-- relatório sairia praticamente toda em branco nas colunas de custo. Só
-- contagens gravadas a partir desta migração têm o valor — contagem já
-- salva antes fica com "Custo Unitário"/"Custo Total" em branco no
-- relatório (limitação real, documentada na própria tela, não escondida).
--
-- Introspecção antes de rodar:
--   select column_name from information_schema.columns where table_name = 'contagens' and column_name = 'custo_unitario';
-- =============================================================================
alter table contagens add column if not exists custo_unitario numeric(14,4);

-- =============================================================================
-- "SAs EM ABERTO" — desempenho do almoxarifado atendendo Solicitações ao
-- Almoxarifado (SA). Pedido do cliente: hoje ele visita manualmente
-- https://consulta.selgron.com.br/sa_aberto.php todo dia pra saber quais SAs
-- ainda estão pendentes e conferir se o time está cumprindo a meta de
-- atender em menos de 2 dias (48h corridas, confirmado via AskUserQuestion).
--
-- Regra central (do próprio cliente): enquanto a SA aparece na consulta, ela
-- está pendente; quando ela SOME da consulta, foi atendida. Isso só é
-- detectável comparando o retrato de agora contra o retrato anterior — por
-- isso existe uma Edge Function agendada (sync-sa-almoxarifado, a cada 30
-- min via pg_cron, ver backend/README.md seção 13) que consulta a página e
-- reconcilia contra esta tabela: SA que aparece de novo continua 'aberta'
-- (ultima_vista_em avança); SA que estava 'aberta' e não apareceu nesta
-- rodada vira 'atendida', com atendida_em = agora (o momento em que a
-- ausência foi detectada — aproximação inevitável, documentada: o
-- atendimento real aconteceu em algum ponto entre o poll anterior e este).
--
-- CORRIGIDO depois de ver o HTML real da página (o cliente mandou via "Ver
-- código-fonte da página") — a 1ª versão deste schema assumia `numero_sa`
-- como identidade única por linha, mas isso é falso: uma SA pode pedir
-- VÁRIOS materiais diferentes, cada um numa linha própria da tabela,
-- distinguida pela coluna "Item" (sequência 01, 02, 03... dentro da MESMA
-- SA — confirmado com exemplos reais no HTML, ex. a SA "073445" tem 10
-- linhas, Item 01 a 10, cada uma com código/descrição/quantidade
-- diferentes). A identidade de verdade é o PAR (numero_sa, item), não
-- numero_sa sozinho — por isso `chave` (concatenação dos dois,
-- "numero_sa-item") é a PRIMARY KEY, não `numero_sa`. Sem essa correção, o
-- item de uma SA multi-material sendo atendido faria TODOS os itens daquela
-- SA fecharem (ou reabrirem) juntos na reconciliação da Edge Function, mesmo
-- que só um deles tivesse sido resolvido de fato — bug de correção que só
-- apareceria em produção, com uma SA real de mais de 1 item.
--
-- Uma linha por (SA, Item) — não uma linha por poll. O que precisa ser
-- preservado é só a transição aberta→atendida de cada item, não um snapshot
-- de cada rodada.
--
-- `aberta_em` vem da coluna "Emissao" da consulta — confirmado no HTML real
-- que essa coluna só tem DATA (formato "DD/MM/AAAA"), nunca hora — gravada
-- como meia-noite daquele dia (`parseDataHoraCelula` na Edge Function já
-- lida com isso sem mudança nenhuma, ela sempre tratou "sem hora" como
-- "00:00:00"). Consequência honesta, documentada aqui e na tela: "tempo em
-- aberto"/"dentro da meta" podem ter até ~24h de imprecisão por causa
-- disso — é uma limitação real da fonte de dado (a página não expõe hora de
-- abertura), não um bug do parser.
--
-- "Tempo em aberto"/"dentro da meta" são SEMPRE calculados no front-end (não
-- colunas persistidas) — pra item ainda aberto, usa `now()` no lugar de
-- `atendida_em`, senão o indicador "SAs vencidas" (aberta há mais de 48h,
-- ainda sem atendimento) nunca conseguiria crescer sozinho enquanto a tela
-- fica aberta. Mesmo critério já usado em `diasParado()` no index.html.
--
-- Reaplicando este bloco por cima de uma tabela já criada com o desenho
-- antigo (PK só `numero_sa`)? `drop table` é seguro aqui SEM `cascade` — é
-- uma tabela só de espelho/consulta, sem nenhum outro objeto deste arquivo
-- com FK apontando pra ela, e sem dado que não possa ser resincronizado
-- sozinho no próximo poll de 30 min ou num "Sincronizar agora" manual.
-- Deliberadamente SEM `cascade`: se algum dia existir uma FK real apontando
-- pra esta tabela (algo criado fora deste arquivo, direto no painel — já
-- aconteceu antes com `usuarios`, ver o comentário na definição dela no
-- topo deste arquivo), este comando erra e pára em vez de silenciosamente
-- arrastar essa constraint junto — force conferir manualmente antes de
-- decidir o que fazer, em vez de cascatear às cegas.
drop table if exists sa_almoxarifado;
create table sa_almoxarifado (
  chave text primary key,        -- numero_sa || '-' || item
  numero_sa text not null,
  item text not null,
  solicitante text,
  material_codigo text,
  material_descricao text,
  quantidade text,
  almoxarifado text,
  aberta_em timestamptz,
  status text not null default 'aberta',      -- 'aberta' | 'atendida'
  atendida_em timestamptz,
  ultima_vista_em timestamptz not null default now(),
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
create index if not exists sa_almoxarifado_numero_sa_idx on sa_almoxarifado(numero_sa);

alter table sa_almoxarifado enable row level security;
drop policy if exists "leitura autenticada" on sa_almoxarifado;
create policy "leitura autenticada" on sa_almoxarifado for select using (auth.role() = 'authenticated');
-- Sem policy de insert/update/delete pra `authenticated` — só a Edge
-- Function (service role, ignora RLS) grava aqui, mesmo padrão de
-- sync-saldo-protheus/usuarios-admin. O app nunca escreve nesta tabela
-- direto, só lê e (via botão "Sincronizar agora", admin) invoca a function.

-- Realtime — pra quem já está com a tela "SAs em Aberto" aberta ver uma SA
-- nova/atendida sem precisar recarregar, assim que o próximo poll (ou um
-- "Sincronizar agora" manual) gravar. Mesmo mecanismo já usado em
-- contagens/inventarios/usuarios/app_config/etiquetas_fila. Introspecção
-- antes de rodar, mesmo motivo de sempre (evita erro de "already member"):
--   select schemaname, tablename from pg_publication_tables where pubname = 'supabase_realtime';
alter publication supabase_realtime add table sa_almoxarifado;

-- =============================================================================
-- CORREÇÃO DE SEGURANÇA: RLS POR PAPEL/AÇÃO NAS TABELAS OPERACIONAIS
-- =============================================================================
-- Até aqui, a maior parte da escrita nestas tabelas era liberada pra
-- QUALQUER usuário autenticado (`auth.role() = 'authenticated'`), sem
-- distinguir operador de líder/admin — suficiente pra barrar `anon`, mas não
-- pra impedir um OPERADOR de, via uma chamada direta à API REST/RPC (sem
-- passar pela UI, que já restringia essas ações por perfil no front-end),
-- aprovar divergência, excluir contagem/inventário, sobrescrever saldo do
-- sistema, editar o catálogo, ou confirmar endereço proposto — tudo isso
-- hoje só é barrado no cliente (`role==='...' ? ... : undefined`/
-- `hasAccess`), nunca validado no servidor.
--
-- Esta seção reaproveita o MESMO padrão `security definer` já usado em
-- `pode_gerenciar_usuarios`/`eh_admin` (acima) — evita RLS recursiva ao
-- consultar `usuarios` dentro da policy de outra tabela — pra fechar essa
-- lacuna tabela por tabela, no que já existe hoje: sem criar nenhuma tabela/
-- coluna nova, sem apagar nenhum dado. Cada policy/função foi desenhada
-- consultando de perto QUEM de fato escreve em cada tabela hoje (grep de
-- todo `.from('<tabela>').insert/update/delete/upsert(` em index.html,
-- cruzado com o gate de perfil da tela que chama cada função) — pra nunca
-- restringir mais do que o app já faz na prática. Idempotente (`drop policy
-- if exists` antes de cada `create policy`, `create or replace function`) —
-- roda tanto num banco que já aplicou as seções anteriores deste arquivo
-- quanto num banco novo, rodando o arquivo inteiro em sequência.
-- =============================================================================

-- Helper novo: líder OU admin — mesmo raciocínio de `pode_gerenciar_usuarios`/
-- `eh_admin` (mais acima neste arquivo), reaproveitado por várias policies
-- abaixo.
create or replace function public.eh_lider_ou_admin(p_uid uuid)
returns boolean as $$
  select exists(
    select 1 from usuarios
    where id = p_uid and status <> 'bloqueado'
      and perfil in ('lider','admin')
  );
$$ language sql stable security definer set search_path = public;
revoke all on function public.eh_lider_ou_admin(uuid) from public;
grant execute on function public.eh_lider_ou_admin(uuid) to authenticated;

-- Helper novo (BUG CORRIGIDO, achado em produção logo após a rodada de RLS
-- por papel/ação): `eh_lider_ou_admin` sozinha ignora o mecanismo de
-- "Acesso por tela" (`acessos_extras`/`acessos_removidos` em `usuarios`,
-- ver `UserForm`/`hasAccess` no index.html) — algumas telas restritas a
-- líder/admin por padrão (`ACESSOS_RESTRITOS` no front-end: 'etiquetas',
-- 'enderecos', 'solicitacaoArmazem', 'aprovacaoDiretoria', 'dashboard',
-- 'relatorios', 'sasAberto') podem ser liberadas individualmente pra um
-- operador específico — e, pra pelo menos duas delas (`EtiquetasPanel`/
-- `AddressValidationPanel`), o acesso à TELA já é a única trava que o
-- front-end aplica (a ação em si não tem um segundo gate de role) — a
-- policy usando só `eh_lider_ou_admin` travava esse operador mesmo com a
-- exceção concedida (achado real: um operador com a exceção 'etiquetas'
-- não conseguia mais "Enviar para Fila", erro "new row violates row-level
-- security policy for table etiquetas_fila"). Mirror exato de
-- `hasAccess(user, viewId)` do index.html — só usado nas 2 tabelas que de
-- fato têm esse mecanismo de exceção (etiquetas_fila, enderecos_propostos/
-- enderecos/estoque_enderecos); as outras tabelas desta seção (contagens/
-- inventarios) foram conferidas uma a uma e usam `role==='lider'||
-- role==='admin'` direto no componente (`canApprove`/`canMark`/
-- `canDecide`), sem nenhum caminho de exceção — `eh_lider_ou_admin`/
-- `eh_admin` continuam corretas pra essas.
create or replace function public.tem_acesso_tela(p_uid uuid, p_tela text)
returns boolean as $$
  select
    case
      when u.perfil = 'admin' then true
      when (u.acessos_removidos ? p_tela) then false
      when u.perfil = 'lider' then true
      else (u.acessos_extras ? p_tela)
    end
  from usuarios u
  where u.id = p_uid and u.status <> 'bloqueado';
$$ language sql stable security definer set search_path = public;
revoke all on function public.tem_acesso_tela(uuid, text) from public;
grant execute on function public.tem_acesso_tela(uuid, text) to authenticated;

-- -----------------------------------------------------------------------
-- CONTAGENS — leitura continua ampla (várias telas — "Contagens de Hoje" na
-- Home, busca de status, etc. — legitimamente mostram a fila de TODO
-- mundo, pra qualquer perfil). Inserção continua ampla — é assim que
-- QUALQUER operador lança uma contagem nova, via `CountStep.finalize()` ->
-- `saveContagemToSupabase` (inclusive recontagem, que também é só um
-- INSERT novo com `numero_contagem+1`/`contagem_anterior_id`). UPDATE
-- (aprovar/rejeitar divergência, marcar urgente, atribuir, gerar SA,
-- aprovar/reprovar Diretoria, editar motivo, voltar pra análise) e DELETE
-- (excluir contagem) nunca são feitos por operador em NENHUM fluxo da UI —
-- sempre líder/admin (UPDATE, ver `approveDivergence`/
-- `requestRecountFromOperator`/`toggleUrgente`/`atribuirContagem`/
-- `enviarParaArmazem`/`enviarParaAprovacaoDiretoria`/
-- `aprovarAjusteDiretoria`/`reprovarAjusteDiretoria`/
-- `editarMotivoObservacaoContagem`/`voltarParaAnaliseLider` em App()) ou só
-- admin (DELETE, ver `onDeleteCount={role==='admin'?deleteCount:undefined}`
-- nos 4 painéis que oferecem excluir).
-- -----------------------------------------------------------------------
drop policy if exists "atualização autenticada" on contagens;
drop policy if exists "atualização pública" on contagens;
drop policy if exists "atualização líder ou admin" on contagens;
drop policy if exists "exclusão autenticada" on contagens;
drop policy if exists "exclusão pública" on contagens;
drop policy if exists "exclusão só admin" on contagens;
create policy "atualização líder ou admin" on contagens for update
  using (public.eh_lider_ou_admin(auth.uid()))
  with check (public.eh_lider_ou_admin(auth.uid()));
create policy "exclusão só admin" on contagens for delete
  using (public.eh_admin(auth.uid()));

-- Trava de integridade na INSERÇÃO: o INSERT continua liberado pra qualquer
-- autenticado (precisa continuar assim — é o caminho normal de contar),
-- mas sem essa trava um operador poderia inserir uma linha JÁ com
-- `status_aprovacao='aprovado_lider'` (ou qualquer outro veredito que só o
-- líder deveria poder dar) direto via API, pulando a análise por completo —
-- risco real de "aprovação" mesmo sem nenhuma tela permitir isso.
-- `CountStep.finalize()` (o ÚNICO ponto de INSERT usado por QUALQUER
-- perfil pra lançar uma contagem nova) nunca produz nada além de
-- 'aprovado_auto'/'aprovado_segunda'/'aguardando_segunda'/
-- 'aguardando_analise_lider' (ver `computeStatus` em index.html) — a
-- importação de histórico (`seedRecontarQueueFromHistorico`, admin-only)
-- também só usa esses dois últimos. Os outros 4 estados
-- ('aprovado_lider', 'aguardando_solicitacao_armazem',
-- 'aguardando_aprovacao_diretoria', 'ajuste_aprovado_diretoria') só
-- existem via UPDATE (já travado acima pra líder/admin), nunca via INSERT
-- em nenhum fluxo real — travar isso na inserção não quebra nenhuma
-- funcionalidade existente, líder/admin continuam livres (a trava só se
-- aplica a quem NÃO é líder/admin).
create or replace function public.contagens_valida_status_insercao()
returns trigger as $$
begin
  if new.status_aprovacao not in ('aprovado_auto','aprovado_segunda','aguardando_segunda','aguardando_analise_lider')
     and not public.eh_lider_ou_admin(auth.uid()) then
    raise exception 'status_aprovacao inválido para inserção direta por este perfil: %', new.status_aprovacao;
  end if;
  return new;
end;
$$ language plpgsql security definer set search_path = public;
drop trigger if exists trg_contagens_valida_status_insercao on contagens;
create trigger trg_contagens_valida_status_insercao
  before insert on contagens
  for each row execute function public.contagens_valida_status_insercao();

-- -----------------------------------------------------------------------
-- INVENTARIOS — leitura e inserção continuam amplas (operador cria
-- inventário avulso o tempo todo via "Nova Contagem" — `PickCountType` não
-- restringe por perfil). UPDATE (marcar urgente, atribuir, cancelar,
-- remover item pendente) e DELETE (excluir) só líder/admin — mesmo padrão
-- de `InventoryList`, que só mostra Baixar/Cancelar/Excluir dentro do
-- bloco `role==='admin'`; "Marcar urgente"/"Atribuir a..." já eram
-- líder/admin.
--
-- `increment_contados` precisa virar `security definer`: é o ÚNICO
-- caminho de UPDATE que QUALQUER perfil (inclusive operador) legitimamente
-- usa — avançar o cursor `contados` ao confirmar um item de uma fila
-- (`RandomCountFlow`/`RouteCountFlow`/`ImportedListCountFlow`). Sem isso,
-- travar UPDATE pra líder/admin quebraria a contagem em fila do operador.
-- -----------------------------------------------------------------------
create or replace function increment_contados(p_id text)
returns void as $$
  update inventarios set contados = contados + 1 where id = p_id;
$$ language sql security definer set search_path = public;
revoke all on function increment_contados(text) from public;
grant execute on function increment_contados(text) to authenticated;

drop policy if exists "atualização autenticada" on inventarios;
drop policy if exists "atualização pública" on inventarios;
drop policy if exists "atualização líder ou admin" on inventarios;
drop policy if exists "exclusão autenticada" on inventarios;
drop policy if exists "exclusão pública" on inventarios;
drop policy if exists "exclusão só admin" on inventarios;
create policy "atualização líder ou admin" on inventarios for update
  using (public.eh_lider_ou_admin(auth.uid()))
  with check (public.eh_lider_ou_admin(auth.uid()));
create policy "exclusão só admin" on inventarios for delete
  using (public.eh_admin(auth.uid()));

-- -----------------------------------------------------------------------
-- ENDERECOS_PROPOSTOS — inserção continua ampla (qualquer operador propõe
-- um endereço enquanto conta, via `addAddressProposal`, passado aos
-- fluxos de contagem sem restrição de perfil). UPDATE (confirmar/rejeitar
-- a proposta, `AddressValidationPanel`) usa `tem_acesso_tela(...,
-- 'enderecos')`, não `eh_lider_ou_admin` puro — BUG REAL corrigido aqui
-- (achado em produção, ver CLAUDE.md): `AddressValidationPanel` não tem
-- NENHUM gate de role interno além do acesso à própria TELA
-- (`hasAccess`/`ACESSOS_RESTRITOS.enderecos`, que já honra
-- `acessosExtras`/`acessosRemovidos`) — um operador com a exceção
-- concedida via "Acesso por tela" via a tela normalmente, mas
-- `eh_lider_ou_admin` (perfil-only) bloqueava a escrita mesmo assim.
-- -----------------------------------------------------------------------
drop policy if exists "atualização autenticada" on enderecos_propostos;
drop policy if exists "atualização pública" on enderecos_propostos;
drop policy if exists "atualização líder ou admin" on enderecos_propostos;
create policy "atualização líder ou admin" on enderecos_propostos for update
  using (public.tem_acesso_tela(auth.uid(), 'enderecos'))
  with check (public.tem_acesso_tela(auth.uid(), 'enderecos'));

-- -----------------------------------------------------------------------
-- ESTOQUE_SALDO / PRODUTOS — leitura passa a exigir autenticação (era
-- `using(true)`, aberta até pra `anon` — sem necessidade real, já que
-- login sempre foi obrigatório pra usar o app desde a migração pro
-- Supabase Auth). Escrita restrita a ADMIN — únicos escritores reais são
-- `replaceEstoqueSaldoInSupabase` (StockSyncPanel, upload da SB2) e
-- `upsertCatalogoDescricao` (CatalogoDescricaoSyncPanel), os dois só
-- dentro de Configurações → admin.
-- -----------------------------------------------------------------------
drop policy if exists "leitura pública" on estoque_saldo;
drop policy if exists "leitura autenticada" on estoque_saldo;
create policy "leitura autenticada" on estoque_saldo for select
  using (auth.role() = 'authenticated');
drop policy if exists "escrita autenticada" on estoque_saldo;
drop policy if exists "escrita pública" on estoque_saldo;
drop policy if exists "escrita só admin" on estoque_saldo;
create policy "escrita só admin" on estoque_saldo for all
  using (public.eh_admin(auth.uid()))
  with check (public.eh_admin(auth.uid()));

drop policy if exists "leitura pública" on produtos;
drop policy if exists "leitura autenticada" on produtos;
create policy "leitura autenticada" on produtos for select
  using (auth.role() = 'authenticated');
drop policy if exists "escrita autenticada" on produtos;
drop policy if exists "escrita só admin" on produtos;
create policy "escrita só admin" on produtos for all
  using (public.eh_admin(auth.uid()))
  with check (public.eh_admin(auth.uid()));

-- -----------------------------------------------------------------------
-- ENDERECOS / ESTOQUE_ENDERECOS — leitura passa a exigir autenticação
-- (mesmo motivo acima). Escrita usa `tem_acesso_tela(..., 'enderecos')`
-- (não `eh_lider_ou_admin` puro, mesmo bug/correção documentado acima em
-- ENDERECOS_PROPOSTOS) — dois escritores reais confirmados:
-- `upsertCatalogoDescricao` (admin, upload em massa — sempre passa,
-- `tem_acesso_tela` retorna `true` pra admin incondicionalmente) E
-- `aplicarEnderecoConfirmado` (líder/admin por padrão, OU qualquer
-- perfil com a exceção `'enderecos'` concedida, aprovação de endereço
-- proposto em `AddressValidationPanel`).
-- -----------------------------------------------------------------------
drop policy if exists "leitura pública" on enderecos;
drop policy if exists "leitura autenticada" on enderecos;
create policy "leitura autenticada" on enderecos for select
  using (auth.role() = 'authenticated');
drop policy if exists "escrita autenticada" on enderecos;
drop policy if exists "escrita líder ou admin" on enderecos;
create policy "escrita líder ou admin" on enderecos for all
  using (public.tem_acesso_tela(auth.uid(), 'enderecos'))
  with check (public.tem_acesso_tela(auth.uid(), 'enderecos'));

drop policy if exists "leitura pública" on estoque_enderecos;
drop policy if exists "leitura autenticada" on estoque_enderecos;
create policy "leitura autenticada" on estoque_enderecos for select
  using (auth.role() = 'authenticated');
drop policy if exists "escrita autenticada" on estoque_enderecos;
drop policy if exists "escrita líder ou admin" on estoque_enderecos;
create policy "escrita líder ou admin" on estoque_enderecos for all
  using (public.tem_acesso_tela(auth.uid(), 'enderecos'))
  with check (public.tem_acesso_tela(auth.uid(), 'enderecos'));

-- -----------------------------------------------------------------------
-- ITEM_RESERVAS — pedido explícito: a duração da reserva precisa ser fixa
-- NO SERVIDOR (nunca confiar no `p_minutos` que o client manda), e só o
-- dono pode renovar/liberar a própria reserva. `reservar_item`/
-- `liberar_item_reserva` viram `security definer` — a lógica interna já
-- era correta (só sobrescreve reserva expirada ou do próprio usuário;
-- `liberar_item_reserva` já filtrava por `usuario_id = auth.uid()`), só
-- precisa deixar de depender da RLS de quem chama pra funcionar — e a
-- policy de escrita ampla (`for all` pra qualquer autenticado) é REMOVIDA
-- por completo: sem nenhuma policy de insert/update/delete pra
-- `authenticated`, a ÚNICA forma de escrever nesta tabela passa a ser
-- através dessas duas funções (que rodam com privilégio elevado — bypassam
-- RLS — mas só fazem exatamente o que o próprio código delas já permitia).
-- Confirmado via grep que index.html nunca chama `.from('item_reservas')`
-- direto em lugar nenhum — só via `.rpc('reservar_item'/'liberar_item_reserva', ...)`.
--
-- `p_minutos` continua no parâmetro só por compatibilidade com a chamada já
-- existente no front-end (`reservarItemSupabase`, `p_minutos:5`) — o valor
-- recebido é ignorado de propósito, a duração real vem sempre da constante
-- `v_duracao` abaixo. Corpo idêntico ao original em tudo mais (mesmas
-- colunas retornadas, mesma faxina de reserva velha, mesma regra de
-- sobrescrita).
-- -----------------------------------------------------------------------
create or replace function reservar_item(p_produto_codigo text, p_inventario_id text, p_minutos int default 5)
returns table(produto_codigo text, inventario_id text, usuario text, usuario_id uuid, criado_em timestamptz, expira_em timestamptz, reservado_por_mim boolean)
language plpgsql
security definer
set search_path = public
as $$
#variable_conflict use_column
-- BUG REAL corrigido aqui (achado testando contra um Postgres de verdade,
-- ver CLAUDE.md) — mesmo problema do corpo original acima: `returns
-- table(produto_codigo text, ...)` cria uma variável implícita que colide
-- com a COLUNA `produto_codigo` em `on conflict (produto_codigo)`. Sem este
-- pragma, a função sempre falhava com "column reference produto_codigo is
-- ambiguous" — nunca tinha funcionado de verdade, em nenhum Postgres.
declare
  v_uid uuid := auth.uid();
  v_nome text;
  v_duracao constant interval := interval '5 minutes'; -- fixa no servidor — `p_minutos` (parâmetro do client) é ignorado de propósito
begin
  select u.nome into v_nome from usuarios u where u.id = v_uid;

  delete from item_reservas ir2 where ir2.expira_em < now() - interval '1 hour';

  insert into item_reservas as r (produto_codigo, inventario_id, usuario, usuario_id, criado_em, expira_em)
  values (p_produto_codigo, p_inventario_id, coalesce(v_nome, 'Desconhecido'), v_uid, now(), now() + v_duracao)
  on conflict (produto_codigo) do update
    set inventario_id = excluded.inventario_id,
        usuario = excluded.usuario,
        usuario_id = excluded.usuario_id,
        criado_em = excluded.criado_em,
        expira_em = excluded.expira_em
    where r.expira_em < now() or r.usuario_id = v_uid;

  return query
    select ir.produto_codigo, ir.inventario_id, ir.usuario, ir.usuario_id, ir.criado_em, ir.expira_em,
           (ir.usuario_id = v_uid) as reservado_por_mim
    from item_reservas ir where ir.produto_codigo = p_produto_codigo;
end;
$$;
revoke all on function reservar_item(text, text, int) from public;
grant execute on function reservar_item(text, text, int) to authenticated;

create or replace function liberar_item_reserva(p_produto_codigo text)
returns void
language sql
security definer
set search_path = public
as $$
  delete from item_reservas where produto_codigo = p_produto_codigo and usuario_id = auth.uid();
$$;
revoke all on function liberar_item_reserva(text) from public;
grant execute on function liberar_item_reserva(text) to authenticated;

drop policy if exists "escrita autenticada" on item_reservas;
-- Sem nenhuma policy de insert/update/delete pra `authenticated` daqui em
-- diante — só as duas funções acima (security definer) escrevem aqui, de
-- propósito. "leitura autenticada" (já existente, ver mais acima) continua
-- igual — não é dado sensível, e o front-end precisa ler o estado da
-- reserva de qualquer código pra mostrar "já sendo contado por Fulano".

-- -----------------------------------------------------------------------
-- ETIQUETAS_FILA — leitura/inserção/atualização usam `tem_acesso_tela(...,
-- 'etiquetas')`, não `eh_lider_ou_admin` puro. BUG REAL corrigido aqui —
-- o primeiro sintoma relatado em produção deste round inteiro (ver
-- CLAUDE.md): `EtiquetasPanel` não tem NENHUM gate de role interno além
-- do acesso à própria TELA (`hasAccess`/`ACESSOS_RESTRITOS.etiquetas`, já
-- honra `acessosExtras`/`acessosRemovidos`) — único lugar que grava nesta
-- tabela, `salvarEtiquetaNaFila`/`marcarEtiquetaImpressa`. Um operador
-- (Lucio Schultz, caso real) com a exceção `'etiquetas'` concedida
-- conseguia abrir a tela normalmente mas era barrado por
-- `eh_lider_ou_admin` (perfil-only) ao clicar "Enviar para Fila" — erro
-- "new row violates row-level security policy for table 'etiquetas_fila'".
-- Sem policy de delete — nenhum caminho do app apaga linha desta tabela.
-- -----------------------------------------------------------------------
drop policy if exists "leitura autenticada" on etiquetas_fila;
drop policy if exists "escrita autenticada" on etiquetas_fila;
drop policy if exists "leitura líder ou admin" on etiquetas_fila;
drop policy if exists "inserção líder ou admin" on etiquetas_fila;
drop policy if exists "atualização líder ou admin" on etiquetas_fila;
create policy "leitura líder ou admin" on etiquetas_fila for select
  using (public.tem_acesso_tela(auth.uid(), 'etiquetas'));
create policy "inserção líder ou admin" on etiquetas_fila for insert
  with check (public.tem_acesso_tela(auth.uid(), 'etiquetas'));
create policy "atualização líder ou admin" on etiquetas_fila for update
  using (public.tem_acesso_tela(auth.uid(), 'etiquetas'))
  with check (public.tem_acesso_tela(auth.uid(), 'etiquetas'));

-- -----------------------------------------------------------------------
-- LIMITAÇÃO CONHECIDA, DOCUMENTADA (não corrigida nesta rodada por
-- disciplina de escopo — não fazia parte da lista de 8 tabelas pedida
-- explicitamente): `contagens_historico` continua com leitura E escrita
-- totalmente públicas pra qualquer autenticado (`using(true)` nos dois,
-- ver mais acima neste arquivo) — é o espelho só-consulta da planilha
-- `BD_Contagens` importada, sem nenhum escritor direto do app hoje (só
-- entra via `HistoricoImportPanel`, admin-only, e via
-- `reprovarAjusteHistoricoNaLinha`, também admin-only), mas a RLS em si
-- não reflete isso. Se quiser fechar também, o mesmo padrão desta seção
-- (`eh_admin`/`eh_lider_ou_admin`) se aplica igual.
-- -----------------------------------------------------------------------

-- =============================================================================
-- GESTÃO DE SEPARAÇÃO — "Programação". Pedido do cliente: "Temos Gestão de
-- inventário agora crie Gestão de separação em gestão de separação crie uma
-- pagina chamada programação, ali vou incluir a sequencia de separação." O
-- líder monta a fila de itens que precisam ser separados (busca no catálogo,
-- escolhe prioridade/urgência do pedido — Alta/Média/Baixa, confirmada com o
-- cliente como o critério de ordenação, não endereço físico), o operador
-- percorre a fila JÁ ORDENADA por prioridade e marca "Separado" conforme
-- avança. Espelha o mesmo desenho já usado em `etiquetas_fila` (mesma
-- tela/painel de gestão, mesmo estilo): tabela denormalizada, sem FK pra
-- usuarios/produtos (`criado_por`/`separado_por` gravam o NOME em texto
-- puro, mesmo padrão de sempre nesse app).
--
-- Diferente de `etiquetas_fila` (nunca deletada) — aqui existe uma ação
-- "Excluir" (só admin, no front-end) que remove a linha de vez, então a RLS
-- já nasce com policy de delete também, seguindo direto o padrão hardened
-- (`tem_acesso_tela`, não o `auth.role()='authenticated'` intermediário que
-- outras tabelas mais antigas deste arquivo passaram antes de serem
-- endurecidas — este projeto já está pós essa migração, uma tabela nova
-- hoje já nasce no padrão final).
-- =============================================================================
create table if not exists sequencia_separacao (
  id uuid primary key default gen_random_uuid(),
  codigo text not null,
  descricao text,
  quantidade text,
  prioridade text not null default 'media',   -- 'alta' | 'media' | 'baixa'
  observacao text,
  status text not null default 'pendente',    -- 'pendente' | 'separado'
  criado_por text,
  criado_em timestamptz not null default now(),
  separado_por text,
  separado_em timestamptz,
  -- etp/op/local/unidade: preenchidos só quando o item entra na fila via
  -- busca por ETP (ver seção "Busca de itens faltantes por ETP" mais
  -- abaixo) — sempre null pro fluxo antigo de busca manual no catálogo,
  -- que não tem nenhum desses 4 conceitos.
  etp text,
  op text,
  local text,
  unidade text
);

alter table sequencia_separacao enable row level security;
drop policy if exists "leitura líder ou admin" on sequencia_separacao;
drop policy if exists "inserção líder ou admin" on sequencia_separacao;
drop policy if exists "atualização líder ou admin" on sequencia_separacao;
drop policy if exists "exclusão líder ou admin" on sequencia_separacao;
create policy "leitura líder ou admin" on sequencia_separacao for select
  using (public.tem_acesso_tela(auth.uid(), 'programacaoSeparacao'));
create policy "inserção líder ou admin" on sequencia_separacao for insert
  with check (public.tem_acesso_tela(auth.uid(), 'programacaoSeparacao'));
create policy "atualização líder ou admin" on sequencia_separacao for update
  using (public.tem_acesso_tela(auth.uid(), 'programacaoSeparacao'))
  with check (public.tem_acesso_tela(auth.uid(), 'programacaoSeparacao'));
create policy "exclusão líder ou admin" on sequencia_separacao for delete
  using (public.tem_acesso_tela(auth.uid(), 'programacaoSeparacao'));

-- Realtime — outro aparelho (o operador no chão de fábrica) vê a fila
-- mudar/um item novo aparecer sem precisar recarregar, mesmo mecanismo já
-- usado em contagens/inventarios/usuarios/app_config/etiquetas_fila.
-- Introspecção antes, mesmo motivo de sempre (evita erro de "already
-- member of publication"):
--   select schemaname, tablename from pg_publication_tables where pubname = 'supabase_realtime';
alter publication supabase_realtime add table sequencia_separacao;

-- =============================================================================
-- BUSCA DE ITENS FALTANTES POR ETP (Gestão de Separação → Programação)
-- =============================================================================
-- Pedido do cliente: "Neste link eu vou digitar o código da ETP e ele
-- pesquisa a OP e quantidade de itens dentro da OP, na tela de programação
-- eu adiciono o número da ETP." — uma nova Edge Function,
-- `consultar-itens-faltantes` (ver
-- supabase/functions/consultar-itens-faltantes/index.ts), consulta
-- https://consulta.selgron.com.br/itensfaltantes.php pelo código da ETP e
-- devolve a lista de itens faltantes daquela ETP (uma ETP pode abranger
-- mais de uma OP e mais de um item — por isso a busca sempre devolve uma
-- LISTA). Mesmo desenho de `consultar-produto-selgron`: proxy sob demanda,
-- sem nenhuma escrita no Supabase — quem grava em `sequencia_separacao` é
-- o front-end, só depois que o líder revisa a lista (checkbox por item,
-- nada entra sozinho — decisão confirmada via AskUserQuestion: "Mostrar
-- lista, eu escolho quais entram") e escolhe uma prioridade única pro
-- lote inteiro (2ª decisão confirmada: "Eu escolho uma prioridade pro
-- lote inteiro", não item a item).
--
-- Os 4 campos novos abaixo (etp/op/local/unidade, já incluídos na
-- definição da tabela acima pra quem aplicar o schema do zero) só são
-- preenchidos por esse fluxo novo — pra quem já tem `sequencia_separacao`
-- aplicada (o líder já rodou o SQL da seção anterior em produção), rodar
-- este bloco de migração:
alter table sequencia_separacao add column if not exists etp text;
alter table sequencia_separacao add column if not exists op text;
alter table sequencia_separacao add column if not exists local text;
alter table sequencia_separacao add column if not exists unidade text;

-- Nenhuma mudança de RLS/Realtime necessária — a tabela já está com o
-- padrão hardened (`tem_acesso_tela`) e já publica pro Realtime desde que
-- foi criada; colunas novas só nullable não exigem nada além do
-- `add column` acima.
