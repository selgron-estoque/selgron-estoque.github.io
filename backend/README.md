# Gestão de Estoques — Backend de Sincronização (Supabase)

Esta pasta contém o banco (schema.sql) e a função que mantém o saldo sincronizado
com o Protheus. É o que falta para o Gestão de Estoques sair do protótipo (dados em
memória) e virar sistema real.

## 1. Criar o projeto Supabase

```bash
npx supabase init
npx supabase link --project-ref <seu-project-ref>
```

## 2. Aplicar o schema

```bash
npx supabase db push
```

Isso cria todas as tabelas do `schema.sql`: catálogo, saldo (cache), endereços
(mestre no Supabase), inventários + snapshot, contagens e a função
`congelar_saldo_inventario`.

## 3. Configurar os segredos da função de sincronização

```bash
npx supabase secrets set PROTHEUS_API_URL=https://protheus.empresa.com/api/estoque/v1/saldo
npx supabase secrets set PROTHEUS_TOKEN=<token do endpoint do Protheus>
```

`SUPABASE_URL` e `SUPABASE_SERVICE_ROLE_KEY` já ficam disponíveis automaticamente
para toda Edge Function — não precisa configurar.

## 4. Deploy da função

```bash
npx supabase functions deploy sync-saldo-protheus
```

## 5. Agendar a sincronização

Duas opções, escolha uma:

**A) Supabase Scheduled Triggers (mais simples)** — no painel do Supabase,
em Database → Cron Jobs, criar um job que chama a função a cada 4 horas (ou o
intervalo que fizer sentido para o volume de movimentação do almoxarifado):

```sql
select cron.schedule(
  'sync-saldo-protheus-4h',
  '0 */4 * * *',
  $$ select net.http_post(
       url:='https://<seu-project-ref>.supabase.co/functions/v1/sync-saldo-protheus',
       headers:='{"Authorization": "Bearer <SERVICE_ROLE_KEY>"}'::jsonb
     ) $$
);
```

**B) Scheduler externo** — GitHub Actions, cron de servidor, etc., fazendo um
`POST` autenticado no endpoint da função. Útil se preferir manter o
agendamento fora do banco.

## 6. Congelar saldo ao criar um inventário

Isso **não** é uma Edge Function — é uma função SQL simples, chamada via RPC
direto do front-end (Supabase JS client), logo depois de inserir a linha em
`inventarios`:

```js
const { data: inv } = await supabase.from('inventarios').insert({...}).select().single();
await supabase.rpc('congelar_saldo_inventario', { p_inventario_id: inv.id });
```

A partir daí, toda contagem desse inventário compara contra
`inventario_itens.saldo_congelado` — nunca contra `estoque_saldo` ao vivo.

## 7. Endereços — não precisa de sincronização nenhuma

Diferente do saldo, o endereço é escrito direto pelo Gestão de Estoques no Supabase —
não existe fonte externa para puxar. O fluxo já desenhado no front-end
(operador informa → líder confirma) vira, no backend, simplesmente:

```js
// operador informa (grava proposta pendente)
await supabase.from('endereco_propostas').insert({
  produto_codigo, endereco_informado, usuario_id,
});

// líder confirma
await supabase.from('endereco_propostas').update({
  status: 'confirmado', resolvido_por, resolvido_em: new Date().toISOString(),
}).eq('id', propostaId);

await supabase.from('enderecos').insert({ codigo: enderecoInformado, almoxarifado });
```

## 8. Como o front-end (Gestão de Estoques) deve ler os dados, resumindo

| Tela | De onde lê |
|---|---|
| Criar inventário / buscar item (contagem manual) | `produtos` + `estoque_saldo` (cache, atualizado a cada sync) |
| Durante a contagem (comparação da contagem cega) | `inventario_itens.saldo_congelado` (nunca `estoque_saldo` direto) |
| Endereço do item | `estoque_enderecos` / `enderecos` |
| Item sem endereço cadastrado | ausência de linha em `estoque_enderecos` → aciona o fluxo de "informar endereço" |
| "Última sincronização" (mostrar na tela de Configurações) | `max(concluido_em)` de `sync_log where status = 'sucesso'` |

Recomendo mostrar esse "última sincronização" em algum lugar visível do app
(a tela de Configurações do protótipo já tem um painel "Origem dos Dados" —
é o lugar natural para isso) para que líder/operador saibam se o saldo que
estão vendo é de agora há pouco ou de ontem à noite.

## 9. Migrar login pro Supabase Auth

Login hoje é 100% local (senha em texto puro numa tabela espelho, sessão
falsificável no `localStorage`). Esta seção troca isso pelo Supabase Auth de
verdade — siga a ordem exatamente, ela foi desenhada pra nenhum passo travar
o app que as 4 pessoas já usam no dia a dia.

**9.1 — Confirmar que não sobrou nenhuma foreign key solta apontando pra
`usuarios`** (SQL Editor):

```sql
select conname, conrelid::regclass, confrelid::regclass
from pg_constraint
where confrelid = 'usuarios'::regclass;
```

Se vier alguma linha, me avise antes de continuar — pode ser preciso
dropar essa constraint (o app não usa esses campos, mas quero confirmar
antes de qualquer coisa).

**9.2 — Rodar o bloco de migração** (`schema.sql`, seção "MIGRAÇÃO — LOGIN
VIA SUPABASE AUTH DE VERDADE") no SQL Editor. Isso renomeia a tabela
`usuarios` atual pra `usuarios_pre_auth_backup` (nada é apagado) e cria a
`usuarios` nova, vazia, já ligada ao Supabase Auth. **O app que já está no
ar continua funcionando normalmente neste momento** — ele ainda loga contra
o código antigo, que nem sabe que essa tabela nova existe.

**9.3 — Coletar um e-mail real de cada uma das 4 pessoas** que usam o
sistema hoje (Supabase Auth exige e-mail de verdade por conta).

**9.4 — Criar os 4 usuários no Supabase Auth**: Dashboard → Authentication →
Users → "Add user" — um por vez, usando o e-mail real + uma senha
temporária à sua escolha (repasse pra pessoa por fora, como já faz hoje com
senha temporária). Anote o UUID de cada um (aparece na lista, ou rode
`select id, email from auth.users;` no SQL Editor).

**9.5 — Reconciliar os dados**: no SQL Editor, rodar o `insert` de
reconciliação (modelo no mesmo bloco de migração do 9.2) uma vez pra cada
pessoa, colando o UUID do 9.4 e o login antigo dela.

**9.6 — Deploy da Edge Function nova**: essa é a primeira vez que uma Edge
Function deste projeto é de fato publicada (a `sync-saldo-protheus`, de uma
etapa anterior, nunca chegou a ser deployada) — então é a primeira vez
rodando o Supabase CLI de verdade neste repositório. Passo a passo, num
terminal, dentro da pasta onde o repositório está clonado no seu
computador (se ainda não tiver clonado, `git clone
https://github.com/selgron-estoque/selgron-estoque.github.io.git` e entre
na pasta):

```bash
# Só na primeira vez (se ainda não tiver feito login no CLI):
npx supabase login

# Liga esta pasta ao projeto Supabase real (project ref = o trecho antes de
# ".supabase.co" na URL do projeto, ex: geeqfpzamexmeketcecu):
npx supabase link --project-ref geeqfpzamexmeketcecu

# Publica a função (o código já está em supabase/functions/usuarios-admin/):
npx supabase functions deploy usuarios-admin
```

Precisa ter o Node.js instalado (o `npx` vem junto) — se o terminal disser
que não conhece o comando `npx`, é isso que falta instalar primeiro.
`SUPABASE_URL`/`SUPABASE_SERVICE_ROLE_KEY` já ficam disponíveis
automaticamente pra função, nada a configurar à parte.

**9.7 — Publicar o novo `index.html`** (o commit/push já entrega isso).

**9.8 — Testar de ponta a ponta antes de seguir**: login com os 4 usuários
reais, e todas as ações de admin — criar um usuário de teste, bloquear/
desbloquear, redefinir senha nos 3 modos (temporária/manual/liberar), e
excluir o usuário de teste. Só avance pro próximo passo depois de confirmar
que tudo isso funciona.

**9.9 — Só depois do 9.8 confirmado**: rodar o bloco "ENDURECIMENTO DE RLS"
do `schema.sql` (fecha o acesso anônimo que `contagens`/`inventarios`/
`enderecos_propostos`/`estoque_saldo` têm hoje — só usuários autenticados
passam a poder ler/gravar essas tabelas).

**9.10 — Alguns dias depois, sem pressa**: `drop table
usuarios_pre_auth_backup;` — limpeza final, só quando estiver confiante de
que a migração foi bem.

### Se algo der errado no meio do caminho

- **Antes do passo 9.7** (novo `index.html` ainda não publicado): totalmente
  reversível, nada foi apagado. `alter table usuarios rename to
  usuarios_broken; alter table usuarios_pre_auth_backup rename to
  usuarios;` desfaz o 9.2 por completo.
- **Depois do 9.7, antes do 9.9**: se o login novo não funcionar em
  produção, me avise — a correção é republicar a versão anterior do
  `index.html`, sem precisar mexer no banco.
- **9.9 é o único passo que pode travar tráfego de verdade** se rodado cedo
  demais — por isso é sempre o último, e só depois do 9.8 confirmado.

## 10. Sincronização em tempo real (Supabase Realtime)

Depois da migração de login, o app trocou o polling de 30s (cada aparelho
perguntando "tem algo novo?" de tempos em tempos) por sincronização
instantânea via Supabase Realtime — contagens, inventários, endereços
propostos e usuários agora aparecem em outros aparelhos na hora, sem
esperar.

**10.1 — Confirmar o estado da publicação de Realtime** (SQL Editor):

```sql
select schemaname, tablename from pg_publication_tables where pubname = 'supabase_realtime';
```

Se alguma das 4 tabelas (`contagens`, `inventarios`, `enderecos_propostos`,
`usuarios`) já aparecer na lista, remova-a do comando do passo 10.2 antes
de rodar (evita erro de "already member of publication").

**10.2 — Habilitar a replicação** (SQL Editor):

```sql
alter publication supabase_realtime add table contagens, inventarios, enderecos_propostos, usuarios;
```

Não precisa de nenhuma policy de RLS nova — o Realtime já respeita as
policies `auth.role() = 'authenticated'` que essas tabelas já têm (seção 9.9
acima).

**10.3 — Publicar o novo `index.html`** (o commit/push já entrega isso) —
sem risco de travar login/contagem: se o Realtime não conseguir conectar
por algum motivo, a carga inicial de dados (fetch normal, mesmo de sempre)
continua funcionando, só a atualização instantânea entre aparelhos que
fica comprometida até resolver.

**10.4 — Testar com dois aparelhos (ou duas abas do navegador)**: logado
nos dois ao mesmo tempo, crie/edite algo num (uma contagem, um inventário,
um usuário) e confirme que aparece no outro em poucos segundos, sem
precisar recarregar a página.

## 11. Configurações do app compartilhadas entre aparelhos (`app_config`)

Antes desta seção, 3 configurações da tela "Configurações" (Visibilidade do
Saldo na Contagem, Grupos Excluídos da Contagem Automática, Tempo de
Inatividade) ficavam salvas só no `localStorage` do aparelho onde o admin
mexeu — não tinham efeito nenhum nos tablets dos operadores. O cliente
pediu que qualquer configuração reflita em todos os aparelhos de imediato,
então elas passaram a morar numa única linha (`app_config`, `id` fixo = 1)
no banco, sincronizada por Realtime — mesmo mecanismo da seção 10.

**11.1 — Rodar o SQL novo** (SQL Editor, se ainda não aplicado): a criação
da tabela `app_config`, a função `eh_admin`, as policies e o
`alter publication` já estão no `backend/schema.sql` atualizado, no bloco
logo depois da seção "SINCRONIZAÇÃO EM TEMPO REAL" — cole e rode esse
bloco inteiro.

**11.2 — Confirmar a publicação de Realtime** (mesma introspecção da seção
10.1, ela já cobre `app_config` se você rodou o SQL depois de atualizar o
arquivo):

```sql
select schemaname, tablename from pg_publication_tables where pubname = 'supabase_realtime';
```

Se `app_config` não aparecer na lista, rode só essa linha:

```sql
alter publication supabase_realtime add table app_config;
```

**11.3 — Testar**: abra o app em dois aparelhos (ou duas abas), logado como
admin num deles. Mude qualquer uma das 3 configurações e confirme que o
outro aparelho (mesmo logado como operador) reflete a mudança em poucos
segundos, sem recarregar a página — é exatamente esse o comportamento que
motivou a migração.

## 12. Saldo "ao vivo" na contagem (proxy pra consulta.selgron.com.br)

Nova Edge Function, `consultar-produto-selgron` — busca saldo/endereço/
armazém/unidade **ao vivo**, direto da consulta interna da Selgron
(`https://consulta.selgron.com.br/produto.consulta.php`, por trás dela está
o Protheus), no exato momento em que o operador abre um item pra contar
(`CountStep`). Diferente do saldo cacheado no Supabase (`estoque_saldo`,
atualizado só quando alguém sobe a planilha SB2 manualmente), esse número
nunca fica desatualizado por uma baixa/movimentação recente. Se a consulta
falhar por qualquer motivo (rede, credencial expirada, formato da página
mudou), a tela cai de volta pro saldo já em cache **sem quebrar nem travar
a contagem** — é só um reforço opcional, nunca uma dependência obrigatória.

**Diferente de tudo que já existe neste projeto**: essa function não grava
nada no Supabase (é um proxy puro — busca fora, devolve pro navegador) e
usa **login/senha reais de um funcionário da Selgron** (não uma conta de
serviço separada — não havia essa opção disponível no momento), guardados
só como secret do Supabase, nunca em código nem commitados.

**12.1 — Guardar as credenciais como secret** (terminal, na pasta onde o
repositório está clonado — mesmo terminal já usado nas seções 9.6/anteriores):

```bash
npx supabase secrets set CONSULTA_SELGRON_USER=<seu_usuario_de_login>
npx supabase secrets set CONSULTA_SELGRON_PASS=<sua_senha>
```

**Rode você mesmo, no seu terminal — nunca me envie a senha pelo chat.**
São os mesmos usuário/senha que já abrem
`https://consulta.selgron.com.br/produto.consulta.php` no navegador (aquela
janela nativa de login do próprio navegador, não um formulário da página).

**12.2 — Deploy da function** (mesmo terminal):

```bash
npx supabase functions deploy consultar-produto-selgron
```

Deploy padrão, com verificação de sessão ligada (mesmo padrão de
`usuarios-admin`) — só quem já está logado no Gestão de Estoques consegue
chamar essa function.

**12.3 — Testar**: abra qualquer fluxo de contagem (Nova Contagem Manual é
o mais rápido pra testar), busque um código que você sabe que existe na
consulta Selgron, e confira que o campo "Sistema" na tela ganha o texto
"(ao vivo)" ao lado — e que aparece um card extra "Endereço (consulta
Selgron)" quando esse item tem endereço cadastrado lá. Se a etiqueta "(ao
vivo)" nunca aparecer (mesmo pra um código que você confirmou existir na
consulta), veja o **12.4** abaixo.

**12.4 — Se o parser não estiver reconhecendo os campos**: o parser HTML
desta function (`htmlParaTexto`/`extrairCampo`, dentro de
`supabase/functions/consultar-produto-selgron/index.ts`) foi construído só
a partir de **screenshots** da página (não do HTML cru) — é resistente a
pequenas variações de marcação (não depende de uma tag específica), mas
pode precisar de um ajuste fino contra a página real. Se acontecer, no
navegador: abra a consulta, faça uma busca, botão direito → "Ver código-
fonte da página" (ou `Ctrl+U`) → copie o HTML inteiro e me envie — ajusto o
parser em minutos com o HTML de verdade em mãos, em vez de screenshot.

### Escopo — saldo sempre sobrescrito; endereço só quando o item ainda não tem cadastro

O saldo "Sistema" mostrado na tela E gravado na contagem passa a usar o
valor ao vivo quando a consulta funciona. O **endereço/armazém** vindos da
consulta sempre aparecem como um card informativo à parte
("Endereço (consulta Selgron)"), e **também** pré-preenchem o campo de
"onde você encontrou o item" — mas só quando o item ainda **não** tem
endereço cadastrado no sistema (etapa em que o operador hoje precisa
digitar/escanear do zero). Continua exigindo confirmação humana (o
operador clica "Confirmar e continuar", nada acontece sozinho) e a mesma
validação do líder de sempre. Item que **já tem** endereço cadastrado
continua 100% no fluxo de confirmação por QR Code de sempre, sem nenhuma
influência da consulta ao vivo — nenhuma mudança nesse caso.

## 13. "SAs em Aberto" — desempenho do almoxarifado (consulta de sa_aberto.php)

Página nova (Análise → "SAs em Aberto") que acompanha o tempo que o
almoxarifado leva pra atender cada Solicitação ao Almoxarifado (SA), contra
uma meta de menos de 2 dias (48h corridas). Substitui a rotina manual de
visitar `https://consulta.selgron.com.br/sa_aberto.php` todo dia.

**Como funciona**: uma Edge Function nova, `sync-sa-almoxarifado`, consulta
essa página periodicamente (a cada 30 min, via `pg_cron` — item 13.4 abaixo)
e reconcilia contra a tabela `sa_almoxarifado`: toda SA encontrada na
consulta fica/continua `'aberta'`; toda SA que estava `'aberta'` no banco e
**não apareceu** nesta rodada vira `'atendida'`, com a hora deste poll como
o momento em que o atendimento foi detectado (é a única forma de saber
quando uma SA "sumiu" — a página só mostra o que ainda está pendente, nunca
um histórico). O app nunca lê a página da Selgron direto — só lê a tabela
`sa_almoxarifado`, que essa função mantém em dia.

### 13.1 — Reaproveita as credenciais já configuradas (seção 12)

`sync-sa-almoxarifado` usa os MESMOS secrets já configurados pra
`consultar-produto-selgron` (`CONSULTA_SELGRON_USER`/`CONSULTA_SELGRON_PASS`)
— é o mesmo domínio `consulta.selgron.com.br`. **Se ao testar (13.3) a
página de SA pedir login diferente do de produto/kardex**, configure
secrets próprios só pra essa função:

```bash
npx supabase secrets set SA_ALMOXARIFADO_USER=<usuario>
npx supabase secrets set SA_ALMOXARIFADO_PASS=<senha>
```

— e me avise, que eu troco a function pra ler esses dois nomes em vez dos
de produto/kardex.

### 13.2 — Rodar o SQL

No SQL Editor do projeto, cole o bloco `sa_almoxarifado` (final de
`backend/schema.sql`, seção "'SAs EM ABERTO'"). Introspecção recomendada
antes, mesmo cuidado de sempre:

```sql
select table_name from information_schema.tables where table_name = 'sa_almoxarifado';
select schemaname, tablename from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'sa_almoxarifado';
```

**Se você já rodou uma versão anterior deste bloco** (chave primária só
`numero_sa`) — sem problema, o bloco atual já começa com `drop table if
exists sa_almoxarifado cascade;` antes de recriar a tabela no formato
certo. É seguro porque essa tabela é só um espelho da consulta (sem FK
apontando pra ela, sem dado que não seja resincronizado sozinho no próximo
poll de 30 min ou num "Sincronizar agora" manual) — nada real é perdido.

### 13.3 — Deploy e teste manual

```bash
npx supabase functions deploy sync-sa-almoxarifado
```

Deploy padrão (com verificação de JWT, mesmo padrão das outras). Depois do
deploy, teste SEM esperar o cron: abra a tela "SAs em Aberto" no app
(perfil líder/admin) e clique **"Sincronizar agora"** — ela chama a
function na hora e mostra quantas SAs foram encontradas/atendidas nesta
rodada. Se der erro, o texto aparece direto na tela (mesma mensagem que a
function devolveu).

### 13.4 — Agendar a sincronização automática (a cada 30 min)

Mesma técnica já documentada na seção 5 (`pg_cron`+`pg_net`), SQL Editor:

```sql
select cron.schedule(
  'sync-sa-almoxarifado-30min',
  '*/30 * * * *',
  $$ select net.http_post(
       url:='https://<seu-project-ref>.supabase.co/functions/v1/sync-sa-almoxarifado',
       headers:='{"Authorization": "Bearer <SERVICE_ROLE_KEY>"}'::jsonb
     ) $$
);
```

Troque `<seu-project-ref>` pelo ref do projeto (o mesmo já usado nas outras
seções) e `<SERVICE_ROLE_KEY>` pela chave de serviço (Project Settings →
API → `service_role` — **nunca** a `anon`/publishable key aqui, essa
chamada precisa de privilégio de escrita). Depois de rodar, confirme que o
job foi criado:

```sql
select jobid, jobname, schedule, active from cron.job where jobname = 'sync-sa-almoxarifado-30min';
```

### 13.5 — Parser já calibrado contra o HTML real (achados que mudaram o desenho)

O parser (`extrairSasAbertas`, dentro de
`supabase/functions/sync-sa-almoxarifado/index.ts`) foi escrito
inicialmente sem nunca ter visto o HTML real — mesma situação inicial que
`consultar-produto-selgron`/Kardex tiveram. Você mandou o HTML real (via
"Ver código-fonte da página") e isso revelou dois achados que mudaram o
desenho, não só ajustaram o parser:

1. **"Numero" (a SA) não é único por linha.** Uma SA pode pedir vários
   materiais diferentes — cada um numa linha própria, numerada pela coluna
   "Item" (01, 02, 03... dentro da MESMA SA). A tabela `sa_almoxarifado`
   passou a ter `chave` (SA+Item) como identidade — ver 13.2. Isso importa
   na prática: se uma SA pede 3 materiais e só 1 é atendido, só aquele item
   sai da lista de "aberta" — os outros 2 continuam pendentes normalmente,
   cada um contando pro tempo em aberto/meta de forma independente.
2. **A coluna "Emissao" só tem DATA, nunca hora.** "Tempo em aberto"/
   "dentro da meta" são calculados a partir dela (ver 13.6) — sem hora
   exata de abertura, pode haver até ~24h de imprecisão nesse cálculo. É
   uma limitação real da própria página (ela não expõe hora de abertura),
   não algo que o parser consiga contornar.

O parser resolve colunas pelo NOME do cabeçalho (Numero/Solicitante/
Emissao/Item/Cod Produto/Descricao/Quant/Almox — os demais campos da
página, como Saldo SA/Saldo Estoque/Centro de Custo, não são usados de
propósito, pra não poluir a tela) e reconhece a estrutura real da tabela
(`id='tbemp'`, gerada por DataTables, com cabeçalho duplicado em `<thead>`
e `<tfoot>` — só o `<tbody>` conta como dado).

**Se "Sincronizar agora" (13.3) devolver "Nenhuma SA reconhecida no
HTML"** — pode acontecer se a Selgron mudar o formato da página no futuro
— **nenhum dado é apagado/alterado**: a função para sozinha antes de mexer
em qualquer linha, por segurança (nunca marca tudo como "atendido" só
porque parou de reconhecer o formato). Nesse caso, mande o HTML real de
novo (mesmo processo de sempre — "Ver código-fonte"/`Ctrl+U`) que eu
recalibro.

**Uma coisa que ainda não foi confirmada, só pelo teste em produção
mesmo**: o parser foi calibrado contra o HTML estático que você mandou, mas
a function em si (`fetch()` autenticado contra `sa_aberto.php` de verdade,
via Basic Auth) nunca foi testada ao vivo — o primeiro "Sincronizar agora"
depois do deploy é o teste real disso.

### 13.6 — O que fica calculado só no front-end (não em coluna nenhuma)

"Tempo em aberto", "Dentro/Fora da meta" e "SAs vencidas" nunca são colunas
gravadas — são sempre calculados na hora, comparando `aberta_em` contra
`atendida_em` (SA já atendida) ou contra "agora" (SA ainda aberta) — é
assim que uma SA aberta há mais de 48h aparece "Fora da meta" na tela
mesmo sem nenhuma sincronização nova ter rodado nesse meio-tempo.

**`aberta_em` vem da coluna "Emissao", que só tem data (sem hora)** — é
gravada como meia-noite daquele dia. Consequência honesta: "tempo em
aberto" pode ter até ~24h de imprecisão em relação ao momento exato em
que a SA foi de fato aberta no Protheus — não é um bug do parser, é uma
limitação real da página de origem.

## 14. Rodada de segurança e confiabilidade — recuperação de senha por token, autorização granular, RLS por papel/ação

Esta seção documenta uma rodada de correções pedida explicitamente com foco
em segurança/confiabilidade — trata 4 problemas de RISCO REAL (não só
organização de código) que existiam desde as rodadas anteriores:

1. **`auto_definir_senha` aceitava só o `userId`** como se fosse uma
   credencial — qualquer um que soubesse (ou adivinhasse) o UUID de outra
   pessoa conseguia definir a senha dela, sem precisar de nenhum token/
   confirmação. Vira um fluxo de token aleatório de uso único, com
   expiração curta, hash em repouso.
2. **A exceção `'usuarios'` em `acessos_extras`** (pensada só pra deixar um
   líder gerenciar usuário comum) dava, na prática, poder IRRESTRITO — dava
   pra criar/promover admin, editar/bloquear/resetar senha de outro admin,
   e excluir qualquer usuário. Vira autorização granular por ação.
3. **A maior parte das tabelas operacionais** (`contagens`/`inventarios`/
   `estoque_saldo`/`produtos`/`enderecos`/`estoque_enderecos`) só distinguia
   "autenticado" de "anônimo" — qualquer operador, chamando a API REST/RPC
   direto (sem passar pela UI, que já restringia por perfil só no
   front-end), conseguia aprovar divergência, excluir contagem/inventário,
   sobrescrever saldo do sistema, editar catálogo. Vira RLS por papel/ação.
4. **`resolver_login`** devolvia `id`/`email`/`status` de QUALQUER
   identifier tentado, mesmo antes de validar senha — um oráculo de
   enumeração de usuários, e o `id` devolvido já tinha sido, no passado,
   aceito como credencial sozinha pelo problema 1. Fica travada, sem grant
   pra `anon`/`authenticated`.

**Nenhum dado foi apagado.** Todo SQL novo desta rodada é aditivo
(`create table if not exists`) ou reversível (`create or replace function`,
`drop policy if exists` seguido de `create policy` — sempre o mesmo nome
que já existia, nunca um nome novo "por cima" do antigo).

### 14.1 — Tabelas novas: recuperação de senha por token

No SQL Editor, rode o bloco "RECUPERAÇÃO DE SENHA — token de uso único,
hash em repouso, expiração curta" do `schema.sql` (cria `password_reset_
tokens` e `password_reset_requests`, as duas com RLS habilitado e **zero**
policy pra `anon`/`authenticated` — só a Edge Function, rodando com a
service role key, toca essas tabelas). Seguro rodar contra o banco já em
produção — são tabelas novas, `if not exists`, sem nenhuma dependência de
dado já existente.

```sql
-- Confirma que as duas tabelas não existiam antes (evita rodar à toa se já
-- tiver aplicado esta seção antes):
select table_name from information_schema.tables
where table_name in ('password_reset_tokens', 'password_reset_requests');
```

### 14.2 — Travar `resolver_login`

Uma única linha, isolada e segura de rodar a qualquer momento (revogar algo
já revogado, ou revogar de uma função que ainda tem grants, nunca dá erro):

```sql
revoke all on function public.resolver_login(text) from public, anon, authenticated;
```

Depois de rodar isso, `resolver_login` só é chamável pelo dono da função
(o superusuário `postgres`/o painel do Supabase) — nenhum client (nem
`anon`, nem um usuário já logado) consegue mais chamá-la. **Isso não quebra
o login** — a resolução "usuário ou e-mail → e-mail real" migrou pra dentro
da nova Edge Function `auth-publico` (ação `login`), que já faz essa
resolução com a service role key (ignora RLS, não depende de nenhuma
função `security definer` chamável por fora) — ver 14.4.

### 14.3 — RLS por papel/ação nas tabelas operacionais

No SQL Editor, rode o bloco "CORREÇÃO DE SEGURANÇA: RLS POR PAPEL/AÇÃO NAS
TABELAS OPERACIONAIS" do `schema.sql` (a partir do comentário com esse
título, até o fim do arquivo). Cobre `contagens`, `inventarios`,
`enderecos_propostos`, `estoque_saldo`, `produtos`, `enderecos`,
`estoque_enderecos`, `item_reservas` e `etiquetas_fila` — sempre
`drop policy if exists "<nome exato que já existia>" ...` antes de criar a
policy nova, então é seguro rodar mais de uma vez (reaplicar não dá erro,
só recria a mesma coisa).

**Antes de rodar**, se quiser confirmar que os nomes de policy que o
bloco vai dropar realmente batem com o que está no seu projeto (evita
qualquer susto, mesmo padrão de cautela já usado nas rodadas anteriores
deste projeto):

```sql
select tablename, policyname, cmd
from pg_policies
where tablename in (
  'contagens','inventarios','enderecos_propostos','estoque_saldo',
  'produtos','enderecos','estoque_enderecos','item_reservas','etiquetas_fila'
)
order by tablename, cmd;
```

Depois de rodar o bloco, um **operador comum** deixa de conseguir, via API
direta: aprovar/rejeitar divergência, marcar urgente, atribuir, gerar SA,
aprovar/reprovar Diretoria, excluir contagem ou inventário, sobrescrever
`estoque_saldo`/`produtos` (só admin). Editar `enderecos`/
`estoque_enderecos`/`enderecos_propostos`/`etiquetas_fila` fica liberado
pra líder/admin OU pra quem tiver a exceção `'enderecos'`/`'etiquetas'`
concedida via "Acesso por tela" (mesmo mecanismo que já libera a TELA
correspondente — ver seção 14.12, correção aplicada depois de um bug real
em produção) — um operador comum sem essa exceção continua bloqueado.
**Nada muda pro fluxo normal de contar** — inserir uma contagem nova,
avançar `contados` numa fila, ler qualquer uma dessas tabelas continuam
liberados pra qualquer autenticado, exatamente como já funcionava.

**Este mesmo bloco também conserta, de graça, um bug real que fazia
`reservar_item` (a trava de "item já sendo contado por outro operador")
nunca funcionar — ver seção 14.11 antes de rodar, pra saber o que
esperar.** (E, se você já rodou este bloco antes de ler a seção 14.12,
rodá-lo de novo já aplica a correção de lá também — é idempotente.)

**Atenção a uma ambiguidade real, que não dá pra resolver só lendo o
arquivo**: a tabela `usuarios` também foi reescrita — não mais espalhada em
3 gerações sucessivas ao longo do arquivo, agora definida uma única vez
(já no formato Auth atual) perto do topo. Pra um banco **novo**, isso é
exatamente o que se quer. Pro banco **já em produção** (que já passou pela
migração da seção 9), não dá pra saber com certeza, sem consultar o banco
de verdade, se o texto exato dessa definição (nomes de policy, colunas)
já bate 100% com o que está lá — bem provável que sim (o comportamento
descrito bate com o que a seção 9 já deixou aplicado), mas não confirmado.
**Recomendação: não rode esse bloco específico (o `create table usuarios`
do topo do arquivo) contra o banco em produção sem antes comparar** — rode
a introspecção abaixo e só ajuste o que realmente divergir:

```sql
select column_name, data_type, is_nullable
from information_schema.columns where table_name = 'usuarios'
order by ordinal_position;

select policyname, cmd, qual, with_check
from pg_policies where tablename = 'usuarios';
```

Se as colunas/policies já baterem com o que está descrito no topo do
`schema.sql`, não precisa rodar nada daquele bloco — ele só existe pra
documentar o formato final, útil pra um banco novo, não pra reaplicar aqui.

### 14.4 — Deploy da Edge Function nova: `auth-publico`

Primeira vez que este projeto separa ações ADMINISTRATIVAS (sempre
autenticadas — `usuarios-admin`) de ações PÚBLICAS (nunca autenticadas —
login, "esqueci minha senha", confirmar token — `auth-publico`). Mesmo
terminal/pasta já usado nos deploys anteriores (ver seção 9.6 se for a
primeira vez):

```bash
npx supabase functions deploy auth-publico
```

Não precisa de nenhum secret novo — usa as mesmas
`SUPABASE_URL`/`SUPABASE_SERVICE_ROLE_KEY` que toda Edge Function deste
projeto já recebe automaticamente.

### 14.5 — Redeploy da Edge Function existente: `usuarios-admin`

O código mudou bastante (autorização granular por ação, ver 14.6) — precisa
de um redeploy, mesmo comando de sempre:

```bash
npx supabase functions deploy usuarios-admin
```

### 14.6 — O que mudou em `usuarios-admin` (autorização granular)

Antes, a checagem de permissão era só "é admin OU tem a exceção
`'usuarios'`" — as duas liberavam QUALQUER ação por igual. Agora,
`podeExecutar()` (dentro da function) decide por AÇÃO:

- **Administrador de verdade**: pode tudo, sem exceção.
- **Quem tem a exceção `'usuarios'` (líder ou operador, concedida via
  "Acesso por tela" no `UserForm`)**: pode criar/editar/bloquear/redefinir
  senha de usuário **não-admin**, mas nunca:
  - criar ou promover ninguém a admin;
  - tocar (editar/bloquear/redefinir senha) numa conta que **já** é admin;
  - **excluir** ninguém — exclusão continua sempre admin-only, mesmo com a
    exceção.
- **Qualquer outro chamador** (operador sem a exceção, ou não autenticado):
  nenhuma ação.

Nenhuma mudança de comportamento pra quem é admin de verdade — essa
correção só reduz o poder de quem tinha a exceção `'usuarios'` sem ser
admin. Se hoje algum líder com essa exceção legitimamente PRECISA criar/
promover um admin, isso passou a exigir um admin de verdade fazer essa
ação específica — decisão deliberada (ver acceptance criteria do pedido:
"Apenas administradores reais devem poder criar/promover administradores").

### 14.7 — Bug corrigido: tela de "Nova senha" travava sem sessão

`chamarUsuariosAdmin()` (usada por toda ação ADMINISTRATIVA) sempre chama
`refreshSession()` antes de invocar a Edge Function — correto pra ação
autenticada, mas a tela de "Nova senha" (fluxo de recuperação, acessado
por quem **não tem sessão nenhuma**, de propósito) chamava essa mesma
função, travando ali mesmo antes da Edge Function ser sequer chamada. Fica
resolvido pela própria separação: o fluxo de recuperação (`recuperar_
solicitar`/`recuperar_confirmar`) agora passa por `invocarAuthPublico()`,
uma função irmã que **nunca** chama `refreshSession()` — funciona
igualmente bem logado ou deslogado, porque as duas ações não fazem sentido
nenhum como "administrativas autenticadas" pra começar.

### 14.8 — Ordem recomendada pra aplicar tudo isso

1. 14.1 (tabelas novas) — sem risco, aditivo puro.
2. 14.2 (travar `resolver_login`) — sem risco, reversível
   (`grant execute on function public.resolver_login(text) to anon;`
   desfaz, se precisar por algum motivo).
3. 14.4 (deploy `auth-publico`) — a função nova só passa a ser CHAMADA
   depois que o `index.html` novo for publicado (14.9); publicá-la antes
   não quebra nada, só fica sem uso ainda.
4. 14.5 (redeploy `usuarios-admin`) — o código novo (`podeExecutar`) só
   muda o resultado de chamadas feitas pelo `index.html` NOVO; o `index.html`
   antigo, ainda no ar, continua chamando as mesmas ações de sempre e
   continua funcionando (a checagem fica mais granular, não mais
   restritiva pra quem já era admin).
5. **Publicar o `index.html` novo** (push já faz isso, GitHub Pages) — só
   a partir daqui o fluxo de recuperação por token e a autorização granular
   passam a valer de verdade na tela.
6. **Testar de ponta a ponta antes de seguir pro próximo passo** — roteiro
   completo no relatório final desta rodada (login normal; "esqueci minha
   senha" gerando e confirmando um token de teste; um usuário com a
   exceção `'usuarios'` tentando promover alguém a admin, esperando ver o
   erro).
7. 14.3 (RLS por papel/ação) — **por último, de propósito**, mesmo
   raciocínio já usado na 9.9: só depois de confirmar que o `index.html`
   novo funciona ponta a ponta. Rodar esse bloco cedo demais (com o app
   antigo ainda no ar, ou sem confirmar que os fluxos novos funcionam)
   pode bloquear uma ação que o app antigo ainda tentava fazer de um jeito
   que a RLS nova não reconhece mais. **Este passo também corrige, sem
   ação extra nenhuma, os 2 bugs reais descritos na seção 14.11** — vale
   ler antes de rodar, só pra saber o que esperar.

### 14.9 — Dependências de CDN fixadas em versão exata

`@supabase/supabase-js` e `jsbarcode` (as duas únicas que ainda estavam
soltas em `@2`/`@3`, sem versão exata) foram fixadas em `2.112.3`/`3.12.3`
— mesmo comportamento de antes, só sem risco de receber um patch novo
sem revisão nenhuma. Não precisa de nenhuma ação no Supabase — é só
`index.html`, já publicado junto do resto.

**SRI (Subresource Integrity) não foi adicionado** a nenhuma das 7 tags
`<script src="https://cdn...">` — ver "Limitações" no relatório final desta
rodada, é uma limitação do ambiente onde esta correção foi feita, não uma
decisão de não fazer.

### 14.10 — Modularização do `index.html`: não feita nesta rodada, roteiro pra fazer depois

O pedido original incluía "separar, gradualmente e sem reescrever tudo de
uma vez, o `index.html` em módulos de autenticação, acesso a dados e UI".
**Decisão desta rodada: não mexer nisso agora** — não porque seja difícil,
mas porque este projeto não tem build step (Babel Standalone via CDN,
sem bundler) nem forma de abrir o app num navegador de verdade neste
ambiente pra confirmar visualmente que uma separação de arquivo não quebrou
nada — o único jeito de verificar aqui é reler o código e rodar transpile/
testes automatizados, insuficiente pra garantir que a ORDEM de carregamento
de múltiplos `<script>` (sem bundler, sem module system real) continua
funcionando igual num navegador de verdade. Preferi não arriscar quebrar um
app em produção sem esse tipo de confirmação, principalmente por ser
literalmente o único item desta lista sem nenhum ganho de segurança direto
(é organização de código).

**Roteiro pra fazer isso com segurança, quando quiser seguir**: começar
pelo pedaço de MENOR risco — funções puras, sem JSX, sem hook de React
(ex.: `formatEnderecoInput`/`compararPorEndereco`/`parseEnderecoPartes`/
os formatadores de data/moeda) — extrair pra um arquivo `utils.js` comum,
carregado via `<script src="./utils.js"></script>` ANTES do
`<script type="text/babel">` principal (os nomes ficam disponíveis no
escopo global, sem precisar de `import`/`export`, mesmo jeito que
`html5-qrcode`/`xlsx`/`JsBarcode` já são carregados hoje). Só depois de
confirmar isso funcionando de verdade no navegador (não só no sandbox),
seguir pro próximo pedaço (ex.: as funções `fetchX`/`saveXToSupabase` de
acesso a dados, que também não têm JSX). Deixar por último qualquer coisa
com componente React/JSX — é onde a co-localização com Babel importa mais
e onde um erro de separação é mais fácil de não perceber sem abrir o app
de verdade.

### 14.11 — Dois bugs reais achados testando contra um Postgres de verdade

As rodadas anteriores desta lista foram verificadas por transpile Babel,
balanceamento de chaves de CSS, harness jsdom/`react-dom`, e `tsc --strict`
pras Edge Functions — nunca por EXECUÇÃO real de SQL contra um banco de
verdade (o sandbox onde este trabalho foi feito não tinha acesso a rede
pro Supabase real). Nesta rodada, descobri que o sandbox tinha PostgreSQL
16 local disponível — subi um banco descartável, criei um stub mínimo do
que a própria plataforma Supabase já provisiona sozinha (schema `auth`,
roles `anon`/`authenticated`/`service_role`, os GRANTs de tabela que a
plataforma concede automaticamente, a publicação `supabase_realtime`) e
apliquei o `backend/schema.sql` de verdade contra ele — a 1ª vez que
qualquer trecho de SQL deste projeto foi de fato EXECUTADO, não só lido.
Isso achou 2 bugs reais que nenhuma verificação anterior tinha pego:

**1. `contagem_itens_prioritarios()` referenciava tabelas antes delas
existirem.** A 1ª definição da função (a mais antiga do arquivo) faz
`left join estoque_enderecos ... left join enderecos ...`, mas essas duas
tabelas só são criadas bem mais abaixo no arquivo — rodar o schema.sql do
começo ao fim num banco novo falhava com
`relation "estoque_enderecos" does not exist` exatamente nesse `create
function`. **Corrigido**: a definição foi movida (mesmo corpo, byte a
byte) pra logo depois da criação de `estoque_enderecos`/`enderecos` — as
duas redefinições seguintes (que já vinham depois, adicionando as colunas
`unidade` e depois `custo_unitario_fallback` — evolução real de schema já
documentada no CLAUDE.md) não precisaram mudar nada.

**2. `reservar_item()` nunca funcionou, em nenhum Postgres, desde que foi
escrita — bug pré-existente, não introduzido por esta rodada de
segurança.** `returns table(produto_codigo text, ...)` cria uma variável
PL/pgSQL implícita chamada `produto_codigo` — que colide com a coluna de
mesmo nome usada em `on conflict (produto_codigo)` dentro do corpo da
função. Toda chamada de `reservar_item(...)` (a trava que impede dois
operadores contarem o mesmo item ao mesmo tempo) sempre falhava com
`ERROR: column reference "produto_codigo" is ambiguous` — em produção,
isso teria feito a "reserva de item" (Configurações → nunca chegou a
funcionar de verdade em nenhum aparelho, mesmo antes desta rodada de
segurança) travar silenciosamente pro operador, sem nenhuma mensagem
clara do motivo. **Corrigido**: adicionado o pragma
`#variable_conflict use_column` logo no início do corpo da função (nos
DOIS lugares do arquivo onde ela é definida — a original e a versão já
endurecida por esta rodada de segurança, com duração fixa de 5 minutos no
servidor) — resolve a ambiguidade a favor da COLUNA da tabela, sem mudar
nenhum outro comportamento.

**Os dois já estão corrigidos no `schema.sql` deste repositório.** Como o
bloco de RLS da seção 14.3 já recria `reservar_item`/`liberar_item_reserva`
via `create or replace function` (idempotente, sem apagar nada), **rodar
aquele bloco no seu projeto real já aplica esta correção de graça** — não
precisa de nenhum passo extra além do que a seção 14.3 já pede. Se você já
tinha notado a "reserva de item" nunca travando de verdade (dois
aparelhos conseguindo abrir o mesmo item pra contar sem aviso nenhum),
essa é provavelmente a causa raiz.

**Verificação, desta vez com execução real, não só leitura estática**:
`backend/schema.sql` aplicado do início ao fim contra um Postgres 16 vazio
(exit 0, zero linha `ERROR`/`FATAL` no log) — confirmação empírica direta
do critério de aceite "o schema base roda em banco vazio sem erro" (as
rodadas anteriores só sustentavam isso por inspeção estrutural do SQL,
nunca por ter rodado de verdade). Em seguida, 12 testes de comportamento
via `set role authenticated; set request.jwt.claim.sub='<uuid>'; ...` (simula
um chamador autenticado específico sem precisar de um JWT de verdade) —
6 controles NEGATIVOS (ação bloqueada) e 4 controles POSITIVOS (a mesma
ação, pelo papel/dono certo, continua funcionando — prova que a
correção não quebrou o uso legítimo), todos passando:

- `reservar_item` com `p_minutos=99999` (malicioso) sempre devolve
  duração de exatamente `00:05:00` — o servidor ignora o parâmetro.
- Operador não insere `contagens` com `status_aprovacao` fora da lista
  permitida (trigger bloqueia) nem aprova via `UPDATE` direto (RLS filtra,
  0 linhas afetadas) — mas **líder consegue** (controle positivo).
- `anon` lê `contagens` e recebe 0 linhas; não consegue chamar
  `resolver_login` (`permission denied for function`).
- Operador não se autopromove a admin via `UPDATE` direto em `usuarios`
  (bypass da Edge Function) — bloqueado no nível do BANCO, não só na
  lógica da Edge Function.
- Operador avança `contados` via `increment_contados` normalmente
  (controle positivo — o único caminho de escrita que ele de fato precisa
  em `inventarios` continua liberado).
- Só o DONO de uma reserva (`item_reservas`) consegue liberá-la via
  `liberar_item_reserva` — outro usuário tentando libera 0 linhas, o
  dono libera normalmente (controle positivo).
- Operador não escreve direto em `estoque_saldo`/`produtos` (RLS
  bloqueia as duas).

O script completo (`stub_supabase_env.sql` + `test_rls_final.sql` +
`run_schema_sql_postgres_live.sh`, que recria um banco descartável, aplica
tudo e roda a suíte inteira sozinho) está preservado no scratchpad da
sessão que fez esta verificação — reaproveitável em qualquer ambiente
com PostgreSQL 16 disponível, sem depender de acesso ao Supabase real.

### 14.12 — Bug real em produção: RLS da seção 14.3 travava um operador com
### exceção concedida via "Acesso por tela" — `tem_acesso_tela` corrige

No mesmo dia em que o cliente aplicou o bloco da seção 14.3 em produção,
um operador (Lucio Schultz), que já tinha recebido a exceção `'etiquetas'`
via "Acesso por tela" (o mecanismo do próprio app — `UserForm`, dual-list
de "Comandos Liberados"/`acessos_extras`, ver CLAUDE.md) e conseguia abrir
a tela normalmente, foi barrado ao clicar "Enviar para Fila" com o erro
`new row violates row-level security policy for table "etiquetas_fila"`.

**Causa raiz**: as policies aplicadas na seção 14.3 usam
`eh_lider_ou_admin(auth.uid())` — checa só o `perfil` da linha em
`usuarios`, sem nenhuma noção do mecanismo de exceção por tela
(`acessos_extras`/`acessos_removidos`). Isso é exatamente correto pras
tabelas cuja tela correspondente já tem um 2º gate de role HARDCODED no
próprio componente, independente de `hasAccess`/`acessosExtras` —
conferido caso a caso: `RecountsPanel.canMark`, `DivergentItemsPanel.
canApprove`, `SolicitacaoArmazemPanel.canDecide`, `DiretoriaApprovalPanel.
canDecide` e `InventoryList.canMark` todos usam `role==='lider'||
role==='admin'` direto, sem caminho de exceção nenhum — pra essas telas
(logo, pra `contagens`/`inventarios`), `eh_lider_ou_admin` continua 100%
correta, **não foi tocada**.

O problema é específico de **duas telas que nunca tiveram esse 2º gate**:
`EtiquetasPanel` e `AddressValidationPanel` — nelas, o acesso à TELA
(`hasAccess`/`ACESSOS_RESTRITOS`, que já honra `acessosExtras`/
`acessosRemovidos`) sempre foi o ÚNICO controle de permissão que o
front-end aplicava, tanto pra ver a tela quanto pra usar a ação dentro
dela. A RLS da seção 14.3, ao usar `eh_lider_ou_admin` (perfil-only) nas
4 tabelas que essas 2 telas escrevem, ficou mais restritiva que o
comportamento que o próprio app sempre teve — um operador com a exceção
concedida passava pela tela, mas era bloqueado no banco.

**Corrigido com uma função nova, `tem_acesso_tela(p_uid, p_tela)`**
(`schema.sql`, logo depois de `eh_lider_ou_admin`) — mirror exato de
`hasAccess(user, viewId)` do `index.html`: admin sempre `true`;
`acessos_removidos` contendo a tela bloqueia mesmo pra líder; `perfil=
'lider'` libera por padrão pras telas deste grupo (mesmo default de
`ACESSOS_RESTRITOS`); senão, só libera se `acessos_extras` contém a tela.
Usa o operador `?` do jsonb (`u.acessos_extras ? p_tela`) — testa se a
string é um elemento de topo do array, mesma semântica de `.includes(...)`
no front-end.

**4 policies trocadas** de `eh_lider_ou_admin(auth.uid())` pra
`tem_acesso_tela(auth.uid(), '<tela>')` — as únicas 4 que correspondem às
2 telas sem 2º gate:

- `etiquetas_fila` (select/insert/update) → `tem_acesso_tela(...,
  'etiquetas')`.
- `enderecos_propostos` (update, "confirmar/rejeitar" em
  `AddressValidationPanel`) → `tem_acesso_tela(..., 'enderecos')`.
- `enderecos` (escrita) → `tem_acesso_tela(..., 'enderecos')` — mesmo
  destino que `aplicarEnderecoConfirmado` já grava junto com
  `enderecos_propostos`.
- `estoque_enderecos` (escrita) → `tem_acesso_tela(..., 'enderecos')` —
  mesma decisão, mesmo par de tabelas que `aplicarEnderecoConfirmado`
  sempre grava junto.

`contagens`/`inventarios`/`estoque_saldo`/`produtos`/`item_reservas`
**não mudaram** — já conferidos como corretos com `eh_lider_ou_admin`/
`eh_admin` puros, sem caminho de exceção em nenhuma tela que os escreve.

**Já está tudo no `schema.sql` deste repositório** — como o bloco inteiro
da seção 14.3 é idempotente (`create or replace function`/`drop policy if
exists` antes de cada `create policy`), **rodar esse bloco de novo no seu
projeto (o mesmo bloco da seção 14.3, do início ao fim) já aplica esta
correção** — não precisa rodar nada separado, só reexecutar o bloco
inteiro mais uma vez. Se você já tinha aplicado a versão antiga (a que
causou o erro do Lucio), o `create or replace function
tem_acesso_tela(...)` mais os 4 `drop policy`/`create policy` corrigidos
substituem exatamente o que já estava lá, sem apagar nenhum dado.

**Verificação**: por leitura direta do código-fonte (`ACESSOS_RESTRITOS`/
`hasAccess`/`perfilLiberaPorPadrao` no `index.html`, e os 5 componentes com
`canMark`/`canApprove`/`canDecide` hardcoded, conferidos um a um pra
confirmar que nenhum outro tem o mesmo problema) — não houve tempo, dado
a urgência do bug em produção, de rodar de novo a suíte de teste contra
Postgres real da seção 14.11 antes de entregar a correção emergencial ao
cliente. **Se quiser essa confirmação empírica**, o mesmo script
(`stub_supabase_env.sql`/`test_rls_final.sql`) da seção 14.11 é
reaproveitável — bastaria adicionar 2 controles novos: um operador SEM
`acessos_extras` continua bloqueado em `etiquetas_fila`/`enderecos`
(regressão não introduzida), e um operador COM `acessos_extras` contendo
a tela certa consegue escrever (o caso que estava quebrado, agora
corrigido).
