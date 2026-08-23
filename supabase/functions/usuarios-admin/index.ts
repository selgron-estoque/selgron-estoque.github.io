// supabase/functions/usuarios-admin/index.ts
//
// Ações ADMINISTRATIVAS AUTENTICADAS sobre `usuarios`/`auth.users` — sempre
// exigem um JWT válido de quem está chamando (bloquear, criar, editar,
// resetar senha de OUTRO usuário, excluir conta). Nunca tratam nenhuma ação
// pública/sem sessão — isso agora mora em `auth-publico/index.ts` (login,
// "esqueci minha senha", confirmação por token) — separação pedida
// explicitamente: misturar as duas coisas no mesmo arquivo era o que fazia
// `chamarUsuariosAdmin()` (que sempre renova a sessão antes de chamar)
// travar o fluxo de recuperação de senha, que nunca tem sessão nenhuma pra
// renovar.
//
// AUTORIZAÇÃO GRANULAR POR AÇÃO (não mais um único "é admin OU tem a
// exceção 'usuarios'" liberando tudo por igual):
//   - Administrador de verdade (perfil='admin'): pode tudo.
//   - Usuário com a exceção 'usuarios' em `acessos_extras` (concedida pelo
//     admin, ver TODOS_OS_MENUS/hasAccess no index.html — essa exceção
//     existe pra deixar um líder GERENCIAR usuários comuns, não pra virar
//     admin por outro caminho): pode criar/editar/bloquear/resetar senha de
//     usuários NÃO-ADMIN, mas NUNCA pode:
//       * criar ou promover ninguém a admin (perfil='admin');
//       * tocar (editar/bloquear/resetar senha) numa conta que JÁ é admin;
//       * excluir QUALQUER usuário (exclusão é sempre admin-only — ação
//         irreversível/de alto impacto).
//   - Qualquer outro chamador (operador sem a exceção, ou não autenticado):
//     nenhuma ação aqui.
// Ver `podeExecutar()` abaixo — checagem central, chamada em CADA ação.
//
// Variáveis de ambiente (já preenchidas automaticamente pelo Supabase, mesmo
// padrão das outras functions): SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY.

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

function gerarTokenAleatorio(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return Array.from(bytes).map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function sha256Hex(texto: string): Promise<string> {
  const bytes = new TextEncoder().encode(texto);
  const hashBuffer = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(hashBuffer)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

function traduzErroAuth(msg: string): string {
  if (/already been registered|already exists/i.test(msg)) return "Este e-mail já está cadastrado.";
  return msg;
}

// Checagem central de autorização por ação — chamada em TODA ação abaixo,
// sempre com o perfil ATUAL do alvo (quando a ação tem um alvo) e o novo
// perfil desejado (quando a ação pode alterar `perfil`, ex. atualizar).
// `null` em `targetPerfilAtual`/`novoPerfilDesejado` significa "não se
// aplica a esta ação" (ex.: criar_usuario não tem perfil atual, exclusão
// não muda perfil).
function podeExecutar(
  perfilChamador: string,
  acessosExtrasChamador: string[],
  acao: string,
  targetPerfilAtual: string | null,
  novoPerfilDesejado: string | null,
): { ok: boolean; erro?: string } {
  if (perfilChamador === "admin") return { ok: true };

  const temExcecaoUsuarios = (acessosExtrasChamador || []).includes("usuarios");
  if (!temExcecaoUsuarios) {
    return { ok: false, erro: "Você não tem permissão para executar esta ação." };
  }

  // Exclusão de usuário é SEMPRE admin-only, mesmo com a exceção.
  if (acao === "excluir_usuario") {
    return { ok: false, erro: "Só um administrador pode excluir usuários." };
  }
  // Nunca pode criar/promover ninguém a admin.
  if (novoPerfilDesejado === "admin") {
    return { ok: false, erro: "Só um administrador pode conceder perfil de administrador." };
  }
  // Nunca pode tocar numa conta que JÁ é admin (editar, bloquear, resetar
  // senha) — mesmo que a intenção não seja mudar o perfil dela.
  if (targetPerfilAtual === "admin") {
    return { ok: false, erro: "Só um administrador pode gerenciar outra conta de administrador." };
  }
  return { ok: true };
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

  // ---- TODA ação deste arquivo exige autenticação ----
  const jwt = req.headers.get("Authorization")?.replace("Bearer ", "");
  if (!jwt) return resposta(401, { ok: false, erro: "Não autenticado." });

  const { data: userData, error: userErr } = await supabase.auth.getUser(jwt);
  if (userErr || !userData?.user) return resposta(401, { ok: false, erro: "Sessão inválida ou expirada." });
  const chamador = userData.user;

  const { data: perfilChamador } = await supabase
    .from("usuarios").select("perfil,status,acessos_extras").eq("id", chamador.id).single();
  if (!perfilChamador || perfilChamador.status === "bloqueado") {
    return resposta(403, { ok: false, erro: "Você não tem permissão para executar esta ação." });
  }
  // Pré-filtro grosso (mantém a compatibilidade de quem nunca teve NENHUMA
  // exceção nem é admin — nem chega a consultar o alvo) — a checagem FINA
  // por ação/alvo acontece dentro de cada bloco, via `podeExecutar()`.
  const temAlgumAcesso = perfilChamador.perfil === "admin" || (perfilChamador.acessos_extras || []).includes("usuarios");
  if (!temAlgumAcesso) {
    return resposta(403, { ok: false, erro: "Você não tem permissão para executar esta ação." });
  }

  try {
    if (acao === "criar_usuario") {
      const { nome, usuario, email, senha, perfil, acessosExtras, acessosRemovidos } = body;
      if (!nome || !usuario || !email || !senha || !perfil) {
        return resposta(400, { ok: false, erro: "Preencha todos os campos obrigatórios." });
      }
      const check = podeExecutar(perfilChamador.perfil, perfilChamador.acessos_extras || [], acao, null, perfil);
      if (!check.ok) return resposta(403, { ok: false, erro: check.erro });

      const { data: novoAuth, error: createErr } = await supabase.auth.admin.createUser({
        email, password: senha, email_confirm: true,
      });
      if (createErr) return resposta(400, { ok: false, erro: traduzErroAuth(createErr.message) });

      const { error: insertErr } = await supabase.from("usuarios").insert({
        id: novoAuth.user.id, nome, usuario, email, perfil,
        status: "ativo", acessos_extras: acessosExtras || [], acessos_removidos: acessosRemovidos || [],
      });
      if (insertErr) {
        await supabase.auth.admin.deleteUser(novoAuth.user.id); // desfaz o auth.users órfão
        return resposta(400, { ok: false, erro: insertErr.message });
      }
      return resposta(200, { ok: true, id: novoAuth.user.id });
    }

    if (acao === "atualizar_usuario") {
      const { userId, nome, usuario, email, perfil, acessosExtras, acessosRemovidos } = body;
      if (!userId) return resposta(400, { ok: false, erro: "Usuário não informado." });

      const { data: alvo } = await supabase.from("usuarios").select("perfil").eq("id", userId).single();
      if (!alvo) return resposta(404, { ok: false, erro: "Usuário não encontrado." });
      const check = podeExecutar(perfilChamador.perfil, perfilChamador.acessos_extras || [], acao, alvo.perfil, perfil ?? null);
      if (!check.ok) return resposta(403, { ok: false, erro: check.erro });

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
      if (acessosRemovidos !== undefined) patch.acessos_removidos = acessosRemovidos;
      const { error } = await supabase.from("usuarios").update(patch).eq("id", userId);
      if (error) return resposta(400, { ok: false, erro: error.message });
      return resposta(200, { ok: true });
    }

    if (acao === "definir_senha") {
      const { userId, modo, novaSenha } = body;
      if (!userId || !modo) return resposta(400, { ok: false, erro: "Dados inválidos." });

      const { data: alvo } = await supabase.from("usuarios").select("perfil").eq("id", userId).single();
      if (!alvo) return resposta(404, { ok: false, erro: "Usuário não encontrado." });
      const check = podeExecutar(perfilChamador.perfil, perfilChamador.acessos_extras || [], acao, alvo.perfil, null);
      if (!check.ok) return resposta(403, { ok: false, erro: check.erro });

      const agora = new Date().toISOString();

      if (modo === "temp") {
        const temp = gerarSenhaTemporaria();
        const { error } = await supabase.auth.admin.updateUserById(userId, { password: temp });
        if (error) return resposta(400, { ok: false, erro: error.message });
        await supabase.from("usuarios").update({ status: "ativo", atualizado_em: agora }).eq("id", userId);
        await marcarSolicitacaoResolvida(supabase, userId, "senha temporária");
        return resposta(200, { ok: true, senhaTemporaria: temp });
      }
      if (modo === "definir") {
        if (!novaSenha || novaSenha.length < 6) return resposta(400, { ok: false, erro: "Senha muito curta." });
        const { error } = await supabase.auth.admin.updateUserById(userId, { password: novaSenha });
        if (error) return resposta(400, { ok: false, erro: error.message });
        await supabase.from("usuarios").update({ status: "ativo", atualizado_em: agora }).eq("id", userId);
        await marcarSolicitacaoResolvida(supabase, userId, "senha definida pelo admin");
        return resposta(200, { ok: true });
      }
      if (modo === "liberar") {
        // Embaralha a senha atual (aleatória, nunca exposta — inutiliza
        // qualquer senha antiga) e gera um TOKEN de recuperação de uso
        // único, com expiração curta (30 min), hash gravado no banco (nunca
        // o token em texto puro) — devolvido só aqui, pro admin já
        // autenticado, pra repassar ao usuário por um canal fora do app
        // (mesmo padrão já usado pra `senhaTemporaria` acima). Quem completa
        // o fluxo é `recuperar_confirmar` em `auth-publico`, chamado pelo
        // próprio usuário na tela "Nova senha", usando o token — nunca mais
        // o `userId` como credencial.
        const { error } = await supabase.auth.admin.updateUserById(userId, { password: gerarSenhaTemporaria() });
        if (error) return resposta(400, { ok: false, erro: error.message });

        // Invalida qualquer token anterior ainda não usado pra este usuário
        // — evita mais de um token válido "vivo" ao mesmo tempo.
        await supabase.from("password_reset_tokens").update({ used_at: agora })
          .eq("usuario_id", userId).is("used_at", null);

        const token = gerarTokenAleatorio();
        const tokenHash = await sha256Hex(token);
        const expiresAt = new Date(Date.now() + 30 * 60 * 1000).toISOString();
        const { error: tokenErr } = await supabase.from("password_reset_tokens").insert({
          usuario_id: userId, token_hash: tokenHash, expires_at: expiresAt,
        });
        if (tokenErr) return resposta(500, { ok: false, erro: tokenErr.message });

        await supabase.from("usuarios").update({ status: "deve_definir_senha", atualizado_em: agora }).eq("id", userId);
        await marcarSolicitacaoResolvida(supabase, userId, "liberado — token gerado");
        return resposta(200, { ok: true, token });
      }
      return resposta(400, { ok: false, erro: "Modo inválido." });
    }

    if (acao === "alternar_bloqueio") {
      const { userId } = body;
      // Mesma proteção que `excluir_usuario` já tinha — sem isso, um admin
      // podia bloquear a própria conta e, como TODA ação admin exige "quem
      // chama não está bloqueado" (checagem acima), ficava sem nenhum jeito
      // de se desbloquear sozinho.
      if (userId === chamador.id) return resposta(400, { ok: false, erro: "Não é possível bloquear a própria conta." });
      const { data: alvo } = await supabase.from("usuarios").select("status,perfil").eq("id", userId).single();
      if (!alvo) return resposta(404, { ok: false, erro: "Usuário não encontrado." });
      const check = podeExecutar(perfilChamador.perfil, perfilChamador.acessos_extras || [], acao, alvo.perfil, null);
      if (!check.ok) return resposta(403, { ok: false, erro: check.erro });

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
      const check = podeExecutar(perfilChamador.perfil, perfilChamador.acessos_extras || [], acao, null, null);
      if (!check.ok) return resposta(403, { ok: false, erro: check.erro });
      // `on delete cascade` (ver schema.sql) já remove a linha de `usuarios`
      // junto — não precisa de um delete separado na tabela.
      const { error } = await supabase.auth.admin.deleteUser(userId);
      if (error) return resposta(400, { ok: false, erro: error.message });
      return resposta(200, { ok: true });
    }

    // Lista as solicitações de "esqueci minha senha" ainda não resolvidas
    // (ver `auth-publico`, ação `recuperar_solicitar`) — substitui o antigo
    // `passwordRequests` local (localStorage, nunca saía do aparelho onde a
    // solicitação foi criada). Mesma checagem de acesso das demais ações
    // (admin ou exceção 'usuarios') — é parte da mesma tela/capacidade de
    // gerenciar usuários.
    if (acao === "listar_solicitacoes_senha") {
      const { data, error } = await supabase
        .from("password_reset_requests")
        .select("id,usuario_id,criado_em,usuarios(nome,usuario)")
        .eq("resolvido", false)
        .order("criado_em", { ascending: false });
      if (error) return resposta(400, { ok: false, erro: error.message });
      return resposta(200, { ok: true, solicitacoes: data });
    }

    return resposta(400, { ok: false, erro: "Ação desconhecida." });
  } catch (err) {
    return resposta(500, { ok: false, erro: String(err instanceof Error ? err.message : err) });
  }
});

// Marca qualquer solicitação pendente deste usuário como resolvida — sempre
// que uma ação de senha (temp/definir/liberar) é tomada sobre ele, faz
// sentido que a solicitação original (se existia) tenha sido atendida.
// Silencioso em erro — nunca deve travar a ação principal por causa disso.
async function marcarSolicitacaoResolvida(supabase: any, userId: string, por: string) {
  try {
    await supabase.from("password_reset_requests")
      .update({ resolvido: true, resolvido_em: new Date().toISOString(), resolvido_por: por })
      .eq("usuario_id", userId).eq("resolvido", false);
  } catch (_e) { /* não crítico */ }
}
