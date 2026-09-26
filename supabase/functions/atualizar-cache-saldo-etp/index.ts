// supabase/functions/atualizar-cache-saldo-etp/index.ts
//
// Pedido do cliente: "não tem como fazer com que ele fique carregando em
// outra tela (Programação), e só mostrar em painel já carregado, com os
// números atualizados?" — o Tracking Picking (painel-indicadores.html, a
// TV) consultava a Selgron AO VIVO, na hora, por ETP, direto do navegador
// que mostra a tela. Isso gerou uma sequência inteira de bugs reais (card
// travado pra sempre, timeout upstream estourando sob concorrência,
// resultado vazio virando erro por engano — ver o histórico de comentários
// em consultar-itens-faltantes/index.ts e painel-indicadores.html antes
// desta mudança) porque a TV — que normalmente fica ligada sozinha, sem
// ninguém "cuidando" dela — precisava esperar e reagir a uma consulta
// upstream lenta/instável em tempo real, sem nenhum lugar pra isso
// acontecer "escondido".
//
// Esta function resolve isso: roda SOZINHA, de tempos em tempos (a cada
// 5 min via Supabase Cron — ver backend/README.md seção 15), busca o saldo
// de TODAS as (ETP, linha) conhecidas — não só as da linha visível agora,
// já que não sabe (nem precisa saber) o que está na tela de ninguém — e
// grava o resultado em `saldo_etp_cache`. O painel-indicadores.html NUNCA
// MAIS consulta a Selgron: só lê essa tabela (Realtime, ver
// `fetchSaldoEtpCache`), sempre mostrando um dado já pronto.
//
// Reaproveita a Edge Function `consultar-itens-faltantes` já existente
// (chamada aqui como uma function-to-function, autenticada com a própria
// SERVICE_ROLE_KEY) em vez de duplicar o parser HTML — o parser (com todo
// o histórico de calibração contra HTML real, filtro de armazém 01,
// tratamento de resultado genuinamente vazio) continua vivendo só num
// lugar, nunca corre o risco de as duas cópias divergirem com o tempo.
//
// "Nunca perder um valor bom": pedido do cliente já atendido antes no
// front-end (PR "mantém o último saldo bom em falhas"), agora centralizado
// aqui — uma falha NUNCA sobrescreve `com_saldo`/`sem_saldo` já gravados
// (o `upsert` de erro só grava as colunas `ultimo_erro`/
// `ultima_tentativa_em`, deixando as outras como estavam); só marca a
// última tentativa como falha, pro front-end mostrar o número antigo com o
// selo de "desatualizado" em vez de escondê-lo.
//
// Autenticação com o app: deploy padrão, COM verificação de JWT — o
// pg_cron autentica com a própria SERVICE_ROLE_KEY no header Authorization
// do `net.http_post` (mesmo padrão já usado por sync-sa-almoxarifado, ver
// backend/README.md seção 13.4).

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// Fallback-do-fallback pra `linha` nula (mesmo valor já usado em
// index.html/painel-indicadores.html, `LINHA_PADRAO`/`LINHA_PADRAO_TRACKING`)
// — só relevante pra itens antigos de `sequencia_separacao` (a única das 2
// tabelas fonte sem `linha` NOT NULL; `maquinas_etp` já migrou pra
// obrigatória).
const LINHA_PADRAO = "Elétrica";

// Mesmo valor de concorrência já validado em produção pro front-end (ver
// `LIMITE_CONCORRENCIA_SALDO_TRACKING`, painel-indicadores.html) — 12
// requisições upstream simultâneas, no máximo (cada chamada aqui dispara 2
// requisições dentro de consultar-itens-faltantes, SEM_SALDO+COM_SALDO em
// paralelo).
const LIMITE_CONCORRENCIA = 6;

// Acima do timeout upstream de consultar-itens-faltantes (`TIMEOUT_UPSTREAM_MS`,
// 30s) — mesmo raciocínio já usado no front-end (`TIMEOUT_CONSULTA_SALDO_MS`
// > timeout interno, pra dar chance da function responder um erro "de
// verdade" primeiro em vez do timeout daqui mascarar tudo) — mais uma folga
// extra aqui por causa do hop function-to-function.
const TIMEOUT_CHAMADA_MS = 45000;

function resposta(status: number, body: unknown) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

async function buscarSaldoEtp(
  etp: string,
): Promise<{ ok: true; comSaldo: number; semSaldo: number } | { ok: false; erro: string }> {
  try {
    const resp = await fetch(`${SUPABASE_URL}/functions/v1/consultar-itens-faltantes`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
        apikey: SUPABASE_SERVICE_ROLE_KEY,
      },
      body: JSON.stringify({ etp }),
      signal: AbortSignal.timeout(TIMEOUT_CHAMADA_MS),
    });
    if (!resp.ok) {
      return { ok: false, erro: `consultar-itens-faltantes respondeu ${resp.status}.` };
    }
    const data = await resp.json();
    if (!data || data.ok !== true) {
      return { ok: false, erro: (data && data.erro) || "Falha ao consultar saldo." };
    }
    return { ok: true, comSaldo: Number(data.comSaldo || 0), semSaldo: Number(data.semSaldo || 0) };
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    return { ok: false, erro: msg };
  }
}

Deno.serve(async (_req: Request) => {
  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

  const { data: logRow, error: logError } = await supabase
    .from("sync_log")
    .insert({ origem: "saldo_etp_cache", status: "em_andamento" })
    .select()
    .single();
  if (logError) {
    return resposta(500, { ok: false, erro: "Falha ao criar log: " + logError.message });
  }

  try {
    // União de `maquinas_etp` e `sequencia_separacao` — mesmo critério já
    // usado no front-end (`computeMaquinasPainelTracking`, `todasEtps`):
    // uma ETP pode ter itens na fila antes mesmo de ter uma linha de cache
    // em `maquinas_etp` (ou vice-versa), então nenhuma das 2 fontes sozinha
    // é suficiente.
    const [maquinasRes, itensRes] = await Promise.all([
      supabase.from("maquinas_etp").select("etp,linha"),
      supabase.from("sequencia_separacao").select("etp,linha"),
    ]);
    if (maquinasRes.error) throw maquinasRes.error;
    if (itensRes.error) throw itensRes.error;

    type ParEtpLinha = { etp: string; linha: string };
    const paresMap = new Map<string, ParEtpLinha>();
    for (const r of [...(maquinasRes.data || []), ...(itensRes.data || [])] as {
      etp: string | null;
      linha: string | null;
    }[]) {
      if (!r.etp) continue;
      const linha = r.linha || LINHA_PADRAO;
      paresMap.set(`${r.etp}|${linha}`, { etp: r.etp, linha });
    }
    const pares = Array.from(paresMap.values());

    let sucesso = 0;
    let comErro = 0;
    let proximaIdx = 0;
    async function processarFila() {
      while (proximaIdx < pares.length) {
        const { etp, linha } = pares[proximaIdx++];
        const res = await buscarSaldoEtp(etp);
        const agora = new Date().toISOString();
        if (res.ok) {
          const { error } = await supabase.from("saldo_etp_cache").upsert(
            {
              etp,
              linha,
              com_saldo: res.comSaldo,
              sem_saldo: res.semSaldo,
              atualizado_em: agora,
              ultimo_erro: null,
              ultima_tentativa_em: agora,
            },
            { onConflict: "etp,linha" },
          );
          if (error) { comErro++; continue; }
          sucesso++;
        } else {
          // Só grava `ultimo_erro`/`ultima_tentativa_em` — NUNCA
          // `com_saldo`/`sem_saldo` (ver comentário do topo do arquivo,
          // "nunca perder um valor bom").
          await supabase.from("saldo_etp_cache").upsert(
            { etp, linha, ultimo_erro: res.erro, ultima_tentativa_em: agora },
            { onConflict: "etp,linha" },
          );
          comErro++;
        }
      }
    }
    await Promise.all(Array.from({ length: Math.min(LIMITE_CONCORRENCIA, pares.length) }, () => processarFila()));

    await supabase
      .from("sync_log")
      .update({
        status: "sucesso",
        itens_processados: sucesso,
        erro: comErro > 0 ? `${comErro} ETP(s) falharam nesta rodada (mantido o último valor bom, quando existia)` : null,
        concluido_em: new Date().toISOString(),
      })
      .eq("id", logRow!.id);

    return resposta(200, { ok: true, totalEtps: pares.length, sucesso, comErro });
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    await supabase
      .from("sync_log")
      .update({ status: "erro", erro: msg, concluido_em: new Date().toISOString() })
      .eq("id", logRow!.id);
    return resposta(200, { ok: false, erro: "Falha ao atualizar cache de saldo: " + msg });
  }
});
