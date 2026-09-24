// supabase/functions/consultar-pedidos-compra-selgron/index.ts
//
// Proxy autenticado pra https://consulta.selgron.com.br/pedido_compra_aberto.php
// — mesmo padrão de consultar-produto-selgron (mesmo domínio, mesma
// autenticação), só que essa página é uma TABELA de verdade (DataTables:
// "Exportar para CSV/PDF/Excel", "Colunas Visíveis", busca por coluna —
// mesma biblioteca já vista em kardex.php), não o formato "Rótulo: valor"
// da consulta de produto. O parser aqui segue o mesmo espírito do
// `celulasDaLinha`/posição-de-coluna já usado pro Kardex, com uma diferença
// importante: em vez de um índice FIXO por coluna (frágil — a página tem um
// botão "Colunas Visíveis", ou seja, a ordem/presença de coluna pode mudar
// por sessão/usuário), lê o `<thead>` de verdade e localiza cada coluna
// pelo RÓTULO. Confirmado com print real do cliente (pedido de compra da
// FESTO BRASIL LTDA, pedido 136144): a coluna do nome do fornecedor tem um
// texto de cabeçalho estranho/não relacionado ("Não se trata de um
// problema de snooker" — parece um placeholder/piada esquecida na
// configuração da coluna do lado da Selgron, não um erro nosso) — por isso
// ela é localizada por POSIÇÃO relativa (a coluna logo depois de "Código"),
// não pelo texto do rótulo, com esse texto exato como pista/log de
// diagnóstico se a posição mudar no futuro.
//
// NÃO grava nada no Supabase — proxy puro, mesmo motivo de
// consultar-produto-selgron (não precisa de SUPABASE_SERVICE_ROLE_KEY).
//
// Reaproveita as MESMAS credenciais já configuradas pra consulta de
// produto (é o mesmo portal, mesmo login):
//   CONSULTA_SELGRON_USER / CONSULTA_SELGRON_PASS
//
// ATENÇÃO — este parser foi calibrado a partir de um PRINT da tela (não do
// HTML cru da página, que ninguém com acesso conseguiu extrair ainda) — a
// estrutura exata de `<table>`/`<thead>`/`<tbody>` é uma suposição razoável
// (mesma biblioteca DataTables do Kardex), mas pode precisar de ajuste fino
// assim que testado contra a página real pela 1ª vez. Se `pedidos` sair
// vazio mesmo com pedidos reais na tela, o mais provável é a estrutura de
// tabela ter vindo diferente do esperado — ver `erroDiagnostico` na
// resposta, e reajustar aqui com o HTML real em mãos.

const CONSULTA_SELGRON_USER = Deno.env.get("CONSULTA_SELGRON_USER") ?? "";
const CONSULTA_SELGRON_PASS = Deno.env.get("CONSULTA_SELGRON_PASS") ?? "";
const CONSULTA_URL = "https://consulta.selgron.com.br/pedido_compra_aberto.php";

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

// Mesmo parser de número BR já usado em consultar-produto-selgron (vírgula
// = decimal, ponto = separador de milhar) — "Quant." nessa tabela pode vir
// como "1", "10", ou com casas decimais dependendo da unidade de medida.
function parseNumeroBR(raw: string | null | undefined): number | null {
  if (raw == null) return null;
  const s = String(raw).trim();
  if (!s) return null;
  const m = /^-?[\d.,]+/.exec(s);
  if (!m) return null;
  let n = m[0];
  if (n.includes(",")) {
    n = n.replace(/\./g, "").replace(",", ".");
  } else if (/\.\d{3}(\.\d{3})*$/.test(n)) {
    n = n.replace(/\./g, "");
  }
  const num = Number(n);
  return Number.isFinite(num) ? num : null;
}

// "DD/MM/AAAA" -> "AAAA-MM-DD" (mesmo formato usado no resto do app pra
// comparar datas como string, ver `hojeLocalStr`/`localDateStr` no
// front-end). `null` se não bater com o formato esperado — nunca inventa
// uma data.
function dataBrParaIso(raw: string | null | undefined): string | null {
  if (!raw) return null;
  const m = /^(\d{2})\/(\d{2})\/(\d{4})$/.exec(String(raw).trim());
  if (!m) return null;
  const [, dd, mm, aaaa] = m;
  return `${aaaa}-${mm}-${dd}`;
}

function textoDaCelula(tdHtml: string): string {
  return tdHtml
    .replace(/<[^>]+>/g, " ")
    .replace(/&nbsp;/gi, " ")
    .replace(/&amp;/gi, "&")
    .replace(/&lt;/gi, "<")
    .replace(/&gt;/gi, ">")
    .replace(/&quot;/gi, '"')
    .replace(/\s+/g, " ")
    .trim();
}

function celulasDaLinha(linhaHtml: string, tag: "td" | "th" = "td"): string[] {
  const re = new RegExp(`<${tag}[^>]*>([\\s\\S]*?)<\\/${tag}>`, "gi");
  const matches = [...linhaHtml.matchAll(re)];
  return matches.map((m) => textoDaCelula(m[1]));
}

interface PedidoItem {
  numero: string | null;
  fornecedor: string | null;
  produto: string | null;
  descricao: string | null;
  quantidade: number | null;
  entrega: string | null; // YYYY-MM-DD
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });

  if (!CONSULTA_SELGRON_USER || !CONSULTA_SELGRON_PASS) {
    return resposta(500, {
      ok: false,
      erro: "Credenciais da consulta Selgron não configuradas (CONSULTA_SELGRON_USER/CONSULTA_SELGRON_PASS).",
    });
  }

  try {
    const auth = "Basic " + btoa(`${CONSULTA_SELGRON_USER}:${CONSULTA_SELGRON_PASS}`);

    const resp = await fetch(CONSULTA_URL, {
      method: "GET",
      headers: { Authorization: auth },
      signal: AbortSignal.timeout(15000),
    });

    if (resp.status === 401 || resp.status === 403) {
      return resposta(200, { ok: false, erro: "Login/senha da consulta Selgron inválidos ou expirados." });
    }
    if (!resp.ok) {
      return resposta(200, { ok: false, erro: `Consulta Selgron respondeu ${resp.status}.` });
    }

    const html = await resp.text();

    // Isola a 1ª <table> da página (a tabela de pedidos, mesma estrutura
    // DataTables do Kardex) — pega só o PRIMEIRO <thead> (a linha de
    // rótulos de coluna) e ignora a 2ª linha de cabeçalho (os campos de
    // busca por coluna, "Pesquisar"/"Busca Lil" etc., visíveis no print do
    // cliente), que o DataTables também costuma marcar como <th> dentro do
    // mesmo <thead> — por isso usa a 1ª <tr> do thead, não todas.
    const theadMatch = /<thead[^>]*>([\s\S]*?)<\/thead>/i.exec(html);
    const tbodyMatch = /<tbody[^>]*>([\s\S]*?)<\/tbody>/i.exec(html);
    if (!theadMatch || !tbodyMatch) {
      return resposta(200, {
        ok: false,
        erro: "Não encontrei a tabela de pedidos na resposta da consulta Selgron (formato da página pode ter mudado).",
      });
    }

    const primeiraLinhaThead = /<tr[^>]*>([\s\S]*?)<\/tr>/i.exec(theadMatch[1]);
    const rotulos = primeiraLinhaThead ? celulasDaLinha(primeiraLinhaThead[1], "th") : [];

    // Localiza cada coluna pelo RÓTULO (resiliente a "Colunas Visíveis"
    // mudar a ordem) — comparação sem acento/maiúscula, e por PREFIXO
    // (alguns rótulos têm sufixo de espaço/ícone de ordenação que
    // `textoDaCelula` já limpou, mas "Desc. Condicao" x "Descrição" por
    // exemplo colidiriam por `includes` puro — por isso usa igualdade,
    // não `includes`, pros rótulos ambíguos).
    const normaliza = (s: string) =>
      s.normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase().trim();
    const rotulosNorm = rotulos.map(normaliza);
    const idxDe = (...alvos: string[]): number => {
      for (const alvo of alvos) {
        const i = rotulosNorm.indexOf(normaliza(alvo));
        if (i !== -1) return i;
      }
      return -1;
    };

    const idxNumero = idxDe("Número", "Numero");
    const idxCodigo = idxDe("Código", "Codigo");
    const idxProd = idxDe("Prod.", "Prod", "Produto");
    const idxDescricao = idxDe("Descrição", "Descricao");
    const idxQuant = idxDe("Quant.", "Quant", "Quantidade");
    const idxEntrega = idxDe("Entrega");
    // Fornecedor: NÃO tem rótulo confiável (ver comentário no topo do
    // arquivo) — assume a coluna logo depois de "Código", que é onde
    // apareceu no print real do cliente ("FESTO BRASIL LTDA" logo após
    // "000116"). Só usa essa posição relativa; nunca chuta um índice fixo
    // absoluto.
    const idxFornecedor = idxCodigo !== -1 ? idxCodigo + 1 : -1;

    if (idxEntrega === -1 || idxQuant === -1) {
      return resposta(200, {
        ok: false,
        erro: "Não encontrei as colunas esperadas (\"Entrega\"/\"Quant.\") na tabela — formato da página pode ter mudado.",
        rotulosEncontrados: rotulos,
      });
    }

    const linhasHtml = [...tbodyMatch[1].matchAll(/<tr[^>]*>([\s\S]*?)<\/tr>/gi)].map((m) => m[1]);
    const pedidos: PedidoItem[] = [];
    for (const linhaHtml of linhasHtml) {
      const celulas = celulasDaLinha(linhaHtml, "td");
      if (celulas.length === 0) continue;
      // DataTables mostra uma linha "Nenhum registro encontrado" (1 única
      // célula, colspan da tabela inteira) quando não há pedido nenhum —
      // detecta pelo tamanho (bem menor que o total de colunas esperado)
      // em vez de tentar casar o texto exato (que pode variar/ter acento).
      if (celulas.length < rotulos.length - 3) continue;

      const entrega = dataBrParaIso(celulas[idxEntrega]);
      pedidos.push({
        numero: idxNumero !== -1 ? celulas[idxNumero] || null : null,
        fornecedor: idxFornecedor !== -1 ? celulas[idxFornecedor] || null : null,
        produto: idxProd !== -1 ? celulas[idxProd] || null : null,
        descricao: idxDescricao !== -1 ? celulas[idxDescricao] || null : null,
        quantidade: parseNumeroBR(celulas[idxQuant]),
        entrega,
      });
    }

    return resposta(200, {
      ok: true,
      pedidos,
      // Diagnóstico — não usado pelo front-end quando `ok:true`, só ajuda a
      // calibrar se `pedidos` sair vazio ou com campos errados na 1ª
      // tentativa real contra a página.
      rotulosEncontrados: rotulos,
      totalLinhasNaTabela: linhasHtml.length,
    });
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    return resposta(200, { ok: false, erro: "Falha ao consultar pedidos de compra na Selgron: " + msg });
  }
});
