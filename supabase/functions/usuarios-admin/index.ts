// supabase/functions/usuarios-admin/index.ts
//
// Ações privilegiadas sobre `usuarios`/`auth.users` que exigem a service role
// key (bloquear, resetar senha de OUTRO usuário, excluir conta) — por isso
// não podem rodar direto do navegador com a publishable key (ver
// backend/schema.sql, RLS de `usuarios`). Chamada pelo front-end via
// `supabaseClient.functions.invoke(...)`, que já anexa o JWT de quem está
// logado automaticamente.
//
// Uma função só, roteada por `acao` — todas (exceto `auto_definir_senha`,
// ver comentário abaixo) compartilham a MESMA checagem "quem está chamando
// é admin autenticado, não bloqueado" logo no início.
//
// Variáveis de ambiente (já preenchidas automaticamente pelo Supabase,
// mesmo padrão de sync-saldo-protheus): SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

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

function gerarSenhaTemporaria(): string {
  const chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"; // mesmo alfabeto de generateTempPassword no index.html
  let out = "";
  for (let i = 0; i < 8; i++) out += chars[Math.floor(Math.random() * chars.length)];
  return out;
}

function traduzErroAuth(msg: string): string {
  if (/already been registered|already exists/i.test(msg)) return "Este e-mail já está cadastrado.";
  return msg;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });

  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

  let body: any;
  try {
    body = await req.json();
  } catch {
    return resposta(400, { ok: false, erro: "Corpo da requisição inválido." });
  }

  const { acao } = body;

  // ---- Caso especial: SEM autenticação, de propósito ----
  // Usuário foi liberado pelo admin (status='deve_definir_senha') e ainda não
  // consegue logar — a "credencial" é a combinação userId + o fato de o
  // admin já ter marcado essa conta como deve_definir_senha (mesmo modelo de
  // confiança do fluxo local antigo, só que agora do lado do servidor).
  if (acao === "auto_definir_senha") {
    const { userId, novaSenha } = body;
    if (!userId || !novaSenha || String(novaSenha).length < 6) {
      return resposta(400, { ok: false, erro: "Dados inválidos." });
    }
    const { data: perfil, error: perfilErr } = await supabase
      .from("usuarios").select("status").eq("id", userId).single();
    if (perfilErr || !perfil) return resposta(404, { ok: false, erro: "Usuário não encontrado." });
    if (perfil.status !== "deve_definir_senha") {
      return resposta(403, { ok: false, erro: "Esta conta não está liberada para definir uma nova senha." });
    }
    const { error: pwError } = await supabase.auth.admin.updateUserById(userId, { password: novaSenha });
    if (pwError) return resposta(500, { ok: false, erro: pwError.message });
    const agora = new Date().toISOString();
    await supabase.from("usuarios").update({ status: "ativo", ultimo_acesso: agora, atualizado_em: agora }).eq("id", userId);
    return resposta(200, { ok: true });
  }

  // ---- Todas as ações abaixo exigem admin autenticado ----
  const jwt = req.headers.get("Authorization")?.replace("Bearer ", "");
  if (!jwt) return resposta(401, { ok: false, erro: "Não autenticado." });

  const { data: userData, error: userErr } = await supabase.auth.getUser(jwt);
  if (userErr || !userData?.user) return resposta(401, { ok: false, erro: "Sessão inválida ou expirada." });
  const chamador = userData.user;

  // Mesma regra do `hasAccess(user, 'usuarios')` no index.html: admin libera
  // por padrão, ou o chamador tem a exceção 'usuarios' concedida via
  // `acessos_extras` (ver ACESSOS_RESTRITOS/hasAccess) — sem espelhar essa
  // segunda condição aqui, um líder/operador com essa exceção veria a tela
  // "Usuários" normalmente mas todas as ações (criar/bloquear/redefinir
  // senha/excluir) quebrariam com 403, regredindo silenciosamente essa
  // funcionalidade que já existia antes desta migração.
  const { data: perfilChamador } = await supabase
    .from("usuarios").select("perfil,status,acessos_extras").eq("id", chamador.id).single();
  const podeGerenciar = !!perfilChamador && perfilChamador.status !== "bloqueado" &&
    (perfilChamador.perfil === "admin" || (perfilChamador.acessos_extras || []).includes("usuarios"));
  if (!podeGerenciar) {
    return resposta(403, { ok: false, erro: "Você não tem permissão para executar esta ação." });
  }

  try {
    if (acao === "criar_usuario") {
      const { nome, usuario, email, senha, perfil, acessosExtras } = body;
      if (!nome || !usuario || !email || !senha || !perfil) {
        return resposta(400, { ok: false, erro: "Preencha todos os campos obrigatórios." });
      }
      const { data: novoAuth, error: createErr } = await supabase.auth.admin.createUser({
        email, password: senha, email_confirm: true,
      });
      if (createErr) return resposta(400, { ok: false, erro: traduzErroAuth(createErr.message) });

      const { error: insertErr } = await supabase.from("usuarios").insert({
        id: novoAuth.user.id, nome, usuario, email, perfil,
        status: "ativo", acessos_extras: acessosExtras || [],
      });
      if (insertErr) {
        await supabase.auth.admin.deleteUser(novoAuth.user.id); // desfaz o auth.users órfão
        return resposta(400, { ok: false, erro: insertErr.message });
      }
      return resposta(200, { ok: true, id: novoAuth.user.id });
    }

    if (acao === "atualizar_usuario") {
      const { userId, nome, usuario, email, perfil, acessosExtras } = body;
      if (!userId) return resposta(400, { ok: false, erro: "Usuário não informado." });

      if (email) {
        const { error: emailErr } = await supabase.auth.admin.updateUserById(userId, { email, email_confirm: true });
        if (emailErr) return resposta(400, { ok: false, erro: traduzErroAuth(emailErr.message) });
      }
      const patch: Record<string, unknown> = { atualizado_em: new Date().toISOString() };
      if (nome !== undefined) patch.nome = nome;
      if (usuario !== undefined) patch.usuario = usuario;
      if (email !== undefined) patch.email = email;
      if (perfil !== undefined) patch.perfil = perfil;
      if (acessosExtras !== undefined) patch.acessos_extras = acessosExtras;
      const { error } = await supabase.from("usuarios").update(patch).eq("id", userId);
      if (error) return resposta(400, { ok: false, erro: error.message });
      return resposta(200, { ok: true });
    }

    if (acao === "definir_senha") {
      const { userId, modo, novaSenha } = body;
      if (!userId || !modo) return resposta(400, { ok: false, erro: "Dados inválidos." });

      if (modo === "temp") {
        const temp = gerarSenhaTemporaria();
        const { error } = await supabase.auth.admin.updateUserById(userId, { password: temp });
        if (error) return resposta(400, { ok: false, erro: error.message });
        await supabase.from("usuarios").update({ status: "ativo", atualizado_em: new Date().toISOString() }).eq("id", userId);
        return resposta(200, { ok: true, senhaTemporaria: temp });
      }
      if (modo === "definir") {
        if (!novaSenha || novaSenha.length < 6) return resposta(400, { ok: false, erro: "Senha muito curta." });
        const { error } = await supabase.auth.admin.updateUserById(userId, { password: novaSenha });
        if (error) return resposta(400, { ok: false, erro: error.message });
        await supabase.from("usuarios").update({ status: "ativo", atualizado_em: new Date().toISOString() }).eq("id", userId);
        return resposta(200, { ok: true });
      }
      if (modo === "liberar") {
        // Equivalente a "senha:null" do fluxo antigo — o Supabase Auth não
        // aceita login sem senha nenhuma, então embaralha a senha atual
        // (aleatória, nunca exposta) pra invalidar a antiga, e marca
        // deve_definir_senha; quem completa o fluxo é `auto_definir_senha`
        // acima, chamado pelo próprio usuário na tela "Nova senha".
        const { error } = await supabase.auth.admin.updateUserById(userId, { password: gerarSenhaTemporaria() });
        if (error) return resposta(400, { ok: false, erro: error.message });
        await supabase.from("usuarios").update({ status: "deve_definir_senha", atualizado_em: new Date().toISOString() }).eq("id", userId);
        return resposta(200, { ok: true });
      }
      return resposta(400, { ok: false, erro: "Modo inválido." });
    }

    if (acao === "alternar_bloqueio") {
      const { userId } = body;
      const { data: alvo } = await supabase.from("usuarios").select("status").eq("id", userId).single();
      if (!alvo) return resposta(404, { ok: false, erro: "Usuário não encontrado." });
      const novoStatus = alvo.status === "bloqueado" ? "ativo" : "bloqueado";
      // `ban_duration` é o mecanismo nativo do Supabase Auth pra impedir
      // login — usado junto do nosso `status` (fonte de exibição na UI):
      // "876000h" (~100 anos) como "bloqueado até desbloquear", "none" pra
      // remover o bloqueio.
      const { error: banErr } = await supabase.auth.admin.updateUserById(userId, {
        ban_duration: novoStatus === "bloqueado" ? "876000h" : "none",
      });
      if (banErr) return resposta(400, { ok: false, erro: banErr.message });
      await supabase.from("usuarios").update({ status: novoStatus, atualizado_em: new Date().toISOString() }).eq("id", userId);
      return resposta(200, { ok: true, status: novoStatus });
    }

    if (acao === "excluir_usuario") {
      const { userId } = body;
      if (userId === chamador.id) return resposta(400, { ok: false, erro: "Não é possível excluir este usuário." });
      // `on delete cascade` (ver schema.sql) já remove a linha de `usuarios`
      // junto — não precisa de um delete separado na tabela.
      const { error } = await supabase.auth.admin.deleteUser(userId);
      if (error) return resposta(400, { ok: false, erro: error.message });
      return resposta(200, { ok: true });
    }

    return resposta(400, { ok: false, erro: "Ação desconhecida." });
  } catch (err) {
    return resposta(500, { ok: false, erro: String(err instanceof Error ? err.message : err) });
  }
});
