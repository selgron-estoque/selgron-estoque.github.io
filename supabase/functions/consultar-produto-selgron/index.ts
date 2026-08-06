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

// Acha a data MAIS RECENTE de movimentação dentro do HTML do Kardex —
// varre TODO `data-sort='<unix>'` da página (a coluna "Dt. Emissão" da
// tabela DataTables carrega o timestamp Unix pronto ali, mais confiável e
// simples que parsear o texto "DD/MM/AAAA" exibido) e devolve o maior
// valor encontrado, já convertido pra "YYYY-MM-DD" (mesmo formato que
// `diasParado()`/o resto do app já espera). `null` se a página não tiver
// nenhuma linha reconhecível (item sem nenhuma movimentação, ou o formato
// da página mudou do lado de lá).
function extrairUltimaMovimentacao(html: string): string | null {
  const regex = /data-sort=['"](\d+)['"]/gi;
  let maiorUnix = 0;
  let m: RegExpExecArray | null;
  while ((m = regex.exec(html)) !== null) {
    const v = Number(m[1]);
    // Filtro de sanidade: um timestamp em segundos plausível pra "alguma
    // data real do calendário" fica entre ~2000-01-01 (946684800) e
    // ~2100-01-01 (4102444800) — protege contra `data-sort` de OUTRA
    // coluna da mesma tabela (ex: um valor monetário/quantidade) que por
    // acaso também usa esse atributo pro DataTables ordenar numericamente,
    // sem ser uma data de verdade.
    if (Number.isFinite(v) && v > 946684800 && v < 4102444800 && v > maiorUnix) {
      maiorUnix = v;
    }
  }
  if (maiorUnix === 0) return null;
  return new Date(maiorUnix * 1000).toISOString().slice(0, 10);
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

    const codigoRetornado = extrairCampo(texto, ["Código do Produto"]);
    const descricao = extrairCampo(texto, ["Descrição", "Descricao"]);
    const saldoTexto = extrairCampo(texto, ["Quantidade em estoque"]);
    const endereco = extrairCampo(texto, ["Endereço", "Endereco"]);
    const armazem = extrairCampo(texto, ["Armazem", "Armazém"]);
    const unidade = extrairCampo(texto, ["Unidade medida"]);

    if (saldoTexto == null) {
      // Achou a página (não é "0 resultados"), mas não achou o rótulo do
      // saldo — sinal de que o formato da página mudou do lado de lá.
      // Melhor devolver erro claro do que fingir um saldo errado.
      return resposta(200, {
        ok: false,
        erro: "Não consegui ler o saldo na resposta da consulta Selgron (formato da página pode ter mudado).",
      });
    }

    const saldo = Number(String(saldoTexto).replace(",", "."));

    // Resolve o Kardex (já disparado em paralelo lá em cima) — nunca lança
    // erro pra fora daqui, sempre cai em `null` silenciosamente no que
    // falhar (rede, timeout, resposta não-2xx, formato inesperado).
    let ultimaMovimentacao: string | null = null;
    try {
      const respKardex = await kardexPromise;
      if (respKardex && respKardex.ok) {
        const htmlKardex = await respKardex.text();
        ultimaMovimentacao = extrairUltimaMovimentacao(htmlKardex);
      }
    } catch {
      ultimaMovimentacao = null;
    }

    return resposta(200, {
      ok: true,
      codigo: codigoRetornado || codigo,
      descricao: descricao || null,
      saldo: Number.isFinite(saldo) ? saldo : null,
      endereco: endereco || null,
      armazem: armazem || null,
      unidade: unidade || null,
      ultimaMovimentacao,
    });
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    return resposta(200, { ok: false, erro: "Falha ao consultar Selgron: " + msg });
  }
});
