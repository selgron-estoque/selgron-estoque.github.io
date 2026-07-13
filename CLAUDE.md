# Stock360 — Contexto do Projeto (para Claude Code)

Este arquivo existe para você (Claude Code) entender rápido onde este projeto parou,
sem precisar reconstruir o histórico de decisões do zero.

## O que é

PWA de inventário cíclico industrial (controle de estoque em almoxarifado), com três
perfis (Operador, Líder de Estoque, Administrador), pensado para tablets Android usados
no chão de fábrica. Ver `README.md` na raiz para a lista completa de módulos e
funcionalidades já implementadas.

## Estado atual: protótipo de front-end em um único arquivo

Tudo hoje é **um único `index.html`** com React 18 + Babel Standalone carregados via CDN
(sem build step), Tailwind não é usado — o design system é CSS puro com variáveis
(`:root { --bg, --panel, --safety, ... }`) no topo do `<style>`. Todos os dados (produtos,
usuários, contagens) vivem em `useState` na memória do navegador — nada persiste entre
sessões, não há banco de verdade conectado ainda.

**Isso foi intencional até aqui** (permitiu iterar rápido via chat), mas agora que o
projeto tem autenticação, upload de arquivo, geração de Excel e leitura de câmera, faz
mais sentido migrar para um projeto Vite + React de verdade, com módulos separados. Se o
usuário pedir para "organizar melhor o projeto" ou similar, essa é provavelmente a tarefa:
quebrar o `index.html` em componentes (`src/components/...`), mover os dados mock para
`src/data/`, configurar Vite + PWA plugin, e trocar os CDNs por dependências reais do
`package.json` (`html5-qrcode`, `xlsx`, `react`, `react-dom`).

## Bibliotecas usadas hoje via CDN (candidatas a virar dependências npm)

- React 18 / ReactDOM / Babel Standalone (cdnjs) — trocar por Vite + React quando migrar.
- `html5-qrcode@2.3.8` (jsdelivr) — leitura de QR Code e código de barras pela câmera.
- `xlsx@0.18.5` / SheetJS (cdnjs) — geração do relatório Excel no navegador.

## O que é real vs. o que é mock

| Funcionalidade | Estado |
|---|---|
| Login, sessão, logout por inatividade | Real (mas senha em texto puro em memória — só protótipo, ver aviso no `README.md`) |
| CRUD de usuários, recuperação de senha | Real na UI, mas tudo em memória (some ao recarregar) |
| 300 produtos carregados de uma exportação real da tabela SB2 do Protheus | Dados reais, mas cache estático embutido no JS (`RAW_SB2_PRODUCTS`) — não sincroniza |
| Leitura de QR/código de barras pela câmera | Real (requer HTTPS/localhost + permissão) |
| Geração de relatório Excel (.xlsx) | Real, roda no navegador via SheetJS |
| Envio por e-mail | Parcial — baixa o Excel e abre um rascunho `mailto:` (não anexa automaticamente, é limitação de navegador, documentada no `README.md`) |
| Fila de recontagem de itens divergentes, histórico de rodadas | Real na UI, em memória |
| Endereços físicos dos itens | Não existem ainda no Protheus — o app tem um fluxo de captura incremental (operador informa → líder confirma) |
| Persistência real (banco de dados) | **Não existe ainda** — é o próximo passo grande |

## Backend desenhado, ainda não aplicado

A pasta `backend/` tem tudo desenhado para o Supabase, mas **nada disso foi de fato
aplicado/deployado ainda** — é um projeto Supabase que precisa ser criado do zero:

- `backend/schema.sql` — schema completo (usuários, produtos, saldo em cache, endereços,
  inventários com snapshot de saldo congelado, contagens). Ler os comentários no topo do
  arquivo — explicam por que saldo e endereço têm tratamento diferente (saldo vem do
  Protheus e é só cache; endereço é dado nativo do Stock360).
- `backend/functions/sync-saldo-protheus/index.ts` — Edge Function (Deno) que puxa saldo
  do Protheus e atualiza o cache. Ainda não testada contra uma API real do Protheus (o
  cliente ainda não confirmou o endpoint exato).
- `backend/README.md` — passo a passo de deploy.

Se o usuário pedir para "conectar o banco de verdade" ou "sair do protótipo", comece por
aplicar esse schema num projeto Supabase novo e trocar os `useState` do front-end por
chamadas ao Supabase client, começando por `usuarios` (auth) e `estoque_saldo`.

## Importação de lista de contagem via Excel — implementada

O usuário pediu a funcionalidade de **importar a lista de contagem via Excel** (upload de
uma planilha padrão com a lista de itens a contar, ao invés de o sistema gerar a lista
sozinho). Pedido original:

> "eu quero poder subir lista para contagem via excel, a lista precisa sempre ser padrão.
> ou seja, eu gero uma lista que precisa contar, subo para o app e ele conta a lista que
> aparecer no tablet."

Isso está implementado no `index.html`:
- 5º tipo de inventário em "Módulo 1" (`NewInventory`): "Lista Importada (Excel)".
- Botão "Baixar modelo padrão (.xlsx)" (`buildImportTemplateWorkbook`) — template com as
  colunas **Produto\* (obrigatório), Descrição, End, Sistema, Fisico**, aba "Contar". Esse
  layout foi ajustado para bater exatamente com a planilha real que o cliente já usa hoje
  pra contar (ver `Cont_13.07.xlsx`, enviada durante a conversa) — ele não gera a planilha a
  partir do zero, sempre sobe esse mesmo modelo.
- Upload + parse client-side (`parseImportedListRows`, usando `XLSX.read` +
  `sheet_to_json`), com normalização de cabeçalho (`normalizeHeaderKey` cobre
  acentos/maiúsculas e os dois apelidos de coluna — "Produto"/"Código" pro código,
  "End"/"Endereço" pro endereço), validação do código obrigatório, remoção de duplicatas
  (mantendo a 1ª ocorrência) e um resumo antes de confirmar (linhas válidas, sem código,
  duplicadas, não encontradas no cache local de 300 produtos).
- A coluna **Sistema** (saldo do sistema já vindo na própria planilha) é o que faz a
  importação funcionar de verdade: o cache local do protótipo só tem 300 dos 10.512 SKUs
  reais, então na prática quase todo código importado não está nele (na planilha real de
  teste, só 1 de 23 códigos batia com o cache). Quando a planilha traz "Sistema", esse
  valor prevalece sobre o cache local (mais recente) e a comparação de contagem funciona
  normalmente mesmo pra item fora do cache — só fica sem comparação automática se o código
  não estiver no cache **e** a planilha também não trouxer "Sistema" pra ele
  (`resumo.semSaldoDisponivel` cobre esse caso na tela de criação do inventário).
- A coluna **Fisico** fica no modelo só por compatibilidade com a planilha que o cliente já
  usa — o app ignora essa coluna no import, já que a contagem física é feita
  interativamente dentro do app (câmera + campo de quantidade), não escrita à mão na
  planilha antes de subir.
- `ImportedListCountFlow` (paralelo ao `RandomCountFlow`) percorre a lista importada na
  ordem exata da planilha, sem embaralhar. Ao voltar para o inventário no meio da lista,
  retoma a partir de `inv.contados` — não reinicia do item 1 (isso reaproveita o mesmo
  padrão dos outros fluxos de contagem de item único, que também levam de volta para a
  tela de inventários a cada item).
- Itens cujo código não está no cache local de 300 produtos funcionam normalmente, usando
  os dados que a própria planilha trouxer como fallback (`foraDoCacheLocal: true` no objeto
  de produto sintético). `CountStep` mostra um aviso visual diferente dependendo do caso: se
  a planilha trouxe "Sistema" pra esse código, avisa que só dados complementares (unidade,
  família, valor em estoque) estão faltando mas a comparação funciona; se não trouxe, avisa
  que não há saldo pra comparar e a contagem vai direto pra análise do líder
  (`hasSaldoLocal` controla os dois ramos).
- `MyCounts` e `RecountsPanel` foram ajustados para exibir "—" em vez de quebrar quando
  `diferenca`/`percentual` são `null` (caso dos itens fora do cache local sem "Sistema" na
  planilha).
- O relatório Excel (`generateReportWorkbook`) ganhou uma 4ª aba, **"Contar"**
  (`buildPlanilhaPadraoRows`), no mesmo formato da planilha de importação (Produto,
  Descrição, End, Sistema, Fisico) — "Fisico" sai preenchido com a quantidade contada no
  app. Isso fecha o ciclo: o líder sobe a planilha pra gerar a lista, o app conta, e o
  relatório devolve a mesma planilha com o resultado, no formato que o cliente já usa.
  Também foi adicionado o campo `enderecoContado` na contagem (`CountStep.finalize`) —
  distinto do `endereco` cadastrado: é o endereço que o operador de fato leu/informou na
  hora de contar (`scannedCode` quando há QR, `enderecoInformado` quando não há cadastro).
  Os dois podem divergir quando o operador escaneia um endereço diferente do cadastrado e
  escolhe "Contar mesmo assim". Aparece como coluna extra tanto na aba "Contagens" quanto
  na aba "Contar".

## Clique no card de inventário vai direto pro 1º item (sem tela de escolha)

Antes, clicar num card em "Inventários Pendentes" levava pra `PickCountType` (escolher
Aleatória/Manual/Rota) antes de começar a contar — redundante, já que o tipo já foi
escolhido na criação do inventário. Agora `InventoryList` manda direto pro fluxo de
contagem: `Lista Importada (Excel)` → `importedListCount`; qualquer outro tipo →
`randomCount`, que passou a ser o fluxo genérico de contagem em fila para todos os tipos
não-importados (Aleatória, Curva ABC, Manual, Rota de Endereço — o protótipo nunca teve
listas de itens distintas por tipo, então unificar não muda o comportamento real, só evita
o clique a mais). `PickCountType` continua existindo só para o card "Nova Contagem" da
Home (contagem avulsa, sem inventário associado).

`RandomCountFlow` também mudou: a seleção de itens deixou de usar `Math.random()` (era
re-sorteada a cada vez que a tela remontava, o que fazia a fila "pular" ao voltar e
reentrar no mesmo inventário) e passou a ordenar por **sequência de endereço** — itens com
`enderecoCadastrado` primeiro (por corredor → rua → endereço), os sem endereço ainda depois
mantendo a priorização por valor/movimento de antes. Como retoma a partir de
`inv.contados` (mesmo padrão do `ImportedListCountFlow`), reentrar no inventário continua
de onde parou em vez de reiniciar do item 1.

## Endereço obrigatório, formato fixo, e etapas restritas por perfil

Três ajustes no `CountStep` (motor de contagem compartilhado por todos os fluxos):

- **Formato fixo de endereço da Selgron**: sempre 3 números, traço, 1 letra, traço, 1
  número (ex: `035-A-1`). `formatEnderecoInput` (perto de `MOTIVOS`) aplica essa máscara
  enquanto o operador digita no campo "Endereço onde o item foi encontrado" — insere os
  traços automaticamente e só aceita caractere válido na posição certa. `ENDERECO_REGEX`
  valida o formato completo antes de liberar o botão. Também usado ao normalizar leitura
  de câmera nesse campo (`handleEnderecoManualScanDetected`).
- **Endereço agora é obrigatório**: removido o botão "Pular por enquanto" que existia na
  etapa `enderecoManual` — todo item precisa ter um endereço informado (que bate o
  `ENDERECO_REGEX`) antes de avançar pra contagem. Antes dava pra pular e contar sem
  informar onde o item estava.
- **Foto e motivo da divergência só para líder/admin**: `isOperador` (checa
  `user.perfil==='operador'`) controla dois pontos — ao confirmar a quantidade, o
  operador pula a etapa `photo` (foto + observação) direto pro `result`; e no `result`, o
  select de "Motivo da divergência" fica oculto e deixa de ser exigido pra habilitar
  "Registrar e continuar". Ideia: o operador só conta e informa o endereço certo —
  classificar a divergência e documentar com foto é tarefa de quem vai analisar depois.

## PWA instalável no iOS

O `manifest.json` sozinho não é suficiente pro Safari/iOS — ele ignora manifest pra
ícone e modo de instalação, precisa das tags específicas da Apple no `<head>` do
`index.html`: `apple-touch-icon` (várias resoluções), `apple-mobile-web-app-capable`
(abre em tela cheia ao instalar, sem a UI do Safari), `apple-mobile-web-app-status-bar-style`
(`default`, combina com a topbar clara do app) e `apple-mobile-web-app-title` (nome curto
"Stock360" embaixo do ícone — sem isso o iOS usa o `<title>` inteiro, que trunca).

Os ícones (`apple-touch-icon.png` 180×180, variantes 152×152 e 167×167 pra
iPhone/iPad, `icon-192.png` e `icon-512.png` pro `manifest.json`) foram gerados a partir
do próprio mark da Selgron (o "S" estilizado, sem o texto "SELGRON" — recortado do mesmo
PDF vetorial da logo) centralizado num fundo escuro (`#14161A`), com `PIL`. São arquivos
PNG reais na raiz do projeto, não base64 embutido — ao contrário da logo completa
(`SELGRON_LOGO_URL`) usada dentro do app, esses precisam ser arquivos referenciáveis por
`<link>`/`manifest.json` pro iOS e Android encontrarem.

Câmera (leitura de QR/código de barras via `html5-qrcode`) e service worker já funcionam
no Safari/iOS sem ajuste adicional (iOS 11.3+) — só exigem HTTPS ou `localhost`, mesma
regra do Android.

## Layout desktop com sidebar (só em telas largas, ≥1024px)

O cliente mandou um mockup de dashboard estilo admin (sidebar escura fixa à esquerda,
topbar com avatar do usuário, cards de KPI, grid de "Acesso rápido") e pediu esse
estilo "na web". Decisão confirmada com o usuário: isso só se aplica em telas largas
(desktop) — o tablet/celular do operador no chão de fábrica **continua exatamente como
era antes**, com a topbar + menu inferior mobile-first (não regredir isso). E a
implementação reaproveita só as telas/dados que já existem — não foram criadas
funcionalidades novas (sino de notificação, filtro de período, feed de "últimas
atividades" ficaram de fora por decisão do usuário).

Como funciona: os dois layouts (mobile e desktop) coexistem no mesmo DOM o tempo todo —
não tem branching em JS por `window.innerWidth`. CSS puro decide o que aparece via
`@media (min-width:1024px)`; abaixo disso as classes novas (`.sidebar`,
`.desktop-topbar`, `.desktop-kpi-grid`, `.desktop-quick-grid`, `.desktop-cta-row`) ficam
com `display:none` e o app renderiza exatamente como antes.

- `Sidebar` (novo componente) — logo da Selgron em branco (`SELGRON_LOGO_WHITE_URL`,
  mesma extração do PDF vetorial, recolorida pra fundo escuro `#12151C`), nav com os
  mesmos `view` ids já usados no `goto()` (nenhuma rota nova), seção "Atalhos rápidos"
  (reaproveita as mesmas rotas) e um rodapé estático de versão.
- `DesktopTopbar` (novo componente) — título da página vindo do `VIEW_TITLES` já
  existente (adicionei só a entrada `home:'Início'`, que faltava), avatar com iniciais
  do nome do usuário, e o mesmo botão de logout do `TopBar` mobile.
- `TopBar` (mobile) ganhou a classe `mobile-topbar` só pra CSS conseguir escondê-la em
  telas largas — nenhuma mudança de comportamento nela.
- `Home` ganhou os blocos `desktop-kpi-grid` / `desktop-quick-grid` / `desktop-cta-row`
  — visualmente diferentes do `grid-cards` mobile, mas calculados a partir das MESMAS
  variáveis já existentes no componente (`pendentes`, `pendentesRecontagem`,
  `counts.length`). A única conta nova é `minhasContagens` (contagens filtradas por
  `user.nome` quando `role==='operador'`) — não é dado novo, só aplica o mesmo filtro
  que `MyCounts` já usa, pra "Minhas Contagens" mostrar um número que faz sentido por
  perfil em vez de reusar o total geral.
- `App()`: `.app` virou o container de `<Sidebar>` + `.app-main` (que embrulha
  `TopBar`/`DesktopTopbar`/`SubBar`/`.content`/`BottomNav`, sem tocar na lógica de
  roteamento por `view` que já existia).

Se o usuário pedir mais telas nesse estilo desktop (Dashboard, Relatórios, etc.), o
padrão é esse: adicionar classes `desktop-*` com `display:none` por padrão e regra
dentro do mesmo bloco `@media (min-width:1024px)` no `<style>`, nunca introduzir lógica
de JS pra decidir layout por tamanho de tela.

## Tela de gerenciamento de usuários — edição em tela cheia, busca, sem login duplicado

O fluxo de "Editar" usuário deixou de ser um formulário inline dentro do card (o mesmo
`<form>` que também servia pra "+ Novo Usuário") e virou uma tela cheia dedicada:

- `UserForm` (novo componente) — mesmo formulário de sempre (nome, usuário/login,
  e-mail, senha inicial só na criação, perfil), agora renderizado como uma view própria
  (`view==='userForm'`) em vez de dentro do `UserManagementPanel`. `App()` decide se é
  criação ou edição pelo `flowState.mode` (`'new'` ou o `id` do usuário) — mesmo padrão
  já usado por `RecountFlow`/`ImportedListCountFlow` (`flowState` carrega o contexto da
  navegação). `goto('userForm', {mode:'new'})` pro botão "+ Novo Usuário",
  `goto('userForm', {mode:u.id, initialData:u})` pro "Editar" de cada linha. Salvar ou
  cancelar sempre volta pra `goto('settings')` (isso é feito em `App()`, não dentro do
  `UserForm` — mesmo padrão do `onCreate` do `NewInventory`).
- **Login duplicado**: `isLoginDuplicado(users, usuario, excludeId)` (perto de
  `emptyUserForm`) compara case-insensitive contra todos os usuários, excluindo o
  próprio `id` no modo edição — assim o usuário pode salvar mantendo o login que já
  tinha, só é bloqueado se tentar mudar pra um login que já existe em OUTRO cadastro.
  Mensagem exata pedida pelo cliente: "Este login já está sendo utilizado por outro
  usuário." Validação roda no `submitForm` do `UserForm`, antes de chamar
  `onCreateUser`/`onUpdateUser` — o backend/estado (`createUser`/`updateUser` em
  `App()`) não faz essa checagem de novo, só quem chama o formulário.
- **Busca**: campo "Buscar usuário" no topo do `UserManagementPanel`, filtra por nome,
  login ou e-mail (case-insensitive, `includes`) — mesmo padrão simples de busca já
  usado em `ManualCountFlow`, sem normalização de acento.
- **Paginação**: `USERS_PAGE_SIZE = 8` por página, com "‹ Anterior" / "Próxima ›" e
  contador "Página X de Y · N usuários" — só aparece quando há mais de 1 página. Busca
  reseta a página pra 1 (senão dá pra ficar numa página vazia depois de filtrar).
  Client-side puro (não tem paginação de verdade no backend ainda, é tudo array em
  memória) — se/quando migrar pra Supabase, trocar por `range()`/`limit()` do
  PostgREST, mas a UI (botões + contador) pode continuar igual.
- Permissões não mudaram: `UserManagementPanel` só é renderizado quando `isAdmin` (já
  era assim), e a rota `userForm` em `App()` também está atrás de `role==='admin'` —
  redundância proposital, mesma dupla checagem (visibilidade do botão + guarda na rota)
  que o resto do app já faz em outros lugares (ex: `newInventory`).
- **Excluir usuário** (`deleteUser` em `App()`): botão "Excluir" por linha, com
  confirmação inline (mesmo padrão do `InventoryList`). Não aparece na própria linha do
  admin logado (`u.id!==currentUser.id`) — evita se auto-excluir e ficar sem acesso.
  Fica registrado em `logHistory` (mesmo log de bloqueio/desbloqueio), aparece na tabela
  "Histórico de Alterações de Senha" mesmo não sendo uma ação de senha — reaproveita o
  único mecanismo de auditoria que já existe, mesma decisão já tomada pro
  bloqueio/desbloqueio antes disso.

## "Endereços Pendentes de Cadastro" saiu de Configurações, virou tela própria

O painel de validação de endereço (líder/admin confirma onde o operador disse que
encontrou um item sem endereço cadastrado — Módulo 5/6) ficava empilhado dentro de
Configurações, logo acima de Usuários. O cliente achou que parecia fazer parte do
cadastro de usuário e pediu pra tirar dali.

- Virou `AddressValidationPanel` (componente extraído, mesma lógica/JSX de antes, sem
  mudança visual interna) numa view própria: `goto('enderecos')`. Guard de acesso em
  `App()`: `role==='lider'||role==='admin'` (mesmo grupo que já tinha acesso ao painel
  antes, só mudou onde mora).
- Pontos de entrada, espelhando exatamente o padrão já usado por "Recontagens
  Pendentes" (mesmo card, mesmo lugar): card na Home (mobile e o KPI/quick-access
  correspondente em desktop) com badge mostrando `enderecosPropostos` com
  `status==='pendente'`, item no nav da `Sidebar` e no "Atalhos rápidos" — todos só
  para líder/admin (`podeGerir` no `Home`, `podeValidarEnderecos` na `Sidebar`).
- `Settings` não recebe mais `enderecosPropostos`/`onResolve` como prop (não usa mais).
  O texto de "Origem dos Dados" que dizia "(ver painel acima)" foi corrigido pra
  apontar pro lugar novo, já que o painel não está mais ali do lado.
- Se pedir pra mover mais alguma coisa de dentro de Configurações pra tela própria, o
  padrão é esse: extrair o componente tal como está, criar a `view`, adicionar o guard
  de role em `App()`, e replicar os mesmos 3 pontos de entrada (Home mobile+desktop,
  Sidebar nav, Sidebar atalhos) — não inventar um 4º lugar novo.

## Convenções de design (não quebrar ao continuar)

- Tema claro, alto contraste (fundo cinza-claro `#EEF0F3`, painéis brancos, texto quase
  preto) — foi trocado de um tema escuro anterior porque ficava difícil de ler em tablet
  sob luz forte de almoxarifado. Não reverter para tema escuro.
- Laranja Selgron (`--safety: #F6A200`) como cor de destaque/ação principal — cor oficial
  da marca do cliente (Pantone 137 / CMYK 0,42,100,0), não um amarelo genérico. O cliente
  é a **Selgron**; "Stock360" é o nome do produto/app que roda dentro da marca dela. Cinza
  institucional (`--ink-dim: #575756`, Pantone 432) também vem da identidade da Selgron.
  Fontes: `Logotipo_Selgron_Laranja_CMYK.pdf` e `Logotipo_Selgron_Cores_Promocionais.pdf`
  (enviados pelo cliente durante a conversa).
- Logo oficial da Selgron embutida como base64 (`SELGRON_LOGO_URL`, no topo do
  `<script>`) — extraída do PDF vetorial com PyMuPDF, recortada e redimensionada para
  ~1400×140px. Usada na tela de login (`.login-logo img`) e na topbar (`.brand-logo`).
  Não trocar de volta para o mark de texto "S360" — isso foi um placeholder genérico do
  protótipo antes de o cliente mandar a logo real.
- Tipografia: Oswald (títulos/display), IBM Plex Sans (corpo), JetBrains Mono (códigos,
  labels técnicos).
- Botões grandes, poucos campos por tela, pensado para uso com luvas — não adicionar
  campos de digitação onde um leitor de câmera resolveria melhor.
- Todo texto da interface é em português (pt-BR) — manter esse padrão.
