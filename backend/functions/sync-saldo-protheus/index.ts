// supabase/functions/sync-saldo-protheus/index.ts
//
// Puxa o saldo em estoque do Protheus (endpoint REST customizado — ver
// conversa sobre integração TOTVS) e atualiza o cache local `estoque_saldo`.
//
// Quando roda:
//   1) Agendada — a cada X horas via Supabase Scheduled Triggers (pg_cron),
//      pra manter o catálogo geral razoavelmente atualizado.
//   2) Sob demanda — chamada manualmente (ex: botão "Sincronizar agora" na
//      tela de Configurações do Stock360, perfil Administrador).
//
// O saldo usado durante a contagem em si NÃO vem direto daqui — vem do
// snapshot congelado em `inventario_itens` (ver congelar-saldo-inventario).
// Esta função só mantém o cache geral em dia para telas de consulta,
// contagem manual e criação de novos inventários.
//
// Variáveis de ambiente necessárias (configurar com `supabase secrets set`):
//   PROTHEUS_API_URL              ex: https://protheus.empresa.com/api/estoque/v1/saldo
//   PROTHEUS_TOKEN                token de autenticação da API do Protheus
//   SUPABASE_URL                  preenchido automaticamente pelo Supabase
//   SUPABASE_SERVICE_ROLE_KEY     preenchido automaticamente pelo Supabase

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const PROTHEUS_API_URL = Deno.env.get("PROTHEUS_API_URL")!;
const PROTHEUS_TOKEN = Deno.env.get("PROTHEUS_TOKEN")!;
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const PAGE_SIZE = 500;

interface ProtheusSaldoItem {
  codigo: string;
  almoxarifado: string;
  saldo: number;
  valorFinanceiro?: number;
  dataUltimaSaida?: string | null;
}

Deno.serve(async (_req: Request) => {
  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

  const { data: logRow, error: logError } = await supabase
    .from("sync_log")
    .insert({ origem: "protheus_saldo", status: "em_andamento" })
    .select()
    .single();

  if (logError) {
    return new Response(JSON.stringify({ ok: false, erro: "Falha ao criar log: " + logError.message }), { status: 500 });
  }

  try {
    let pagina = 1;
    let totalProcessados = 0;
    let temMais = true;

    while (temMais) {
      const resp = await fetch(`${PROTHEUS_API_URL}?pagina=${pagina}&tamanho=${PAGE_SIZE}`, {
        headers: { Authorization: `Bearer ${PROTHEUS_TOKEN}` },
      });

      if (!resp.ok) {
        throw new Error(`Protheus respondeu ${resp.status}: ${await resp.text()}`);
      }

      const lote: ProtheusSaldoItem[] = await resp.json();
      if (lote.length === 0) {
        temMais = false;
        break;
      }

      // Garante que o produto existe na tabela produtos antes do upsert de
      // saldo (evita erro de foreign key se o catálogo ainda não tiver esse
      // código — cenário raro, mas acontece em migrações incrementais).
      const produtosUnicos = [...new Set(lote.map((i) => i.codigo))];
      await supabase
        .from("produtos")
        .upsert(
          produtosUnicos.map((codigo) => ({ codigo, descricao: codigo })),
          { onConflict: "codigo", ignoreDuplicates: true }
        );

      const upsertRows = lote.map((item) => ({
        produto_codigo: item.codigo,
        almoxarifado: item.almoxarifado,
        saldo: item.saldo,
        valor_financeiro: item.valorFinanceiro ?? null,
        data_ultima_saida: item.dataUltimaSaida ?? null,
        sincronizado_em: new Date().toISOString(),
      }));

      const { error: upsertError } = await supabase
        .from("estoque_saldo")
        .upsert(upsertRows, { onConflict: "produto_codigo,almoxarifado" });

      if (upsertError) throw upsertError;

      totalProcessados += lote.length;
      pagina += 1;
      if (lote.length < PAGE_SIZE) temMais = false; // última página
    }

    await supabase
      .from("sync_log")
      .update({
        status: "sucesso",
        itens_processados: totalProcessados,
        concluido_em: new Date().toISOString(),
      })
      .eq("id", logRow!.id);

    return new Response(JSON.stringify({ ok: true, itensProcessados: totalProcessados }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  } catch (err) {
    await supabase
      .from("sync_log")
      .update({
        status: "erro",
        erro: String(err instanceof Error ? err.message : err),
        concluido_em: new Date().toISOString(),
      })
      .eq("id", logRow!.id);

    return new Response(JSON.stringify({ ok: false, erro: String(err) }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }
});
