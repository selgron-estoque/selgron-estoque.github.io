// supabase/functions/consultar-itens-faltantes/index.ts
//
// Consulta https://consulta.selgron.com.br/itensfaltantes.php pelo código de
// uma ETP e devolve os itens faltantes encontrados — pedido do cliente:
// "Neste link eu vou digitar o código da ETP e ele pesquisa a OP e
// quantidade de itens dentro da OP, na tela de programação eu adiciono o
// número da ETP." Uma ETP pode abranger mais de uma OP e mais de um item —
// por isso a busca sempre devolve uma LISTA (nunca um item único), e a tela
// "Programação" (ver index.html, `ProgramacaoSeparacaoPanel`) mostra essa
// lista como PRÉVIA com checkbox por item, nada é gravado sozinho — decisão
// explícita do cliente via `AskUserQuestion`: "Mostrar lista, eu escolho
// quais entram." A prioridade (Alta/Média/Baixa) do lote inteiro também é
// escolhida uma vez só, no momento de confirmar — não item a item (2ª
// decisão já confirmada com o cliente).
//
// Diferente de sync-sa-almoxarifado (que roda num cron e RECONCILIA/grava
// direto no banco), esta function é só um PROXY sob demanda, sem nenhuma
// escrita no Supabase — mesmo desenho de consultar-produto-selgron: recebe
// {etp}, devolve os itens encontrados, e quem grava (`sequencia_separacao`)
// é o front-end, só depois que o líder confirma quais itens entram e com
// que prioridade.
//
// Filtros fixos da busca (confirmados no exemplo de URL real mandado pelo
// cliente) — SALDO=SEM_SALDO e o mesmo conjunto de grupos (B1_GRUPO) sempre;
// só o C2_NTEP (código da ETP) muda a cada busca. Se o cliente pedir pra
// tornar esses filtros configuráveis no futuro, é um pedido separado — por
// enquanto ficam fixos, exatamente como o link que ele já usa manualmente:
//   https://consulta.selgron.com.br/itensfaltantes.php?C2_NTEP=6220-26&
//   D4_TRT=&DATA_EMISSAO_DE=&DATA_EMISSAO_ATE=&SALDO=SEM_SALDO&
//   B1_GRUPO=0044%2C0090%2C0088%2C9900%2C9910%2C9930%2C9940%2C0016%2C1016&
//   btn-confirmar=
//
// PARSER — já calibrado contra o HTML real da página (o cliente mandou via
// Ctrl+U, ETP 6220-26, 20 linhas de dado) — a lista de colunas do 1º
// screenshot batia certinho (OP/Descrição OP/ETP/Dt. Emp./Produto/NTE/
// Grupo/Local/Saldo Estoque/Qtd Empenho/U.M./SCs/PCs/Terc), mas a 1ª versão
// não achava NENHUM item, sempre caindo em "não foi possível reconhecer a
// tabela" — mesmo com a ETP existindo e a tabela vindo cheia de linhas.
//
// Causa real: diferente de sync-sa-almoxarifado (onde <thead>/<tfoot>
// SEMPRE envolvem os <th> duplicados dentro de um <tr>), esta página monta
// <thead>/<tfoot> com os <th> SOLTOS, sem NENHUM <tr> ao redor — HTML
// tecnicamente malformado (navegador tolera e insere um <tr> implícito na
// hora de renderizar, mas o parser aqui procurava literalmente por
// "<tr>...<th>...</tr>" pra achar o cabeçalho, e nunca achava nenhum, já
// que não existe esse <tr> no HTML de verdade). Corrigido: `extrairBlocoTag`
// isola o conteúdo de dentro de <thead>...</thead> primeiro, e
// `extrairCelulas` lê os <th> de dentro dele direto, sem depender de <tr>
// nenhum — funciona pros dois formatos (com ou sem <tr> ao redor do
// cabeçalho), sem regredir sync-sa-almoxarifado (que continua caindo no
// mesmo resultado de sempre, só chegando lá por um caminho mais direto).
//
// Linhas de DADO continuam vindo só de <tr> com pelo menos um <td> (mesma
// técnica de sempre) — nesta página elas nunca tiveram problema, o <tbody>
// já envolve cada linha num <tr> normal; só o cabeçalho é que vinha solto.
//
// `mapearColunas` aqui faz 2 passadas — igualdade EXATA primeiro, substring
// só como fallback — pra nunca deixar um cabeçalho curto ("OP") casar por
// acidente com outro que o contém como substring ("Descrição OP"), mesma
// categoria de bug já visto antes neste projeto (keyword solta "sa"
// colidindo com "Saldo SA" em sync-sa-almoxarifado, corrigido depois).
//
// Coluna "Produto" — não existe uma coluna própria de descrição no
// relatório (confirmado pela lista de colunas do screenshot), então a
// descrição precisa vir embutida na própria célula "Produto" (assumido como
// "CÓDIGO seguido de descrição", ex.: "021.030.00023 - PARAFUSO..."),
// reconstruída via os mesmos 3 formatos de código válidos usados em toda a
// SB2 deste app (8/9/11 dígitos com pontuação). Sem bater com nenhum desses
// formatos, o código sai `null` (NUNCA inventado) — o front-end mostra a
// linha mesmo assim, mas não deixa selecionar sem um código reconhecido.
//
// Só 6 dos 14 campos da tabela real são capturados (op/etp/produto/local/
// quantidade/unidade) — os outros 8 (Descrição OP/Dt. Emp./NTE/Grupo/Saldo
// Estoque/SCs/PCs/Terc) não são usados pela fila de separação, mesmo
// critério de "não guardar dado que a tela não precisa" já seguido noutras
// integrações deste projeto (ex.: Classe/SA deixados em branco no export de
// BD_Contagens).

const CONSULTA_SELGRON_USER = Deno.env.get("CONSULTA_SELGRON_USER") ?? "";
const CONSULTA_SELGRON_PASS = Deno.env.get("CONSULTA_SELGRON_PASS") ?? "";
const ITENS_FALTANTES_URL = "https://consulta.selgron.com.br/itensfaltantes.php";
// Mesmo conjunto de grupos/saldo do exemplo real mandado pelo cliente — ver
// comentário do topo do arquivo.
const FILTROS_FIXOS =
  "&D4_TRT=&DATA_EMISSAO_DE=&DATA_EMISSAO_ATE=&SALDO=SEM_SALDO&B1_GRUPO=" +
  encodeURIComponent("0044,0090,0088,9900,9910,9930,9940,0016,1016") +
  "&btn-confirmar=";

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

// Só as 6 colunas usadas pela fila de separação — ver comentário do topo do
// arquivo pro porquê das outras 8 ficarem de fora.
const COLUNA_KEYWORDS: Record<string, string[]> = {
  op: ["op"],
  etp: ["etp"],
  produto: ["produto"],
  local: ["local"],
  quantidade: ["qtd empenho"],
  unidade: ["u.m.", "um"],
};

// 2 passadas: igualdade exata primeiro (evita "OP" casar com "Descrição
// OP", que também contém "op" como substring — mesma classe de bug já
// vista em sync-sa-almoxarifado com a keyword solta "sa"); substring só
// como fallback, pra sobreviver a uma variação pequena de texto (ex.
// espaço a mais entre palavras que a normalização não colapsou por algum
// motivo).
function mapearColunas(cabecalhos: string[]): Record<string, number> {
  const norm = cabecalhos.map(normalizarTexto);
  const mapa: Record<string, number> = {};
  for (const campo of Object.keys(COLUNA_KEYWORDS)) {
    let idx = -1;
    for (const kw of COLUNA_KEYWORDS[campo]) {
      idx = norm.findIndex((h) => h === kw);
      if (idx !== -1) break;
    }
    if (idx === -1) {
      for (const kw of COLUNA_KEYWORDS[campo]) {
        idx = norm.findIndex((h) => h.includes(kw));
        if (idx !== -1) break;
      }
    }
    if (idx !== -1) mapa[campo] = idx;
  }
  return mapa;
}

// Os 3 formatos de código de produto válidos já usados em toda a SB2 deste
// projeto (8/9/11 dígitos com pontuação — ver `reconstructNumericCode` em
// index.html) — sempre ancorados no início da célula "Produto". Sem bater
// com nenhum, `codigo` sai `null` — nunca inventado a partir de texto que
// não reconhece.
const PRODUTO_CODIGO_REGEX = /^(\d{3}\.\d{3}\.\d{5}|\d{3}\.\d{5}\.\d|\d{3}\.\d{5})\b[\s:–-]*(.*)$/;

function separarCodigoDescricao(celulaTexto: string): { codigo: string | null; descricao: string | null } {
  const texto = (celulaTexto || "").trim();
  if (!texto) return { codigo: null, descricao: null };
  const m = PRODUTO_CODIGO_REGEX.exec(texto);
  if (m) {
    const descricao = (m[2] || "").trim();
    return { codigo: m[1], descricao: descricao || null };
  }
  return { codigo: null, descricao: texto };
}

interface ItemFaltante {
  op: string | null;
  etp: string | null;
  codigo: string | null;
  descricao: string | null;
  local: string | null;
  quantidade: string | null;
  unidade: string | null;
  produtoBruto: string | null; // sempre a célula "Produto" crua — front-end usa pra exibir/editar quando `codigo` sai null
}

// Extrai o conteúdo de DENTRO da primeira ocorrência de uma tag (ex.:
// "thead") — usado pra achar o cabeçalho independente de ele vir envolvido
// por um <tr> ou não (ver comentário do topo do arquivo).
function extrairBlocoTag(html: string, tag: string): string | null {
  const re = new RegExp(`<${tag}[^>]*>([\\s\\S]*?)<\\/${tag}>`, "i");
  const m = re.exec(html);
  return m ? m[1] : null;
}

function extrairCelulas(html: string, tagCelula: "th" | "td"): string[] {
  const re = new RegExp(`<${tagCelula}[^>]*>[\\s\\S]*?<\\/${tagCelula}>`, "gi");
  return (html.match(re) || []).map((c) => textoDaCelula(c));
}

// Devolve `null` quando a tabela/cabeçalho não é reconhecida (sinal de que
// o formato da página mudou, ou a ETP não existe e a página nem monta a
// tabela) — DIFERENTE de devolver `[]` (tabela reconhecida, cabeçalho bate,
// mas genuinamente 0 linhas de dado — resultado vazio de verdade). Essa
// distinção é o que permite ao Deno.serve abaixo dar um erro honesto só no
// 1º caso, sem confundir com "esta ETP não tem item faltante".
function extrairItensFaltantes(html: string): ItemFaltante[] | null {
  // Escolhe a tabela com mais linhas <tr> — heurística simples, suficiente
  // aqui: a página não tem outra tabela grande visível no HTML confirmado.
  // Sem `id` conhecido pra esta tabela específica (diferente de `tbemp` em
  // sa_aberto.php, já confirmado contra o HTML real).
  const tabelasCandidatas = html.match(/<table[\s\S]*?<\/table>/gi) || [];
  let tabela = "";
  let maisLinhas = -1;
  for (const t of tabelasCandidatas) {
    const n = (t.match(/<tr[^>]*>/gi) || []).length;
    if (n > maisLinhas) {
      maisLinhas = n;
      tabela = t;
    }
  }
  if (!tabela) return null;

  // Cabeçalho — tenta primeiro um <thead> explícito, lendo os <th> de
  // dentro dele DIRETO (funciona com ou sem <tr> ao redor — ver comentário
  // do topo do arquivo). Sem <thead> reconhecível, cai no formato antigo
  // (1ª linha <tr> que contém <th>, no loop abaixo).
  const theadBloco = extrairBlocoTag(tabela, "thead");
  let cabecalhos: string[] | null = theadBloco ? extrairCelulas(theadBloco, "th") : null;
  if (cabecalhos && cabecalhos.length === 0) cabecalhos = null;

  const linhas = tabela.match(/<tr[^>]*>[\s\S]*?<\/tr>/gi) || [];

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
  if (!cabecalhos) return null;

  const colunas = mapearColunas(cabecalhos);
  // Sem NENHUM dos 2 campos mais essenciais (produto/op) reconhecidos, o
  // cabeçalho não bate com o formato esperado — trata como falha de
  // parser, não como resultado vazio.
  if (colunas.produto === undefined && colunas.op === undefined) return null;

  const resultado: ItemFaltante[] = [];
  for (const linha of linhasDado) {
    const celulasHtml = linha.match(/<td[^>]*>[\s\S]*?<\/td>/gi) || [];
    const celulasTexto = celulasHtml.map((c) => textoDaCelula(c));

    const produtoTexto = colunas.produto !== undefined ? celulasTexto[colunas.produto] || "" : "";
    const { codigo, descricao } = separarCodigoDescricao(produtoTexto);

    resultado.push({
      op: colunas.op !== undefined ? celulasTexto[colunas.op] || null : null,
      etp: colunas.etp !== undefined ? celulasTexto[colunas.etp] || null : null,
      codigo,
      descricao,
      local: colunas.local !== undefined ? celulasTexto[colunas.local] || null : null,
      quantidade: colunas.quantidade !== undefined ? celulasTexto[colunas.quantidade] || null : null,
      unidade: colunas.unidade !== undefined ? celulasTexto[colunas.unidade] || null : null,
      produtoBruto: produtoTexto || null,
    });
  }
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

  let etp = "";
  try {
    const body = await req.json();
    etp = String(body?.etp ?? "").trim();
  } catch {
    return resposta(400, { ok: false, erro: "Corpo da requisição inválido — esperado {etp}." });
  }
  if (!etp) return resposta(200, { ok: false, erro: "Informe o código da ETP." });

  try {
    const auth = "Basic " + btoa(`${CONSULTA_SELGRON_USER}:${CONSULTA_SELGRON_PASS}`);
    const url = `${ITENS_FALTANTES_URL}?C2_NTEP=${encodeURIComponent(etp)}${FILTROS_FIXOS}`;
    const resp = await fetch(url, {
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
    const itens = extrairItensFaltantes(html);

    if (itens === null) {
      return resposta(200, {
        ok: false,
        erro:
          "Não foi possível reconhecer a tabela de itens faltantes — a página pode ter mudado de formato, ou a ETP não existe. Se isso persistir, mande o HTML real da página (Ctrl+U) pra recalibrar.",
      });
    }

    return resposta(200, { ok: true, etp, itens, total: itens.length });
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    return resposta(200, { ok: false, erro: "Falha ao consultar itens faltantes: " + msg });
  }
});
