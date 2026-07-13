# Stock360 — Inventário Cíclico Industrial

Protótipo funcional (front-end) do PWA descrito no briefing, cobrindo os 10 módulos
especificados. Roda 100% no navegador — não há backend conectado ainda.

## Atualização: Login, Controle de Usuários e Recuperação de Senha

O protótipo agora exige login antes de mostrar qualquer tela do app.

**Tela de login** — usuário/e-mail + senha, botão "Entrar" grande, "Esqueci minha senha",
campos grandes pensados para tablet, mostrar/ocultar senha. Um card de "credenciais de
demonstração" aparece na própria tela (remover isso em produção) porque o protótipo não
tem backend — sem ele, ninguém conseguiria testar os três perfis.

Credenciais de demonstração:
| Usuário | Senha | Perfil |
|---|---|---|
| alisson | admin123 | Administrador |
| roberto.alves | lider123 | Líder de Estoque |
| carlos.mendes | operador123 | Operador |
| fernanda.lima | operador123 | Operador |

**Controle de usuários** (Configurações → visível só para Administrador): criar usuário
(nome completo, usuário de acesso, e-mail opcional, senha inicial, perfil), editar,
bloquear/desbloquear, e redefinir senha de qualquer usuário (gerar temporária, definir
manualmente, ou liberar para o próprio usuário criar). Líder e Operador não têm acesso a
esse painel — o próprio perfil já bloqueia a permissão, então "usuário comum alterar suas
próprias permissões" não é possível na interface.

**Recuperação de senha** — fluxo completo: usuário solicita → fica pendente para o
Administrador (Alisson, semeado como usuário inicial) → admin aprova gerando senha
temporária, definindo uma nova, ou liberando o usuário para criar a própria. Tudo registrado
num histórico (usuário, ação, administrador responsável, data/hora), visível em
Configurações. Por segurança, a tela de solicitação sempre responde com a mesma mensagem
genérica, exista ou não o usuário informado — evita que alguém descubra logins válidos por
tentativa e erro.

**Segurança implementada no protótipo:**
- Sessão individual por usuário logado (guardada em memória — sem localStorage, que não é
  suportado em artifacts).
- Logout manual (botão no topo) e logout automático após 15 minutos de inatividade (sem
  clique, toque ou tecla).
- Bloqueio de usuário pelo administrador impede login imediatamente.
- Controle de permissões por perfil em cada tela (criar inventário só líder/admin, gestão
  de usuários só admin, etc.).

**⚠️ O que isso NÃO é ainda:** o protótipo guarda as senhas em texto puro em memória do
navegador só para simular o fluxo de login sem backend. Isso é aceitável apenas para
demonstração. Em produção, a autenticação deve usar o **Supabase Auth** (ou equivalente),
com hash de senha (bcrypt/argon2) feito no servidor — a senha nunca deve trafegar em texto
puro nem ficar visível para o administrador. As ações "gerar senha temporária" e "definir
senha manualmente" no protótipo mostram o valor em texto só para fins de demonstração; na
versão real, isso seria enviado por um canal seguro (e-mail/SMS) e nunca ficaria gravado
em log.

O protótipo agora carrega **300 itens reais** extraídos de uma exportação da tabela SB2
(Saldo em Estoque) do Protheus — uma amostra dos 10.512 SKUs do Almox 01 (150 de maior
valor financeiro + 150 aleatórios, para representar bem tanto a Curva A quanto o volume
geral do estoque).

**O que a SB2 trouxe:** código do produto, descrição, grupo, saldo atual, valor
financeiro, custo unitário, empenhado e data da última saída.

**O que a SB2 não trouxe (ainda não existe no Protheus):** endereço físico e unidade de
medida. Como o cliente confirmou que o cadastro de endereços ainda não existe, o app foi
ajustado para não travar nisso:

- Nenhum item nasce com endereço cadastrado → o **Módulo 5 (confirmação por QR Code) fica
  em espera** para esses itens.
- No lugar do QR, o operador **informa onde encontrou o item fisicamente** durante a
  própria contagem. Essa informação vai para uma fila de **"Endereços Pendentes de
  Cadastro"**, visível em Configurações para Líder/Administrador, que confirma ou rejeita
  cada proposta.
- É assim que o cadastro de endereços se constrói aos poucos, sem esperar um projeto à
  parte de mapeamento físico do almoxarifado antes de começar a contar.
- O **Módulo 4 (Contagem por Rota)** fica desabilitado na tela de seleção até existir pelo
  menos um endereço confirmado — não faz sentido gerar rota sem endereço.
- A fila do **Módulo 2 (Contagem Aleatória)** já usa dois critérios reais da SB2 citados
  no briefing como "futuros": prioriza itens de maior valor financeiro (proxy de Curva A)
  e itens sem saída registrada recentemente.

Assim que o cadastro de endereços existir no Protheus (ou for populado via essa fila),
basta trocar `enderecoCadastrado: false` por `true` e preencher `endereco` nos dados reais
— toda a lógica de QR Code, contagem cega e rota já está pronta para isso, sem precisar
mudar telas.

## Como abrir

Abra `index.html` em qualquer navegador (ideal: Chrome no Android, para testar a
instalação como PWA). Também pode ser hospedado em qualquer servidor estático
(Vercel, Netlify, Supabase Storage, etc.) — os três arquivos (`index.html`,
`manifest.json`, `service-worker.js`) precisam ficar na mesma pasta.

No tablet Android, abra pelo Chrome → menu → "Adicionar à tela inicial" para instalar.

## O que está implementado no protótipo

- Troca de perfil (Operador / Líder / Administrador) via seletor no topo — simula login,
  já que não há autenticação real ainda.
- Tela inicial com os 5 cards do briefing.
- **Módulo 1** — Criação de inventário (líder): nome, almoxarifado, responsável, data,
  quantidade de itens, 4 tipos de contagem.
- **Módulo 2** — Contagem aleatória: fila gerada automaticamente a partir do mock de
  produtos.
- **Módulo 3** — Contagem manual: busca por código ou descrição.
- **Módulo 4** — Contagem por rota: itens agrupados por corredor → rua, sequência lógica.
- **Módulo 5** — Confirmação de endereço via QR: a leitura agora usa a **câmera real do
  tablet** (biblioteca `html5-qrcode`), lendo tanto QR Code quanto códigos de barras 1D
  (Code128, EAN-13, EAN-8, UPC-A, Code39, ITF). Continua havendo um atalho "sem câmera:
  simular leitura" para testar o fluxo em ambientes sem permissão de câmera.
- **Módulo 6** — Contagem cega: o saldo do sistema nunca é mostrado antes do operador
  informar a quantidade física.
- **Módulo 7** — Regras de segunda contagem, agora com o fluxo completo: ≤5% aprovação
  automática; 5–15% na 1ª contagem fica "aguardando segunda contagem"; acima de 15% (em
  qualquer rodada) vai para "aguardando análise do líder". Veja a seção abaixo.

## Atualização: Relatório Excel (download e e-mail)

Novo card "Relatórios" na tela inicial, com duas ações:

**Baixar Excel (.xlsx)** — geração 100% no navegador usando SheetJS, sem precisar de
backend. O arquivo sai com 3 abas:
- **Resumo** — indicadores gerais (itens contados, divergências, acuracidade, valor
  divergente).
- **Contagens** — todas as contagens registradas, com histórico completo de rodadas
  (1ª, 2ª contagem…), endereço, usuário, quantidade, saldo do sistema, diferença, % de
  divergência, valor, status e motivo.
- **Solicitação de Ajuste** — só os itens com divergência, já no formato pensado para
  mandar à equipe que corrige o saldo no Protheus (código, saldo sistema, saldo contado,
  ajuste necessário, valor, motivo, quem aprovou).

**Enviar por e-mail** — formulário com destinatário, assunto e mensagem. Ao enviar, o
Excel é baixado e o cliente de e-mail padrão do dispositivo abre com o texto pronto
(`mailto:`). Fica registrado um histórico de envios (destinatário, assunto, quem enviou,
quando).

**⚠️ Limitação importante, deixada visível na própria tela:** navegadores não permitem
anexar um arquivo automaticamente a um e-mail por questões de segurança — não existe API
JS para isso. Por isso o fluxo baixa o Excel e abre o e-mail já escrito, mas o anexo
precisa ser adicionado manualmente antes de enviar. Para um envio 100% automático (sem
esse passo manual), é necessário um backend — por exemplo uma Supabase Edge Function que
gera a planilha no servidor e a envia por uma API de e-mail transacional (Resend,
SendGrid, Amazon SES). Essa função reaproveitaria exatamente a mesma lógica de montagem
das 3 abas já implementada aqui no front-end.

Cada contagem finalizada gera um **novo registro**, sem nunca sobrescrever os anteriores —
o histórico completo de cada item (1ª contagem, 2ª contagem, quem contou, quando, qual foi
o resultado) fica preservado e visível.

**Onde encontrar:** novo card "Recontagens Pendentes" na tela inicial (com contador de
pendências), separado em duas filas:
- **Aguardando Segunda Contagem** — itens com divergência entre 5% e 15% na 1ª contagem.
  Botão "Recontar este item" abre uma nova contagem cega para o mesmo item; se for o mesmo
  operador da contagem anterior, aparece um aviso (o processo pede outro operador, mas não
  bloqueia — fica a critério de quem está testando).
- **Aguardando Análise do Líder** — divergências acima de 15%, ou itens que já foram
  recontados e continuam divergindo. Aqui o Líder/Administrador vê o histórico completo
  (1ª contagem, 2ª contagem…) e escolhe entre **"Aprovar divergência"** (fecha o caso) ou
  **"Solicitar nova contagem"** (abre mais uma rodada).

Em "Minhas Contagens" cada item também mostra de qual rodada se trata (ex: "2ª contagem")
e, quando aplicável, o resultado da contagem anterior logo abaixo — sem esconder nada do
histórico.
- **Módulo 8** — Lista padronizada de motivos de divergência, exigida quando há diferença.
- **Módulo 9** — Dashboard com indicadores de operação, qualidade e top itens divergentes.
- **Módulo 10** — Ver seção "Modelo de dados" abaixo — estrutura pronta para Supabase.
- Interface industrial: botões grandes, poucas digitações, cores de status (verde/amarelo/
  vermelho), tipografia condensada de alto contraste, pensada para uso com luvas em tablet.

## O que ainda precisa ser construído para produção

Este arquivo é um protótipo de front-end com dados em memória (perdidos ao recarregar a
página). Para virar o sistema real descrito no briefing, falta:

1. **Autenticação real** (Supabase Auth) com os três perfis e regras de permissão por
   linha (RLS) — hoje o seletor de perfil é só uma simulação visual.
2. **Banco de dados Supabase** com as tabelas abaixo (schema SQL sugerido).
3. ~~Leitura de QR Code real~~ — **já implementada** com `html5-qrcode`, lendo QR e códigos
   de barras 1D pela câmera do tablet. Funciona em qualquer tela que precise identificar um
   item ou endereço (confirmação de endereço, contagem manual, cadastro incremental de
   endereço). Requer HTTPS (ou `localhost`) e permissão de câmera concedida pelo navegador —
   não funciona em `file://` nem sem permissão.
4. **Upload de fotos** para Supabase Storage (hoje as fotos ficam só em memória local).
5. **Motor de geração de fila de contagem** (curva ABC, maior valor, maior giro, histórico
   de divergência, itens sem contagem recente) — hoje a fila aleatória é só um `shuffle`
   simples do mock.
6. **Otimização de rota** por proximidade física de endereço — hoje a "rota" só agrupa por
   corredor/rua, sem um algoritmo de menor deslocamento real.
7. **Integração TOTVS** (saldo de estoque, produtos, endereços) e **Power BI** (exportação
   dos indicadores) — nenhuma das duas está conectada; o modelo de dados abaixo já deixa
   campos livres para isso.
8. **Sincronização offline-first**: hoje o service worker faz cache básico de arquivos
   estáticos; para operar em áreas do almoxarifado com sinal fraco, o ideal é fila de
   contagens pendentes salvas localmente (IndexedDB) e sincronizadas quando a conexão
   voltar.

## Modelo de dados sugerido (Supabase / PostgreSQL)

```sql
create table usuarios (
  id uuid primary key default gen_random_uuid(),
  nome text not null,
  login text unique not null,
  perfil text not null check (perfil in ('operador','lider','admin')),
  status text not null default 'ativo'
);

create table produtos (
  codigo text primary key,
  descricao text not null,
  unidade text not null,
  grupo text,
  custo numeric(12,2)
);

create table enderecos (
  id uuid primary key default gen_random_uuid(),
  almoxarifado text not null,
  rua text not null,
  corredor text not null,
  prateleira text,
  nivel text,
  posicao text,
  qr_code text unique not null
);

create table estoque (
  produto_codigo text references produtos(codigo),
  endereco_id uuid references enderecos(id),
  saldo numeric(12,3) not null default 0,
  primary key (produto_codigo, endereco_id)
);

create table inventarios (
  id uuid primary key default gen_random_uuid(),
  nome text not null,
  almoxarifado text not null,
  responsavel_id uuid references usuarios(id),
  data date not null,
  tipo text not null check (tipo in (
    'aleatoria','curva_abc','manual','rota_endereco'
  )),
  qtd_itens int not null,
  status text not null default 'pendente'
);

create table contagens (
  id uuid primary key default gen_random_uuid(),
  inventario_id uuid references inventarios(id),
  produto_codigo text references produtos(codigo),
  endereco_id uuid references enderecos(id),
  usuario_id uuid references usuarios(id),
  quantidade numeric(12,3) not null,
  saldo_sistema numeric(12,3) not null,
  diferenca numeric(12,3) generated always as (quantidade - saldo_sistema) stored,
  foto_url text,
  observacao text,
  criado_em timestamptz not null default now()
);

create table segunda_contagem (
  id uuid primary key default gen_random_uuid(),
  contagem_original_id uuid references contagens(id),
  segundo_contador_id uuid references usuarios(id),
  quantidade numeric(12,3),
  resultado text,
  aprovado_por uuid references usuarios(id),
  criado_em timestamptz not null default now()
);

create table divergencias (
  id uuid primary key default gen_random_uuid(),
  contagem_id uuid references contagens(id),
  saldo_sistema numeric(12,3),
  saldo_contado numeric(12,3),
  diferenca numeric(12,3),
  valor numeric(12,2),
  motivo text,
  aprovado boolean default false,
  aprovado_por uuid references usuarios(id)
);
```

## Stack usada no protótipo vs. stack recomendada

| Camada | Protótipo (este arquivo) | Produção recomendada |
|---|---|---|
| UI | React via CDN + Babel standalone, um único `index.html` | React (Vite), mesmo design system |
| Dados | Mock em memória (`useState`) | Supabase (Postgres + Auth + Storage + Realtime) |
| QR Code | `html5-qrcode` lendo a câmera (já real) | mesma lib, só trocar o backend de validação |
| Offline | Cache estático simples | IndexedDB com fila de sincronização |
| Deploy | Arquivo estático | Vercel/Netlify + domínio próprio, PWA instalável |
| Relatório/E-mail | Excel gerado no navegador (SheetJS) + `mailto:` (anexo manual) | Supabase Edge Function + Resend/SendGrid (anexo automático) |

Este protótipo é a referência de UX e de fluxo — todas as telas, regras de negócio
(percentuais de divergência, contagem cega, motivos padronizados) e a hierarquia de
permissões já seguem exatamente o briefing, prontas para serem ligadas a um backend real.
