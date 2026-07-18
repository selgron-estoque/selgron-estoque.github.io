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
