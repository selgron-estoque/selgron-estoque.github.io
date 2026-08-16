// supabase/functions/consultar-produto-selgron/index.ts
//
// Proxy autenticado pra https://consulta.selgron.com.br/produto.consulta.php
// — puxa saldo/endereço/armazém/unidade AO VIVO, direto dessa consulta
// interna da Selgron (por trás dela está o Protheus), pra CountStep
// mostrar o número mais atual possível no exato momento em que o operador
// abre um item pra contar. Ver CLAUDE.md, seção "Puxar saldo/endereço
// direto do Protheus (consulta.selgron.com.br)" pro contexto completo da
// decisão (por que "ao vivo, sem cache" em vez de sincronização em lote
// como a planilha SB2 — resumo: essa consulta é feita pra 1 produto de
// cada vez, uma ferramenta pensada pra 1 pessoa buscar ocasionalmente, não
// pra receber dezenas de milhares de pedidos de um sincronismo em massa).
//
// NÃO grava nada no Supabase — é um proxy puro (busca fora, devolve pro
// front-end) — por isso não precisa de SUPABASE_SERVICE_ROLE_KEY nem de
// `createClient`, diferente de sync-saldo-protheus/usuarios-admin.
//
// Autenticação com a Selgron: essa consulta.php exige HTTP Basic Auth
// (usuário/senha reais de um funcionário — não havia opção de conta de
// serviço separada disponível no momento, decisão já discutida com o
// cliente). Guardado como secret, NUNCA em código:
//   npx supabase secrets set CONSULTA_SELGRON_USER=<usuario>
//   npx supabase secrets set CONSULTA_SELGRON_PASS=<senha>
//
// Autenticação com o app: deploy padrão, SEM --no-verify-jwt (mesmo padrão
// de usuarios-admin) — só quem já está logado no Gestão de Estoques
// consegue chamar essa function (o JWT vai junto automaticamente via
// `supabaseClient.functions.invoke`).

const CONSULTA_SELGRON_USER = Deno.env.get("CONSULTA_SELGRON_USER") ?? "";
const CONSULTA_SELGRON_PASS = Deno.env.get("CONSULTA_SELGRON_PASS") ?? "";
const CONSULTA_URL = "https://consulta.selgron.com.br/produto.consulta.php";
// Kardex — histórico de movimentação do item, usado só pra derivar a data da
// ÚLTIMA movimentação (pedido do cliente: "não vou mais precisar subir a
// SB2, mas ainda preciso saber quantos dias o material está parado"). Ver
// CLAUDE.md, seção "Última movimentação via Kardex ao vivo" pro contexto
// completo — resumo: cada linha da tabela carrega `data-sort='<unix>'` na
// coluna "Dt. Emissão", então a data mais recente é só um Math.max() sobre
// todos os data-sort da página — nunca dá pra confiar na 1ª linha do HTML
// (as linhas vêm agrupadas por tipo de movimento, não ordenadas globalmente
// por data) nem no campo "Dados Finais" do resumo (é só o fim da janela de
// filtro padrão da própria página, coincide com "hoje", não com a última
// movimentação real — confirmado com o cliente: "Desconsidera isso é outra
// coisa, o campo de data é DT Emissão").
const KARDEX_URL = "https://consulta.selgron.com.br/kardex.php";

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

// Converte o HTML da resposta em texto simples, linha por linha — deliberadamente
// NÃO depende da estrutura exata de tag (table/div/br), já que só tínhamos
// screenshots renderizados do cliente pra confirmar o formato, não o HTML
// cru — só do padrão visual "Rótulo: valor" que se repete em todo exemplo
// já conferido. Mais resistente a pequenas mudanças de marcação do lado de
// lá (mesma filosofia de robustez já usada nos outros parsers deste app).
function htmlParaTexto(html: string): string {
  return html
    .replace(/<script[\s\S]*?<\/script>/gi, " ")
    .replace(/<style[\s\S]*?<\/style>/gi, " ")
    .replace(/<(br|\/tr|\/p|\/div|\/li)\s*\/?>/gi, "\n")
    .replace(/<[^>]+>/g, " ")
    .replace(/&nbsp;/gi, " ")
    .replace(/&amp;/gi, "&")
    .replace(/&lt;/gi, "<")
    .replace(/&gt;/gi, ">")
    .replace(/&quot;/gi, '"')
    .replace(/[ \t]+/g, " ")
    .split("\n")
    .map((l) => l.trim())
    .filter(Boolean)
    .join("\n");
}

// Extrai o valor de um rótulo tipo "Endereço: 006-F-2" do texto já sem
// tags. Aceita mais de um rótulo alternativo (ex: "Armazem"/"Armazém",
// com/sem acento — o print do cliente mostrou "Armazem" sem acento).
function extrairCampo(texto: string, rotulos: string[]): string | null {
  const linhas = texto.split("\n");
  for (const linha of linhas) {
    for (const rotulo of rotulos) {
      const prefixo = rotulo + ":";
      const idx = linha.indexOf(prefixo);
      if (idx !== -1) {
        const valor = linha.slice(idx + prefixo.length).trim();
        if (valor) return valor;
      }
    }
  }
  return null;
}

// Normaliza um código de armazém pra COMPARAÇÃO (não pra exibição) — "01" e
// "1" precisam bater como o mesmo armazém (a consulta Selgron mostra com
// zero à esquerda, "Armazem: 01"; o app internamente usa "1", mesmo valor
// de `estoque_saldo.almoxarifado`/`product.almoxarifado` em todo o resto do
// código). Só remove zero à esquerda quando o valor é 100% numérico — um
// código tipo "EX" ou o texto "Sem armazém" passam intactos (maiúsculos),
// nunca bateriam com um armazém numérico de qualquer jeito.
function normalizarArmazem(v: string | null | undefined): string {
  if (!v) return "";
  const t = String(v).trim();
  if (!t) return "";
  if (/^\d+$/.test(t)) return String(Number(t));
  return t.toUpperCase();
}

// Divide o texto (já achatado por `htmlParaTexto`) em BLOCOS, um por
// resultado — a busca da Selgron pode devolver MAIS DE UM resultado pro
// MESMO código, um por armazém em que ele existe (confirmado com o
// cliente, print real: "Sua busca por 000.05587 retornou 3 resultado(s)",
// com um bloco "Armazem: Sem armazém"/"Quantidade em estoque: 0.0" e outro
// "Armazem: 01"/"Quantidade em estoque: 7.0" — o mesmo código, dois
// armazéns, dois saldos bem diferentes). SEM essa divisão, `extrairCampo`
// (que varre o texto INTEIRO) sempre pegava o valor do PRIMEIRO bloco da
// página inteira — podia ser exatamente o armazém errado, silenciosamente
// (mesma categoria de bug já vista várias vezes neste projeto: nenhum
// erro, só um número errado). Cada bloco começa numa linha "Código do
// Produto: ...", que se repete uma vez por resultado. Sem NENHUMA
// ocorrência desse rótulo (formato inesperado, ou resposta mais antiga que
// nunca teve mais de 1 resultado), cai num único bloco = o texto inteiro —
// mesmo comportamento de sempre, nunca quebra o caso comum de 1 resultado.
function dividirEmBlocos(texto: string): string[] {
  const linhas = texto.split("\n");
  const blocos: string[][] = [];
  let atual: string[] | null = null;
  for (const linha of linhas) {
    if (/^C[oó]digo do Produto\s*:/i.test(linha)) {
      atual = [];
      blocos.push(atual);
    }
    if (atual) atual.push(linha);
  }
  if (blocos.length === 0) return [texto];
  return blocos.map((b) => b.join("\n"));
}

interface BlocoResultado {
  codigo: string | null;
  descricao: string | null;
  saldo: number | null;
  endereco: string | null;
  armazem: string | null;
  unidade: string | null;
}

// Extrai os campos de UM bloco (um resultado da busca) — mesmos rótulos de
// sempre, só que aplicados ao texto do bloco isolado, não à página inteira.
function extrairBloco(blocoTexto: string): BlocoResultado {
  const saldoTexto = extrairCampo(blocoTexto, ["Quantidade em estoque"]);
  const saldoNum = saldoTexto != null ? Number(String(saldoTexto).replace(",", ".")) : null;
  return {
    codigo: extrairCampo(blocoTexto, ["Código do Produto"]),
    descricao: extrairCampo(blocoTexto, ["Descrição", "Descricao"]),
    saldo: saldoNum != null && Number.isFinite(saldoNum) ? saldoNum : null,
    endereco: extrairCampo(blocoTexto, ["Endereço", "Endereco"]),
    armazem: extrairCampo(blocoTexto, ["Armazem", "Armazém"]),
    unidade: extrairCampo(blocoTexto, ["Unidade medida"]),
  };
}

// Extrai o texto de cada célula <td> de UMA linha <tr>...</tr> do Kardex,
// na ordem em que aparecem — usado só pra pegar o "Valor Unitário" da linha
// vencedora (ver `extrairDadosKardex` abaixo), já que essa tabela não tem
// rótulo por célula (é posicional, ao contrário do "Rótulo: valor" da
// consulta de produto) — mesmo padrão "ler por posição de coluna" já usado
// em outros parsers de planilha/tabela deste app quando não há como
// resolver por nome de coluna de forma confiável.
function celulasDaLinha(linhaHtml: string): string[] {
  const matches = [...linhaHtml.matchAll(/<td[^>]*>([\s\S]*?)<\/td>/gi)];
  return matches.map((m) => m[1].replace(/<[^>]+>/g, " ").replace(/&nbsp;/gi, " ").trim());
}

// Índice da coluna "Valor Unitário" dentro da linha (0-based, contando as
// células <td> visíveis) — confirmado no HTML real que o cliente mandou
// (View Source, produto 030.090.00019): Tipo(0) / Produto(1) /
// Descrição(2) / Tipo(3) / Armazém(4) / Quantidade(5) / Valor Unitário(6) /
// ICMS(7) / IPI(8) / TM-TES(9) / Operação(10) / Documento(11) / Serie(12) /
// Centro Custo(13) / OP(14) / SA(15) / Observação(16) / Fornecedor-
// Cliente(17) / Dt. Emissão(18, com data-sort).
const KARDEX_COL_VALOR_UNITARIO = 6;

// Acha a movimentação MAIS RECENTE dentro do HTML do Kardex — varre TODO
// `data-sort='<unix>'` da página (a coluna "Dt. Emissão" da tabela
// DataTables carrega o timestamp Unix pronto ali, mais confiável e simples
// que parsear o texto "DD/MM/AAAA" exibido) e usa a linha com o MAIOR
// valor, já que as linhas vêm agrupadas por tipo de movimento, não
// ordenadas globalmente por data (nunca dá pra confiar na 1ª/última linha
// do documento). Devolve a data dessa linha (formato "YYYY-MM-DD", mesmo
// que `diasParado()`/o resto do app já espera) e o "Valor Unitário" da
// MESMA linha — a movimentação mais recente é a melhor aproximação
// disponível pro custo unitário "atual" do item, já que o Kardex não tem
// nenhum campo de custo médio corrente à parte (mesmo espírito do que a
// planilha SB2 já entregava: valor_financeiro/saldo era só um retrato do
// custo no momento do upload, não um "custo médio" calculado à parte).
// `{ultimaMovimentacao:null, custoUnitario:null}` se a página não tiver
// nenhuma linha reconhecível (item sem nenhuma movimentação, ou o formato
// da página mudou do lado de lá).
function extrairDadosKardex(html: string): { ultimaMovimentacao: string | null; custoUnitario: number | null } {
  const linhas = html.match(/<tr[^>]*>[\s\S]*?<\/tr>/gi) || [];
  let maiorUnix = 0;
  let custoUnitario: number | null = null;
  for (const linha of linhas) {
    const mSort = /data-sort=['"](\d+)['"]/i.exec(linha);
    if (!mSort) continue;
    const v = Number(mSort[1]);
    // Filtro de sanidade: um timestamp em segundos plausível pra "alguma
    // data real do calendário" fica entre ~2000-01-01 (946684800) e
    // ~2100-01-01 (4102444800) — protege contra `data-sort` de OUTRA
    // coluna da mesma tabela (ex: um valor monetário/quantidade) que por
    // acaso também usa esse atributo pro DataTables ordenar numericamente,
    // sem ser uma data de verdade.
    if (!Number.isFinite(v) || v <= 946684800 || v >= 4102444800) continue;
    if (v > maiorUnix) {
      maiorUnix = v;
      const celulas = celulasDaLinha(linha);
      const bruto = celulas[KARDEX_COL_VALOR_UNITARIO];
      const num = bruto != null && bruto !== "" ? Number(String(bruto).replace(",", ".")) : NaN;
      custoUnitario = Number.isFinite(num) ? num : null;
    }
  }
  const ultimaMovimentacao = maiorUnix === 0 ? null : new Date(maiorUnix * 1000).toISOString().slice(0, 10);
  return { ultimaMovimentacao, custoUnitario };
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });

  if (!CONSULTA_SELGRON_USER || !CONSULTA_SELGRON_PASS) {
    return resposta(500, {
      ok: false,
      erro: "Credenciais da consulta Selgron não configuradas (CONSULTA_SELGRON_USER/CONSULTA_SELGRON_PASS).",
    });
  }

  let body: any;
  try {
    body = await req.json();
  } catch {
    return resposta(400, { ok: false, erro: "Corpo da requisição inválido." });
  }

  const codigo = String(body?.codigo || "").trim();
  if (!codigo) return resposta(400, { ok: false, erro: "Código do produto não informado." });
  // Opcional — quando informado (ex.: `product.almoxarifado`, o mesmo
  // código de armazém já usado em todo o resto do app), desambigua entre
  // múltiplos resultados da busca (ver `dividirEmBlocos`/`normalizarArmazem`
  // abaixo). Sem ele, um código com mais de 1 armazém na consulta cai como
  // ambíguo — nunca adivinha, mesmo critério já usado nas funções de
  // catálogo do Supabase (`fetchProdutosByCodigos`/`searchSupabaseCatalog`).
  const armazemPedido = normalizarArmazem(body?.armazem != null ? String(body.armazem) : null);

  try {
    const auth = "Basic " + btoa(`${CONSULTA_SELGRON_USER}:${CONSULTA_SELGRON_PASS}`);

    // Kardex é buscado em PARALELO com a consulta de produto (não em
    // sequência) — reduz a latência total pro operador, já que os dois
    // fetches independem um do outro. Falha do Kardex NUNCA derruba a
    // consulta inteira — `.catch(()=>null)` isola essa 2ª requisição: se
    // ela falhar (timeout, rede, formato mudou), `ultimaMovimentacao`
    // simplesmente sai `null` na resposta, e o resto dos dados do produto
    // (saldo/endereço/descrição/unidade) continua respondendo normalmente.
    const kardexPromise = fetch(
      KARDEX_URL + "?codprod=" + encodeURIComponent(codigo),
      { method: "GET", headers: { Authorization: auth }, signal: AbortSignal.timeout(8000) },
    ).catch(() => null);

    const resp = await fetch(CONSULTA_URL, {
      method: "POST",
      headers: {
        Authorization: auth,
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: "busca=" + encodeURIComponent(codigo),
      // Nunca deixa o operador esperando indefinidamente se a consulta
      // interna ficar lenta/travada — cai pro saldo já em cache (Supabase)
      // que CountStep já usa hoje.
      signal: AbortSignal.timeout(8000),
    });

    // Erros "esperados" (senha errada, código não encontrado, formato
    // mudou) sempre voltam com status 200 e `ok:false` no corpo — mesma
    // lição já documentada em usuarios-admin: um status != 2xx faz o
    // supabase-js do front-end jogar fora o corpo real da resposta e só
    // devolver uma mensagem genérica, então só uso status != 200 pra erro
    // de configuração/requisição malformada (bug de verdade), nunca pra
    // "não achei"/"credencial errada".
    if (resp.status === 401 || resp.status === 403) {
      return resposta(200, { ok: false, erro: "Login/senha da consulta Selgron inválidos ou expirados." });
    }
    if (!resp.ok) {
      return resposta(200, { ok: false, erro: `Consulta Selgron respondeu ${resp.status}.` });
    }

    const html = await resp.text();
    const texto = htmlParaTexto(html);

    if (/retornou\s+0\s+resultado/i.test(texto)) {
      return resposta(200, { ok: false, erro: "Código não encontrado na consulta Selgron.", naoEncontrado: true });
    }

    // Divide a página em blocos (1 por resultado) ANTES de extrair qualquer
    // campo — ver `dividirEmBlocos` pro motivo (mesmo código pode aparecer
    // em mais de um armazém, cada um com seu próprio bloco/saldo).
    const blocos = dividirEmBlocos(texto).map(extrairBloco);

    if (blocos.length === 1 && blocos[0].saldo == null) {
      // Achou a página (não é "0 resultados"), mas não achou o rótulo do
      // saldo no único resultado — sinal de que o formato da página mudou
      // do lado de lá. Melhor devolver erro claro do que fingir um saldo
      // errado (preserva o comportamento de sempre pro caso comum, 1
      // resultado só — a lógica de múltiplos blocos abaixo nunca entra
      // nesse caminho).
      return resposta(200, {
        ok: false,
        erro: "Não consegui ler o saldo na resposta da consulta Selgron (formato da página pode ter mudado).",
      });
    }

    // Escolhe QUAL bloco usar. 1 resultado só -> sem ambiguidade nenhuma,
    // usa ele (comportamento de sempre). Mais de 1 -> só resolve quando o
    // armazém pedido bate com EXATAMENTE 1 bloco; senão (sem armazém
    // informado, nenhum bloco bate, ou mais de um bate — nunca deveria
    // acontecer) fica `null`: cada campo abaixo sai `null` nesse caso, sem
    // adivinhar — o front-end (padrão "...Efetivo" em CountStep) já sabe
    // cair pro saldo/endereço/etc. já em cache no Supabase quando um campo
    // vem `null` daqui, exatamente o comportamento seguro desejado.
    let escolhido: BlocoResultado | null = null;
    if (blocos.length <= 1) {
      escolhido = blocos[0] || null;
    } else if (armazemPedido) {
      const candidatos = blocos.filter((b) => normalizarArmazem(b.armazem) === armazemPedido);
      escolhido = candidatos.length === 1 ? candidatos[0] : null;
    }

    const codigoRetornado = escolhido ? escolhido.codigo : null;
    const descricao = escolhido ? escolhido.descricao : null;
    const endereco = escolhido ? escolhido.endereco : null;
    const armazem = escolhido ? escolhido.armazem : null;
    const unidade = escolhido ? escolhido.unidade : null;
    const saldo = escolhido && escolhido.saldo != null ? escolhido.saldo : null;

    // Resolve o Kardex (já disparado em paralelo lá em cima) — nunca lança
    // erro pra fora daqui, sempre cai em `null` silenciosamente no que
    // falhar (rede, timeout, resposta não-2xx, formato inesperado).
    let ultimaMovimentacao: string | null = null;
    let custoUnitario: number | null = null;
    try {
      const respKardex = await kardexPromise;
      if (respKardex && respKardex.ok) {
        const htmlKardex = await respKardex.text();
        const dadosKardex = extrairDadosKardex(htmlKardex);
        ultimaMovimentacao = dadosKardex.ultimaMovimentacao;
        custoUnitario = dadosKardex.custoUnitario;
      }
    } catch {
      ultimaMovimentacao = null;
      custoUnitario = null;
    }

    return resposta(200, {
      ok: true,
      codigo: codigoRetornado || codigo,
      descricao: descricao || null,
      saldo: saldo != null && Number.isFinite(saldo) ? saldo : null,
      endereco: endereco || null,
      armazem: armazem || null,
      unidade: unidade || null,
      // Kardex não é escopado por armazém nesta versão (a movimentação mais
      // recente vale pro código inteiro) — continua valendo mesmo quando o
      // bloco de saldo/endereço acima ficou ambíguo/sem match.
      ultimaMovimentacao,
      custoUnitario,
      // Informativo só — o front-end não lê isto quando ok:true (cada campo
      // acima já reflete `null` sozinho quando não deu pra resolver), mas
      // ajuda a diagnosticar um "saldo sumiu" via log/DevTools no futuro.
      ambiguo: blocos.length > 1 && !escolhido,
    });
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    return resposta(200, { ok: false, erro: "Falha ao consultar Selgron: " + msg });
  }
});
