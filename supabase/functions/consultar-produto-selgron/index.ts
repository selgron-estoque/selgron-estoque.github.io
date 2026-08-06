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

    return resposta(200, {
      ok: true,
      codigo: codigoRetornado || codigo,
      descricao: descricao || null,
      saldo: Number.isFinite(saldo) ? saldo : null,
      endereco: endereco || null,
      armazem: armazem || null,
      unidade: unidade || null,
    });
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    return resposta(200, { ok: false, erro: "Falha ao consultar Selgron: " + msg });
  }
});
