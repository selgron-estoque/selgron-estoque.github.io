// supabase/functions/auth-publico/index.ts
//
// Ações PÚBLICAS (sem sessão nenhuma) relacionadas a autenticação — login e
// recuperação de senha. Separada de propósito de `usuarios-admin/index.ts`
// (que só trata ações administrativas, sempre exigindo um admin/exceção já
// autenticado) — a mistura das duas coisas no mesmo arquivo era exatamente o
// que permitia `auto_definir_senha` (recuperação, sem sessão) conviver com
// `chamarUsuariosAdmin()` chamando `refreshSession()` incondicionalmente
// antes de QUALQUER ação, inclusive essa — travando o fluxo de recuperação
// sempre que não havia sessão nenhuma pra renovar (bug real reportado pelo
// cliente). Esta função nunca é chamada por `chamarUsuariosAdmin` — o
// front-end usa `invocarAuthPublico()`, que NUNCA tenta renovar sessão
// antes (não existe sessão nenhuma pra renovar nesses fluxos).
//
// Duas responsabilidades específicas de segurança que este arquivo resolve:
//
// 1) LOGIN por usuário/e-mail sem expor dado de conta a quem não provou
//    senha ainda. O app aceita login por "usuário ou e-mail", mas o
//    Supabase Auth só autentica por e-mail — antes, a RESOLUÇÃO
//    usuário→e-mail acontecia via uma RPC (`resolver_login`) chamável
//    direto pelo `anon`, que devolvia `id`, `email` e `status` da conta
//    ANTES de qualquer senha ser verificada — um oráculo de existência de
//    usuário (dá pra descobrir se um login existe só testando a RPC) E de
//    dados da conta (e-mail real, se está bloqueada, se está aguardando
//    definir nova senha). Pior: o `id` devolvido virava a "credencial"
//    aceita por `auto_definir_senha` pra trocar a senha de QUALQUER conta
//    com `status='deve_definir_senha'`, sem precisar provar identidade
//    nenhuma — bastava ter (ou adivinhar) o `id`.
//
//    Aqui, a resolução usuário→e-mail acontece DENTRO desta function (com
//    service role, nunca exposta) e SÓ o resultado final da tentativa de
//    login é devolvido — "usuário/e-mail não encontrado" e "senha errada"
//    sempre viram a MESMA mensagem genérica, e só depois de uma senha
//    CORRETA já verificada é que o status da conta (bloqueado/precisa senha
//    nova) é revelado — informação de conta só depois de autenticação,
//    nunca antes (mesmo critério pedido explicitamente: "não permita
//    enumeração de usuários nem forneça dados da conta antes da
//    autenticação").
//
// 2) RECUPERAÇÃO DE SENHA por token aleatório, de uso único, com expiração
//    curta, hash (SHA-256) gravado no banco — nunca o token em texto puro.
//    Sem infraestrutura de e-mail/SMS neste projeto (documentado em
//    CLAUDE.md), o token é gerado só quando um ADMIN (já autenticado) libera
//    a conta em `usuarios-admin` (ação `definir_senha`, modo `liberar`) —
//    mesmo padrão que a senha temporária (`modo='temp'`) já usa: devolvida
//    só pra quem já provou ser admin, que repassa por um canal fora do app
//    (verbal, WhatsApp — como o cliente já opera). O pedido de "esqueci
//    minha senha" feito aqui, sem sessão, NUNCA gera nem devolve token
//    nenhum — só grava uma solicitação (`password_reset_requests`) pro
//    admin ver e agir, resolvendo de quebra o bug de que a lista antiga
//    (`passwordRequests`, `localStorage`) nunca saía do aparelho onde foi
//    criada, então nunca aparecia pro admin em outro dispositivo.
//
// Variáveis de ambiente (auto-preenchidas pelo Supabase, mesmo padrão dos
// outros Edge Functions deste projeto): SUPABASE_URL, SUPABASE_ANON_KEY,
// SUPABASE_SERVICE_ROLE_KEY.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

// Mensagem única pra QUALQUER falha de login (usuário não existe, senha
// errada) — nunca diferenciar, é o que fecha o oráculo de enumeração.
const ERRO_LOGIN_GENERICO = "Usuário ou senha inválidos.";

function resposta(status: number, body: unknown) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...CORS_HEADERS },
  });
}

async function sha256Hex(texto: string): Promise<string> {
  const bytes = new TextEncoder().encode(texto);
  const hashBuffer = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(hashBuffer)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

function gerarTokenAleatorio(): string {
  // 32 bytes (256 bits) de entropia — bem acima do necessário pra um token
  // de uso único e vida curta (30 min), codificado em hex (só [0-9a-f], sem
  // caractere que precise de escape/URL-encoding).
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return Array.from(bytes).map((b) => b.toString(16).padStart(2, "0")).join("");
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });

  const supabaseAdmin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

  let body: any;
  try {
    body = await req.json();
  } catch {
    return resposta(400, { ok: false, erro: "Corpo da requisição inválido." });
  }

  const { acao } = body;

  try {
    // =========================================================================
    // LOGIN — resolve usuário/e-mail → e-mail, verifica a senha DENTRO desta
    // function (nunca expõe e-mail/id/status pra quem ainda não provou
    // conhecer a senha certa).
    // =========================================================================
    if (acao === "login") {
      const identifier = String(body.identifier || "").trim().toLowerCase();
      const senha = String(body.senha || "");
      if (!identifier || !senha) return resposta(400, { ok: false, erro: ERRO_LOGIN_GENERICO });

      const { data: linha } = await supabaseAdmin
        .from("usuarios")
        .select("id,email,status")
        .or(`usuario.ilike.${identifier},email.ilike.${identifier}`)
        .limit(1)
        .maybeSingle();

      if (!linha || !linha.email) {
        // Usuário não encontrado — mesma mensagem de "senha errada", sempre.
        return resposta(200, { ok: false, erro: ERRO_LOGIN_GENERICO });
      }

      // Verificação de senha de verdade via GoTrue — client com a anon key
      // (menor privilégio possível pra essa chamada específica; não precisa
      // de service role pra validar uma senha).
      const supabaseAnon = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
      const { data: authData, error: authErr } = await supabaseAnon.auth.signInWithPassword({
        email: linha.email,
        password: senha,
      });

      if (authErr || !authData?.session) {
        // Senha errada — mesma mensagem de "usuário não encontrado", sempre.
        return resposta(200, { ok: false, erro: ERRO_LOGIN_GENERICO });
      }

      // A partir daqui a pessoa JÁ provou conhecer a senha certa — só agora
      // é seguro revelar algo sobre o estado da conta.
      if (linha.status === "bloqueado") {
        return resposta(200, { ok: false, erro: "Usuário bloqueado. Contate o administrador." });
      }
      if (linha.status === "deve_definir_senha") {
        // Só alcançável na prática se o admin tiver definido uma senha
        // conhecida via `modo='definir'` e, por algum motivo, deixado o
        // status assim (o modo mais comum, `liberar`, embaralha a senha pra
        // um valor que ninguém conhece — inatingível por login normal até a
        // recuperação por token acontecer). Mantido por defesa em
        // profundidade.
        return resposta(200, {
          ok: false,
          needsNewPassword: true,
          erro: "Esta conta precisa de uma nova senha. Use 'Esqueci minha senha'.",
        });
      }

      await supabaseAdmin.from("usuarios").update({ ultimo_acesso: new Date().toISOString() }).eq("id", linha.id);

      return resposta(200, {
        ok: true,
        access_token: authData.session.access_token,
        refresh_token: authData.session.refresh_token,
      });
    }

    // =========================================================================
    // "Esqueci minha senha" — nunca mina nem devolve token nenhum aqui.
    // Só grava uma solicitação pro admin ver (em QUALQUER aparelho — corrige
    // o antigo `passwordRequests` local, que nunca saía do dispositivo onde
    // foi criado) e SEMPRE responde com a mesma mensagem genérica, exista ou
    // não o usuário — mesmo critério de "não confirmar/negar existência" já
    // documentado no comentário antigo desta função no index.html.
    // =========================================================================
    if (acao === "recuperar_solicitar") {
      const identifier = String(body.identifier || "").trim().toLowerCase();
      const MSG = "Se o usuário existir, uma solicitação foi enviada para aprovação do administrador.";
      if (!identifier) return resposta(200, { ok: true, msg: MSG });

      const { data: linha } = await supabaseAdmin
        .from("usuarios")
        .select("id,status")
        .or(`usuario.ilike.${identifier},email.ilike.${identifier}`)
        .limit(1)
        .maybeSingle();

      if (linha && linha.status !== "bloqueado") {
        // Evita empilhar solicitações duplicadas pro mesmo usuário enquanto
        // a anterior ainda não foi resolvida pelo admin.
        const { data: jaPendente } = await supabaseAdmin
          .from("password_reset_requests")
          .select("id")
          .eq("usuario_id", linha.id)
          .eq("resolvido", false)
          .limit(1)
          .maybeSingle();
        if (!jaPendente) {
          await supabaseAdmin.from("password_reset_requests").insert({ usuario_id: linha.id });
        }
      }
      // Sempre a mesma resposta, independente do resultado acima.
      return resposta(200, { ok: true, msg: MSG });
    }

    // =========================================================================
    // Confirma a nova senha usando o TOKEN de recuperação (não mais o
    // userId) — valida hash+expiração+uso único antes de tocar em qualquer
    // coisa.
    // =========================================================================
    if (acao === "recuperar_confirmar") {
      const token = String(body.token || "").trim();
      const novaSenha = String(body.novaSenha || "");
      if (!token || novaSenha.length < 6) {
        return resposta(400, { ok: false, erro: "Dados inválidos." });
      }
      const tokenHash = await sha256Hex(token);
      const agora = new Date().toISOString();

      const { data: linhaToken } = await supabaseAdmin
        .from("password_reset_tokens")
        .select("id,usuario_id,expires_at,used_at")
        .eq("token_hash", tokenHash)
        .maybeSingle();

      if (!linhaToken || linhaToken.used_at || linhaToken.expires_at < agora) {
        // Mensagem única pra qualquer motivo de recusa (não achou, já
        // usado, expirado) — não dá pista sobre qual dos três é o caso.
        return resposta(200, { ok: false, erro: "Token inválido ou expirado." });
      }

      const { data: perfilAlvo } = await supabaseAdmin
        .from("usuarios")
        .select("status")
        .eq("id", linhaToken.usuario_id)
        .maybeSingle();
      if (!perfilAlvo || perfilAlvo.status === "bloqueado") {
        return resposta(200, { ok: false, erro: "Token inválido ou expirado." });
      }

      const { error: pwError } = await supabaseAdmin.auth.admin.updateUserById(linhaToken.usuario_id, {
        password: novaSenha,
      });
      if (pwError) return resposta(500, { ok: false, erro: pwError.message });

      await supabaseAdmin.from("password_reset_tokens").update({ used_at: agora }).eq("id", linhaToken.id);
      await supabaseAdmin
        .from("usuarios")
        .update({ status: "ativo", ultimo_acesso: agora, atualizado_em: agora })
        .eq("id", linhaToken.usuario_id);
      await supabaseAdmin
        .from("password_reset_requests")
        .update({ resolvido: true, resolvido_em: agora, resolvido_por: "recuperação por token" })
        .eq("usuario_id", linhaToken.usuario_id)
        .eq("resolvido", false);

      return resposta(200, { ok: true });
    }

    return resposta(400, { ok: false, erro: "Ação desconhecida." });
  } catch (err) {
    return resposta(500, { ok: false, erro: String(err instanceof Error ? err.message : err) });
  }
});
