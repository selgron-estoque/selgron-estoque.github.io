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
