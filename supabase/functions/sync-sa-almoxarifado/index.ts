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
//   1) Todo ITEM de SA encontrado nesta consulta é upsert'ado com
//      status='aberta' (ver "achado real" abaixo — item, não SA, é a
//      unidade de reconciliação).
//   2) Todo item que estava 'aberta' no banco mas NÃO apareceu nesta
//      consulta vira 'atendida', com atendida_em = agora — a melhor
//      aproximação possível do momento real de atendimento, que ficou em
//      algum ponto entre o poll anterior (ainda o viu) e este (não viu
//      mais).
//
// PARSER — calibrado contra o HTML REAL da página (o cliente mandou via
// "Ver código-fonte da página"/Ctrl+U), não mais só uma suposição de
// formato. Dois achados reais que mudaram o desenho original:
//
//   1) "Numero" (a SA) NÃO é identidade única por linha — uma SA pode pedir
//      VÁRIOS materiais diferentes, cada um numa linha própria da tabela,
//      distinguida pela coluna "Item" (sequência 01, 02, 03... dentro da
//      MESMA SA — confirmado com exemplos reais no HTML, ex. a SA "073445"
//      tem 10 linhas, Item 01 a 10, cada uma com código/descrição/
//      quantidade diferentes). A identidade de verdade é o PAR
//      (numero_sa, item) — ver `chave` em backend/schema.sql. Reconciliar
//      por numero_sa sozinho fecharia (ou reabriria) TODOS os itens de uma
//      SA multi-material junto, mesmo que só um deles tivesse sido
//      resolvido de fato — por isso toda a lógica abaixo (upsert,
//      reconciliação) opera sobre `chave`, nunca sobre `numero_sa` isolado.
//
//   2) A coluna "Emissao" só tem DATA (formato "DD/MM/AAAA"), nunca hora —
//      tratado como meia-noite daquele dia. Limitação REAL da fonte, ainda
//      de pé: "tempo em aberto"/"dentro da meta" podem ter até ~24h de
//      imprecisão por causa disso (a página não expõe hora de abertura).
//
//   3) BUG real encontrado depois do 1º sync ao vivo (cliente reportou:
//      "Emissao: 12/08/2026" na página real, mas o app mostrava
//      "11/08/2026, 21:00:00") — a versão anterior de `parseDataHoraCelula`
//      montava o ISO com sufixo "Z" (UTC), tratando "meia-noite daquele
//      dia" como meia-noite EM UTC. Como a página é um sistema interno
//      brasileiro, a data exibida ("12/08/2026") é sempre horário de
//      Brasília, não UTC — meia-noite em Brasília (UTC-3) é 03:00 UTC, não
//      00:00 UTC. Gravar como 00:00 UTC e depois exibir convertido pra
//      Brasília (`toLocaleString('pt-BR')`, index.html) empurrava a data
//      de volta pro dia ANTERIOR às 21h — o sintoma exato reportado.
//      Corrigido usando o offset fixo "-03:00" (Brasil não tem mais
//      horário de verão desde 2019, não precisa de lógica de DST) em vez
//      de "Z" — vale tanto pra "Emissao" (sem hora, cai em "00:00:00")
//      quanto pro caso hipotético de uma coluna de data trazer hora no
//      futuro (mesma premissa: qualquer hora nesta página é horário local
//      de Brasília, nunca UTC).
//
// A tabela real (`id='tbemp'`, gerada via jQuery DataTables) tem uma
// estrutura <thead>+<tfoot>+<tbody> onde tanto o <thead> quanto o <tfoot>
// repetem o mesmo cabeçalho como células <th> (o <tfoot> serve pros campos
// de busca por coluna do DataTables) — só o <tbody> tem células <td> de
// dado de verdade. `extrairSasAbertas` classifica linha por CONTEÚDO da
// célula (tem <th> vs. tem <td>), não por qual tag-pai a envolve — mais
// simples e resistente a variação de marcação do que tentar distinguir
// <thead>/<tfoot>/<tbody> via regex. DataTables pagina client-side depois
// que a página carrega (`pageLength:500` no JS dela) — irrelevante aqui,
// porque o `fetch()` desta function não executa JS nenhum: a resposta HTML
// já vem do servidor com TODAS as linhas no <tbody>, a paginação só
// aconteceria depois, no navegador de quem abre a página de verdade.
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
    .replace(/[\u0300-\u036f]/g, "") // remove marcas diacriticas combinantes (acentos)
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

// Palavras-chave por coluna, uma única e precisa cada uma — confirmadas
// contra o cabeçalho REAL da página (Numero/Solicitante/Emissao/Item/
// Cod Produto/Descricao/Quant/Saldo SA/Saldo Estoque/Almox/Obs/OP/
// Cod. C.Custo/C. Custo — os 6 últimos não são usados, de propósito, pra
// não poluir a tela com dado que o cliente não pediu). Cada palavra-chave
// foi conferida uma a uma contra TODOS os outros cabeçalhos reais pra
// garantir que não colide por substring (`.includes()`) com nenhum deles —
// ex.: "quant" não aparece em "saldo sa"/"saldo estoque"; "cod produto" não
// aparece em "cod. c.custo" (textos diferentes, mesmo com o period
// preservado pela normalização). A versão anterior deste mapa tinha um
// fallback genérico `"sa"` pra `numero` que teria colidido com "Saldo SA"
// (que contém a substring "sa") — removido, não existe mais.
const COLUNA_KEYWORDS: Record<string, string[]> = {
  numero: ["numero"],
  item: ["item"],
  abertura: ["emissao"],
  solicitante: ["solicitante"],
  materialCodigo: ["cod produto"],
  materialDescricao: ["descricao"],
  quantidade: ["quant"],
  almoxarifado: ["almox"],
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

// Aceita "DD/MM/AAAA HH:MM[:SS]" ou só "DD/MM/AAAA" (o formato real da
// coluna "Emissao", sempre sem hora) — devolve ISO ou null se não
// reconhecer. Também tenta um atributo `data-sort='<unix>'`/
// `data-order='<unix>'` na própria célula, se existir (mesmo padrão de
// DataTables já visto no Kardex de produto.consulta.php) — preferido por
// ser inequívoco, quando presente; a página de SA não usa isso na coluna de
// data (confirmado no HTML real), então na prática sempre cai no 2º regex.
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
  // "-03:00", não "Z" — a página é um sistema interno brasileiro, então a
  // data/hora exibida já é horário de Brasília (fuso fixo, sem DST desde
  // 2019), nunca UTC. Ver "achado 3" no comentário do topo do arquivo —
  // usar "Z" aqui fazia a data exibida no app "voltar" pro dia anterior.
  const iso = `${ano}-${mes}-${dia}T${hh}:${mm}:${ss}-03:00`;
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? null : d.toISOString();
}

interface SaAberta {
  numeroSa: string;
  item: string;
  solicitante: string | null;
  materialCodigo: string | null;
  materialDescricao: string | null;
  quantidade: string | null;
  almoxarifado: string | null;
  abertaEm: string | null;
}

// Extrai os itens de SA em aberto do HTML da página. Ver o comentário do
// topo do arquivo pra o raciocínio completo (estrutura thead+tfoot+tbody,
// classificação de linha por conteúdo de célula, achado do par
// numero+item como identidade real).
function extrairSasAbertas(html: string): SaAberta[] {
  const tabelaPorId = /<table[^>]*id=["']tbemp["'][\s\S]*?<\/table>/i.exec(html);
  const tabela = tabelaPorId ? tabelaPorId[0] : (html.match(/<table[\s\S]*?<\/table>/i) || [])[0];
  if (!tabela) return [];

  const linhas = tabela.match(/<tr[^>]*>[\s\S]*?<\/tr>/gi) || [];

  // Cabeçalho = a PRIMEIRA linha com célula <th> encontrada (é a do
  // <thead> — vem antes do <tfoot> na ordem do documento, e os dois só têm
  // <th>, nunca <td>). Linha de dado = QUALQUER linha com célula <td> —
  // isso exclui tanto <thead> quanto <tfoot> automaticamente, sem precisar
  // identificar qual tag-pai envolve cada uma.
  let cabecalhos: string[] | null = null;
  const linhasDado: string[] = [];
  for (const linha of linhas) {
    const celulasTh = linha.match(/<th[^>]*>[\s\S]*?<\/th>/gi);
    const celulasTd = linha.match(/<td[^>]*>[\s\S]*?<\/td>/gi);
    if (!cabecalhos && celulasTh && celulasTh.length > 0) {
      cabecalhos = celulasTh.map((c) => textoDaCelula(c));
    } else if (celulasTd && celulasTd.length > 0) {
      linhasDado.push(linha);
    }
  }
  if (!cabecalhos) return [];

  const colunas = mapearColunas(cabecalhos);
  if (colunas.numero === undefined) return [];

  const resultado: SaAberta[] = [];
  linhasDado.forEach((linha, idx) => {
    const celulasHtml = linha.match(/<td[^>]*>[\s\S]*?<\/td>/gi) || [];
    const celulasTexto = celulasHtml.map((c) => textoDaCelula(c));

    const numeroSa = colunas.numero !== undefined ? celulasTexto[colunas.numero] : "";
    if (!numeroSa) return;

    // Item: usa a coluna real quando disponível; senão cai na posição da
    // linha dentro da tabela (1-based, zero à esquerda) — garante uma
    // `chave` única mesmo contra um formato de página degradado/mais
    // antigo que não exponha essa coluna.
    const itemColuna = colunas.item !== undefined ? (celulasTexto[colunas.item] || "").trim() : "";
    const item = itemColuna || String(idx + 1).padStart(2, "0");

    resultado.push({
      numeroSa: numeroSa.trim(),
      item,
      solicitante: colunas.solicitante !== undefined ? (celulasTexto[colunas.solicitante] || null) : null,
      materialCodigo: colunas.materialCodigo !== undefined ? (celulasTexto[colunas.materialCodigo] || null) : null,
      materialDescricao:
        colunas.materialDescricao !== undefined ? (celulasTexto[colunas.materialDescricao] || null) : null,
      quantidade: colunas.quantidade !== undefined ? (celulasTexto[colunas.quantidade] || null) : null,
      almoxarifado: colunas.almoxarifado !== undefined ? (celulasTexto[colunas.almoxarifado] || null) : null,
      abertaEm:
        colunas.abertura !== undefined
          ? parseDataHoraCelula(celulasHtml[colunas.abertura], celulasTexto[colunas.abertura])
          : null,
    });
  });
  return resultado;
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
      chave: `${sa.numeroSa}-${sa.item}`,
      numero_sa: sa.numeroSa,
      item: sa.item,
      solicitante: sa.solicitante,
      material_codigo: sa.materialCodigo,
      material_descricao: sa.materialDescricao,
      quantidade: sa.quantidade,
      almoxarifado: sa.almoxarifado,
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
        .upsert(lote, { onConflict: "chave" });
      if (upsertError) throw upsertError;
    }

    // Reconciliação — qualquer ITEM de SA que estava 'aberta' no banco e não
    // veio nesta lista foi atendido (regra central do cliente). Reconcilia
    // por `chave` (SA+Item), NUNCA por `numero_sa` sozinho — uma SA com
    // vários materiais só pode fechar o item específico que sumiu da
    // consulta, não a SA inteira (ver o comentário no topo do arquivo e em
    // backend/schema.sql).
    const chavesAbertasAgora = new Set(sasAbertas.map((s) => `${s.numeroSa}-${s.item}`));
    const { data: abertasNoBanco, error: selectError } = await supabase
      .from("sa_almoxarifado")
      .select("chave")
      .eq("status", "aberta");
    if (selectError) throw selectError;

    const chavesParaFechar = (abertasNoBanco || [])
      .map((r: { chave: string }) => r.chave)
      .filter((c: string) => !chavesAbertasAgora.has(c));

    if (chavesParaFechar.length > 0) {
      const { error: closeError } = await supabase
        .from("sa_almoxarifado")
        .update({ status: "atendida", atendida_em: agora, atualizado_em: agora })
        .in("chave", chavesParaFechar);
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
      sasAtendidasNestaRodada: chavesParaFechar.length,
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
