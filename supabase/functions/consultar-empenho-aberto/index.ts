// supabase/functions/consultar-empenho-aberto/index.ts
//
// Consulta https://consulta.selgron.com.br/fabrica.consulta.php (a página
// "Empenho Aberto") pelo código de uma ETP e devolve os dados da(s)
// máquina(s)/OP(s) encontradas — pedido do cliente: mostrar um card com
// esses dados como CABEÇALHO, acima da lista de itens faltantes que já
// aparece hoje na tela "Programação" quando o líder busca por uma ETP (ver
// index.html, `ProgramacaoSeparacaoPanel` — a busca por ETP já dispara
// `fetchItensFaltantesPorEtp`, que chama `consultar-itens-faltantes`; esta
// function é uma 2ª busca independente, disparada junto).
//
// Mesmo desenho de `consultar-itens-faltantes`: só um PROXY sob demanda,
// sem NENHUMA escrita no Supabase — recebe {etp}, devolve os resultados
// encontrados, nada é gravado em `sequencia_separacao` a partir daqui (só o
// fluxo de itens faltantes grava, depois que o líder confirma quais itens
// entram).
//
// Autenticação com a Selgron: reaproveita as MESMAS credenciais já
// configuradas pra `consultar-produto-selgron`/`consultar-itens-faltantes`
// (mesmo domínio, mesmo usuário/senha de funcionário — não precisa de
// nenhum secret novo):
//   npx supabase secrets set CONSULTA_SELGRON_USER=<usuario>
//   npx supabase secrets set CONSULTA_SELGRON_PASS=<senha>
//
// Requisição é POST com corpo form-urlencoded (`busca=<etp>`) — diferente
// de `itensfaltantes.php` (GET com querystring), igual ao padrão já usado
// em `consultar-produto-selgron` pra `produto.consulta.php`.
//
// PARSER — calibrado contra o HTML real mandado pelo cliente (ETP
// "6220-26", 1 resultado, via Ctrl+U). Estrutura confirmada:
//   Sua busca por <b>6220-26 </b>  retornou 1 resultado(s)<br><br><br>
//   <table><tr>
//     <td>	OP: <b>526457</b><br>	Cliente: <b>...</b><br>...</td>
//     <td align='center'><a href=...>Ordem de Produção<br></a>...</td>
//   </tr></table>
// — uma ETP pode retornar mais de 1 resultado ("retornou N resultado(s)"),
// cada um virando seu PRÓPRIO <tr> na mesma <table> — o parser suporta N
// linhas, não só 1. Só o 1º <td> de cada <tr> tem dado real (campos
// "Rótulo: <b>Valor</b><br>"); o 2º <td> é só a coluna de links (Ordem de
// Produção/Estrutura/Empenho/Faltantes/etc.) e nunca é lido.
//
// O espaçamento antes do ":" é inconsistente entre campos ("OP:" vs
// "ETP :" vs "Montagem :") — por isso o rótulo é capturado por regex
// tolerante (`[^:<>]+?\s*:`), nunca por posição fixa de caractere, e só
// depois normalizado (sem acento/maiúscula) pra bater com a chave certa.
// Valores sempre vêm com espaço de preenchimento à direita (largura fixa
// do sistema de origem) — sempre `.trim()`.
//
// "01/01/1900" é claramente um placeholder de "data não definida/nunca
// aconteceu" desse sistema legado (mesma ideia de um NULL disfarçado) —
// tratado como AUSENTE (sai `null`), nunca exibido como se fosse uma data
// real, tanto aqui quanto na exibição do front-end.
//
// Distinção "erro real" vs. "resultado vazio real", mesmo critério já
// usado em `consultar-itens-faltantes`/`consultar-produto-selgron`: a
// própria página já anuncia "retornou N resultado(s)" — N=0 é um resultado
// vazio LEGÍTIMO (`resultados:[]`, sem erro nenhum); a mensagem de
// contagem simplesmente NÃO EXISTIR na resposta (nem "0" nem N>0) é que
// sinaliza formato mudado (`ok:false`, pede recalibração).
//
// Colunas de links (2º <td> de cada linha — Ordem de Produção/Estrutura/
// Empenho/Empenho Custo/Faltantes/Devoluções) não são capturadas — não
// interessam pra este card, mesmo critério de "não guardar dado que a
// tela não precisa" já seguido noutras integrações deste projeto.

const CONSULTA_SELGRON_USER = Deno.env.get("CONSULTA_SELGRON_USER") ?? "";
const CONSULTA_SELGRON_PASS = Deno.env.get("CONSULTA_SELGRON_PASS") ?? "";
const EMPENHO_ABERTO_URL = "https://consulta.selgron.com.br/fabrica.consulta.php";

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
    .replace(/[̀-ͯ]/g, "") // remove marcas diacriticas combinantes (acentos)
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

interface EmpenhoAberto {
  op: string | null;
  cliente: string | null;
  nomeFantasia: string | null;
  chassi: string | null;
  etp: string | null;
  codigoProduto: string | null;
  descricao: string | null;
  separacao: string | null; // data DD/MM/AAAA — null quando ausente (inclui o placeholder 01/01/1900)
  montagem: string | null;
  entregaPcp: string | null;
  entregaComercial: string | null;
}

// Os 11 campos capturados, por rótulo NORMALIZADO (sem acento/maiúscula) —
// ver comentário do topo do arquivo pro porquê de comparar por regex
// tolerante em vez de posição fixa de caractere.
const CAMPO_POR_ROTULO: Record<string, keyof EmpenhoAberto> = {
  op: "op",
  cliente: "cliente",
  "nome fantasia": "nomeFantasia",
  chassi: "chassi",
  etp: "etp",
  "codigo do produto": "codigoProduto",
  descricao: "descricao",
  separacao: "separacao",
  montagem: "montagem",
  "entrega pcp": "entregaPcp",
  "entrega comercial": "entregaComercial",
};

const CAMPOS_DATA = new Set<keyof EmpenhoAberto>(["separacao", "montagem", "entregaPcp", "entregaComercial"]);
// Placeholder de "data não definida/nunca aconteceu" nesse sistema legado —
// ver comentário do topo do arquivo.
const DATA_PLACEHOLDER_AUSENTE = "01/01/1900";

function extrairPrimeiraCelula(trHtml: string): string | null {
  const m = /<td[^>]*>([\s\S]*?)<\/td>/i.exec(trHtml);
  return m ? m[1] : null;
}

// Lê os pares "Rótulo: <b>Valor</b>" de dentro do 1º <td> de uma linha —
// funciona independente de eles virem separados por <br> ou não, já que a
// busca global (regex com /g) avança sozinha por cima de qualquer tag
// entre um campo e o próximo.
function extrairCamposDaCelula(tdHtml: string): EmpenhoAberto {
  const resultado: EmpenhoAberto = {
    op: null,
    cliente: null,
    nomeFantasia: null,
    chassi: null,
    etp: null,
    codigoProduto: null,
    descricao: null,
    separacao: null,
    montagem: null,
    entregaPcp: null,
    entregaComercial: null,
  };
  const re = /([^:<>]+?)\s*:\s*<b>([\s\S]*?)<\/b>/gi;
  let m: RegExpExecArray | null;
  while ((m = re.exec(tdHtml))) {
    const campo = CAMPO_POR_ROTULO[normalizarTexto(textoDaCelula(m[1]))];
    if (!campo) continue;
    const valor = textoDaCelula(m[2]);
    if (!valor) continue; // célula vazia — mantém null, nunca fabrica
    if (CAMPOS_DATA.has(campo) && valor === DATA_PLACEHOLDER_AUSENTE) continue; // placeholder — mantém null
    resultado[campo] = valor;
  }
  return resultado;
}

// Devolve `null` quando a página não bate com o formato esperado (sinal de
// recalibrar) — DIFERENTE de devolver `[]` (busca reconhecida, "retornou 0
// resultado(s)" de verdade, sem nenhuma máquina/OP pra essa ETP). Mesma
// distinção já usada em consultar-itens-faltantes/consultar-produto-selgron.
function extrairEmpenhoAberto(html: string): EmpenhoAberto[] | null {
  // Mesmo padrão de detecção de "zero resultados" já usado em
  // consultar-produto-selgron ("retornou 0 resultado(s)") — checado ANTES
  // do caso geral, já que "0" também bate em \d+.
  if (/retornou\s+0\s+resultado/i.test(html)) return [];

  // Sem a mensagem de contagem nenhuma (nem "0" nem N>0) — a página não
  // bate com o formato esperado, precisa recalibrar.
  if (!/retornou\s+\d+\s+resultado/i.test(html)) return null;

  // Tabela com mais <tr> — mesma heurística já usada em
  // consultar-itens-faltantes (sem `id` conhecido pra esta tabela
  // específica, e o HTML confirmado não tem outra tabela grande visível).
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

  const linhas = tabela.match(/<tr[^>]*>[\s\S]*?<\/tr>/gi) || [];
  const resultados: EmpenhoAberto[] = [];
  for (const linha of linhas) {
    const primeiraCelula = extrairPrimeiraCelula(linha);
    if (!primeiraCelula) continue;
    const campos = extrairCamposDaCelula(primeiraCelula);
    // Linha reconhecível precisa de pelo menos OP ou ETP — protege contra
    // uma linha de "lixo" virar um resultado fantasma, todo em branco.
    if (!campos.op && !campos.etp) continue;
    resultados.push(campos);
  }
  // Tabela achada, mensagem dizia N>0, mas nenhuma linha reconhecível —
  // formato mudou de um jeito que este parser não cobre, precisa recalibrar.
  return resultados.length > 0 ? resultados : null;
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
    const resp = await fetch(EMPENHO_ABERTO_URL, {
      method: "POST",
      headers: {
        Authorization: auth,
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: "busca=" + encodeURIComponent(etp),
      // Nunca deixa o operador esperando indefinidamente se a consulta
      // interna ficar lenta/travada.
      signal: AbortSignal.timeout(15000),
    });

    // Erros "esperados" sempre voltam com status 200 e `ok:false` no
    // corpo — mesma lição já documentada nas outras Edge Functions deste
    // projeto: um status != 2xx faz o supabase-js do front-end jogar fora
    // o corpo real da resposta e só devolver uma mensagem genérica.
    if (resp.status === 401 || resp.status === 403) {
      return resposta(200, { ok: false, erro: "Login/senha da consulta Selgron inválidos ou expirados." });
    }
    if (!resp.ok) {
      return resposta(200, { ok: false, erro: `Consulta Selgron respondeu ${resp.status}.` });
    }

    const html = await resp.text();
    const resultados = extrairEmpenhoAberto(html);

    if (resultados === null) {
      return resposta(200, {
        ok: false,
        erro:
          "Não foi possível reconhecer os dados de Empenho Aberto para essa ETP — a página pode ter mudado de formato. Se isso persistir, mande o HTML real da página (Ctrl+U) pra recalibrar.",
      });
    }

    return resposta(200, { ok: true, etp, resultados, total: resultados.length });
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    return resposta(200, { ok: false, erro: "Falha ao consultar Empenho Aberto: " + msg });
  }
});
