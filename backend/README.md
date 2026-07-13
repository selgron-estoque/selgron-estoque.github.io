# Inventário 360 — Backend de Sincronização (Supabase)

Esta pasta contém o banco (schema.sql) e a função que mantém o saldo sincronizado
com o Protheus. É o que falta para o Inventário 360 sair do protótipo (dados em
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

Diferente do saldo, o endereço é escrito direto pelo Inventário 360 no Supabase —
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

## 8. Como o front-end (Inventário 360) deve ler os dados, resumindo

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
