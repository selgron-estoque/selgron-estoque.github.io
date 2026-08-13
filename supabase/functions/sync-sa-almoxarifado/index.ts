// supabase/functions/sync-sa-almoxarifado/index.ts
//
// Consulta https://consulta.selgron.com.br/sa_aberto.php (a lista de
// Solicitações ao Almoxarifado ainda em aberto) e reconcilia contra a
// tabela `sa_almoxarifado` — pedido do cliente: acompanhar o desempenho do
// almoxarifado atendendo SAs, meta de menos de 2 dias (48h corridas), sem
// precisar visitar essa página manualmente todo dia.
//
// Regra central (do próprio cliente): "enquanto a SA estiver aparecendo na
// consulta, ela ainda está pendente. Quando a SA deixar de aparecer,
// significa que foi atendida." — só dá pra detectar isso comparando o
// retrato de AGORA contra o estado já salvo, por isso esta function roda
// PERIODICAMENTE (a cada 30 min via pg_cron, ver backend/README.md seção
// 13), não só sob demanda:
//   1) Toda SA encontrada nesta consulta é upsert'ada com status='aberta'.
//   2) Toda SA que estava 'aberta' no banco mas NÃO apareceu nesta consulta
//      vira 'atendida', com atendida_em = agora — a melhor aproximação
//      possível do momento real de atendimento, que ficou em algum ponto
//      entre o poll anterior (ainda a viu) e este (não a viu mais).
//
// Autenticação com a Selgron: reaproveita os MESMOS secrets já configurados
// pra consultar-produto-selgron (mesmo domínio consulta.selgron.com.br) —
// CONSULTA_SELGRON_USER/CONSULTA_SELGRON_PASS. Se a página de SA exigir um
// login diferente, configure secrets próprios (ver backend/README.md 13.2).
//
// Autenticação com o app: deploy padrão, COM verificação de JWT — tanto o
// botão "Sincronizar agora" (JWT do usuário logado) quanto o pg_cron (JWT =
// a própria SERVICE_ROLE_KEY, passada no header Authorization do
// net.http_post, ver backend/README.md seção 13.4) autenticam normalmente.
//
// PARSER — pendência real, documentada: escrito sem nunca ter visto o HTML
// de verdade da página (mesma situação inicial de consultar-produto-selgron/
// kardex.php, que precisaram de 1-2 rodadas de ajuste depois que o cliente
// mandou o HTML real via "Ver código-fonte"/Ctrl+U). Por isso o parser
// resolve colunas por NOME de cabeçalho normalizado (não por posição fixa)
// — mais resistente a variação de marcação, mas ainda é uma 1ª versão a
// calibrar contra a página real (ver backend/README.md seção 13.5).

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CONSULTA_SELGRON_USER = Deno.env.get("CONSULTA_SELGRON_USER") ?? "";
const CONSULTA_SELGRON_PASS = Deno.env.get("CONSULTA_SELGRON_PASS") ?? "";
const SA_ABERTO_URL = "https://consulta.selgron.com.br/sa_aberto.php";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

function resposta(status: number, body: unknown) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...CORS_HEADERS },
  });
}

// Remove acento/maiúscula/espaço extra pra comparar cabeçalho de coluna sem
// depender de acentuação exata (mesmo cuidado já visto em outras páginas
// desta consulta interna — "Armazem" apareceu sem acento numa delas).
function normalizarTexto(s: string): string {
  return s
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "") // remove marcas diacríticas combinantes (acentos)
    .toLowerCase()
    .replace(/\s+/g, " ")
    .trim();
}

function textoDaCelula(html: string): string {
  return html
    .replace(/<[^>]+>/g, " ")
    .replace(/&nbsp;/gi, " ")
    .replace(/&amp;/gi, "&")
    .replace(/&lt;/gi, "<")
    .replace(/&gt;/gi, ">")
    .replace(/&quot;/gi, '"')
    .replace(/\s+/g, " ")
    .trim();
}

// Palavras-chave que identificam cada coluna, em ordem de prioridade —
// primeira que bater no cabeçalho normalizado vence. `numero` vem por
// último de propósito (é o mais genérico — "sa"/"numero" sozinho poderia
// colidir com outro cabeçalho antes de mais específicos serem checados).
const COLUNA_KEYWORDS: Record<string, string[]> = {
  numero: ["numero da sa", "numero sa", "nº sa", "num sa", "sa"],
  abertura: ["data abertura", "dt abertura", "abertura", "data emissao", "dt emissao", "data"],
  solicitante: ["solicitante", "requisitante"],
  materialCodigo: ["codigo", "cod produto", "cod. produto", "produto"],
  materialDescricao: ["descricao", "material", "descricao do material"],
  quantidade: ["quantidade", "qtd", "qtde"],
};

function mapearColunas(cabecalhos: string[]): Record<string, number> {
  const norm = cabecalhos.map(normalizarTexto);
  const mapa: Record<string, number> = {};
  for (const campo of Object.keys(COLUNA_KEYWORDS)) {
    for (const kw of COLUNA_KEYWORDS[campo]) {
      const idx = norm.findIndex((h) => h === kw || h.includes(kw));
      if (idx !== -1) {
        mapa[campo] = idx;
        break;
      }
    }
  }
  return mapa;
}

// Aceita "DD/MM/AAAA HH:MM[:SS]" ou só "DD/MM/AAAA" — devolve ISO ou null se
// não reconhecer. Também tenta um atributo `data-sort='<unix>'`/
// `data-order='<unix>'` na própria célula, se existir (mesmo padrão de
// DataTables já visto no Kardex de produto.consulta.php) — preferido por
// ser inequívoco, quando presente.
function parseDataHoraCelula(htmlCelula: string, textoCelula: string): string | null {
  const mSort = /data-(?:sort|order)=['"](\d+)['"]/i.exec(htmlCelula);
  if (mSort) {
    const v = Number(mSort[1]);
    if (Number.isFinite(v) && v > 946684800 && v < 4102444800) {
      return new Date(v * 1000).toISOString();
    }
  }
  const m = /(\d{2})\/(\d{2})\/(\d{4})(?:\s+(\d{2}):(\d{2})(?::(\d{2}))?)?/.exec(textoCelula);
  if (!m) return null;
  const [, dia, mes, ano, hh = "00", mm = "00", ss = "00"] = m;
  const iso = `${ano}-${mes}-${dia}T${hh}:${mm}:${ss}Z`;
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? null : d.toISOString();
}

interface SaAberta {
  numeroSa: string;
  solicitante: string | null;
  materialCodigo: string | null;
  materialDescricao: string | null;
  quantidade: string | null;
  abertaEm: string | null;
}

// Extrai as SAs em aberto do HTML da página — resolve colunas por NOME
// (não posição fixa), mesmo espírito já usado em parseHistoricoContagensRows
// (index.html) pra ser robusto a reordenação de coluna numa exportação
// futura. Só processa a PRIMEIRA `<table>` encontrada com uma linha de
// cabeçalho reconhecível (com "numero"/"sa" mapeado) — se a página tiver
// mais de uma tabela (ex: um resumo antes da lista), as demais são
// ignoradas.
function extrairSasAbertas(html: string): SaAberta[] {
  const tabelas = html.match(/<table[\s\S]*?<\/table>/gi) || [];
  for (const tabela of tabelas) {
    const linhas = tabela.match(/<tr[^>]*>[\s\S]*?<\/tr>/gi) || [];
    if (linhas.length < 2) continue;

    // Cabeçalho: 1ª linha, células <th> se existirem, senão <td>.
    const linhaHeader = linhas[0];
    if (!linhaHeader) continue;
    const celulasHeaderHtml = linhaHeader.match(/<th[^>]*>[\s\S]*?<\/th>/gi) || linhaHeader.match(/<td[^>]*>[\s\S]*?<\/td>/gi) || [];
    if (celulasHeaderHtml.length === 0) continue;
    const cabecalhos = celulasHeaderHtml.map((c) => textoDaCelula(c));
    const colunas = mapearColunas(cabecalhos);
    if (colunas.numero === undefined) continue; // não é a tabela certa

    const resultado: SaAberta[] = [];
    for (let i = 1; i < linhas.length; i++) {
      const celulasHtml = linhas[i].match(/<td[^>]*>[\s\S]*?<\/td>/gi) || [];
      if (celulasHtml.length === 0) continue;
      const celulasTexto = celulasHtml.map((c) => textoDaCelula(c));

      const numeroSa = colunas.numero !== undefined ? celulasTexto[colunas.numero] : "";
      if (!numeroSa) continue;

      resultado.push({
        numeroSa: numeroSa.trim(),
        solicitante: colunas.solicitante !== undefined ? (celulasTexto[colunas.solicitante] || null) : null,
        materialCodigo: colunas.materialCodigo !== undefined ? (celulasTexto[colunas.materialCodigo] || null) : null,
        materialDescricao:
          colunas.materialDescricao !== undefined ? (celulasTexto[colunas.materialDescricao] || null) : null,
        quantidade: colunas.quantidade !== undefined ? (celulasTexto[colunas.quantidade] || null) : null,
        abertaEm:
          colunas.abertura !== undefined
            ? parseDataHoraCelula(celulasHtml[colunas.abertura], celulasTexto[colunas.abertura])
            : null,
      });
    }
    if (resultado.length > 0) return resultado;
  }
  return [];
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });

  if (!CONSULTA_SELGRON_USER || !CONSULTA_SELGRON_PASS) {
    return resposta(500, {
      ok: false,
      erro: "Credenciais da consulta Selgron não configuradas (CONSULTA_SELGRON_USER/CONSULTA_SELGRON_PASS).",
    });
  }

  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

  const { data: logRow, error: logError } = await supabase
    .from("sync_log")
    .insert({ origem: "sa_almoxarifado", status: "em_andamento" })
    .select()
    .single();
  if (logError) {
    return resposta(500, { ok: false, erro: "Falha ao criar log: " + logError.message });
  }

  try {
    const auth = "Basic " + btoa(`${CONSULTA_SELGRON_USER}:${CONSULTA_SELGRON_PASS}`);
    const resp = await fetch(SA_ABERTO_URL, {
      method: "GET",
      headers: { Authorization: auth },
      signal: AbortSignal.timeout(15000),
    });

    if (resp.status === 401 || resp.status === 403) {
      throw new Error("Login/senha da consulta Selgron inválidos ou expirados.");
    }
    if (!resp.ok) {
      throw new Error(`Consulta Selgron respondeu ${resp.status}.`);
    }

    const html = await resp.text();
    const sasAbertas = extrairSasAbertas(html);

    // Página respondeu 200 mas não reconhecemos nenhuma linha — sinal forte
    // de que o formato mudou do lado de lá (ou a página está genuinamente
    // vazia, "nenhuma SA em aberto"). Não dá pra distinguir os dois casos
    // só pelo HTML sem ver a página real — por segurança, NUNCA marca todo
    // mundo como atendido quando o parser não reconheceu nada (evitaria uma
    // falsa "onda de atendimentos" se o parser simplesmente parou de
    // funcionar) — só atualiza o log e sai, sem tocar em `sa_almoxarifado`.
    if (sasAbertas.length === 0) {
      await supabase
        .from("sync_log")
        .update({
          status: "erro",
          itens_processados: 0,
          erro: "Nenhuma SA reconhecida no HTML — parser pode precisar de calibração (ver backend/README.md 13.5), ou a lista está genuinamente vazia.",
          concluido_em: new Date().toISOString(),
        })
        .eq("id", logRow!.id);
      return resposta(200, { ok: true, itensProcessados: 0, aviso: "Nenhuma SA reconhecida — nada foi alterado." });
    }

    const agora = new Date().toISOString();
    const upsertRows = sasAbertas.map((sa) => ({
      numero_sa: sa.numeroSa,
      solicitante: sa.solicitante,
      material_codigo: sa.materialCodigo,
      material_descricao: sa.materialDescricao,
      quantidade: sa.quantidade,
      aberta_em: sa.abertaEm,
      status: "aberta",
      atendida_em: null,
      ultima_vista_em: agora,
      atualizado_em: agora,
    }));

    // Upsert em lotes de 500 (mesmo teto já usado em outros sincronismos
    // deste projeto, ex. replaceEstoqueSaldoInSupabase).
    for (let i = 0; i < upsertRows.length; i += 500) {
      const lote = upsertRows.slice(i, i + 500);
      const { error: upsertError } = await supabase
        .from("sa_almoxarifado")
        .upsert(lote, { onConflict: "numero_sa" });
      if (upsertError) throw upsertError;
    }

    // Reconciliação — qualquer SA que estava 'aberta' no banco e não veio
    // nesta lista foi atendida (regra central do cliente).
    const numerosAbertosAgora = new Set(sasAbertas.map((s) => s.numeroSa));
    const { data: abertasNoBanco, error: selectError } = await supabase
      .from("sa_almoxarifado")
      .select("numero_sa")
      .eq("status", "aberta");
    if (selectError) throw selectError;

    const numerosParaFechar = (abertasNoBanco || [])
      .map((r: { numero_sa: string }) => r.numero_sa)
      .filter((n: string) => !numerosAbertosAgora.has(n));

    if (numerosParaFechar.length > 0) {
      const { error: closeError } = await supabase
        .from("sa_almoxarifado")
        .update({ status: "atendida", atendida_em: agora, atualizado_em: agora })
        .in("numero_sa", numerosParaFechar);
      if (closeError) throw closeError;
    }

    await supabase
      .from("sync_log")
      .update({
        status: "sucesso",
        itens_processados: sasAbertas.length,
        concluido_em: new Date().toISOString(),
      })
      .eq("id", logRow!.id);

    return resposta(200, {
      ok: true,
      itensProcessados: sasAbertas.length,
      sasAtendidasNestaRodada: numerosParaFechar.length,
    });
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    await supabase
      .from("sync_log")
      .update({ status: "erro", erro: msg, concluido_em: new Date().toISOString() })
      .eq("id", logRow!.id);
    return resposta(200, { ok: false, erro: "Falha ao sincronizar SAs: " + msg });
  }
});
