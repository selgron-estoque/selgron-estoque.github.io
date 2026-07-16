# Inventário 360 (repo/pasta: Stock360) — Contexto do Projeto (para Claude Code)

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
| Login, sessão, logout por inatividade | Real (mas senha em texto puro — só protótipo, ver aviso no `README.md`). Sessão agora persiste no `localStorage` (`stock360:v1:session`) — recarregar a página NÃO desloga mais; só expira de verdade por inatividade real (15 min) ou logout manual (ver seção "Sessão de login sobrevive a recarregar a página" abaixo) |
| CRUD de usuários, recuperação de senha | Real na UI, persistido no `localStorage` deste navegador (sobrevive a recarregar a página/fechar o navegador neste aparelho) |
| 300 produtos carregados de uma exportação real da tabela SB2 do Protheus | Dados reais, mas cache estático embutido no JS (`RAW_SB2_PRODUCTS`) — não sincroniza |
| Leitura de QR/código de barras pela câmera | Real (requer HTTPS/localhost + permissão) |
| Geração de relatório Excel (.xlsx) | Real, roda no navegador via SheetJS |
| Envio por e-mail | Parcial — baixa o Excel e abre um rascunho `mailto:` (não anexa automaticamente, é limitação de navegador, documentada no `README.md`) |
| Fila de recontagem de itens divergentes, histórico de rodadas | Real na UI, persistido no `localStorage` (ver acima) |
| Endereços físicos dos itens | Não existem ainda no Protheus — o app tem um fluxo de captura incremental (operador informa → líder confirma) |
| Persistência local (localStorage) | **Implementada** (ver seção abaixo) — sobrevive a recarregar a página, mas só neste aparelho/navegador |
| Persistência real sincronizada entre aparelhos (banco de dados) | **Não existe ainda** — é o próximo passo grande, schema já desenhado em `backend/` |

## Persistência local via localStorage — primeiro passo antes do backend real

O usuário pediu pra "começar a trabalhar em salvar os dados lançados no app". Sem um
projeto Supabase real conectado ainda (precisa de credenciais que só o usuário pode
gerar — ver seção "Backend desenhado" abaixo), o primeiro passo possível sem depender de
infraestrutura externa foi persistir os dados no `localStorage` do próprio navegador.

- `usePersistedState(key, initialValue)` (perto de `App()`) — hook genérico: lê do
  `localStorage` na inicialização (`loadPersisted`, com fallback silencioso pro valor
  padrão se não existir nada salvo ainda ou o JSON estiver corrompido) e grava a cada
  mudança via `useEffect`. Chave prefixada com `stock360:v1:` — o `v1` existe pra, se o
  formato dos dados mudar de um jeito incompatível no futuro, bastar subir pra `v2` e o
  app ignora dados antigos em vez de quebrar tentando ler um formato que não bate mais.
- O que passou a persistir: `users`, `inventories`, `counts`, `enderecosPropostos`,
  `passwordRequests`, `passwordHistory`, `reportSendHistory` — tudo que o app hoje
  guarda em `useState` no nível de `App()` e que representa dado "lançado" pelo usuário.
- O que **não** persiste, de propósito: `currentUserId` (sessão de login) e
  `view`/`flowState` (navegação). Recarregar a página sempre volta pra tela de login e
  pra Home — não faz sentido reabrir no meio de um fluxo de contagem sem o contexto
  todo, e manter sessão logada automaticamente teria implicação de segurança maior
  (tablet compartilhado no chão de fábrica).
- **Limitação importante, que o usuário já sabe**: isso é persistência POR APARELHO —
  cada tablet/navegador tem sua própria cópia do `localStorage`, não sincroniza entre
  operadores. Dois tablets contando o mesmo inventário não veem o progresso um do
  outro. Resolver isso de verdade é exatamente o que o backend real (Supabase) faz —
  esse passo aqui só evita perder os dados a cada recarregamento enquanto isso não vem.
- **Nota de segurança**: as senhas de usuário (texto puro, já um limitação conhecida do
  protótipo — ver `README.md`) agora ficam gravadas em disco via `localStorage`, não só
  em memória RAM como antes. Ainda é aceitável só para demonstração/protótipo; reforça
  ainda mais a necessidade do Supabase Auth real antes de qualquer uso em produção.

## Backend desenhado, ainda não aplicado

A pasta `backend/` tem tudo desenhado para o Supabase, mas **nada disso foi de fato
aplicado/deployado ainda** — é um projeto Supabase que precisa ser criado do zero:

- `backend/schema.sql` — schema completo (usuários, produtos, saldo em cache, endereços,
  inventários com snapshot de saldo congelado, contagens). Ler os comentários no topo do
  arquivo — explicam por que saldo e endereço têm tratamento diferente (saldo vem do
  Protheus e é só cache; endereço é dado nativo do Inventário 360).
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
"Inventário 360" embaixo do ícone — sem isso o iOS usa o `<title>` inteiro, que trunca).

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

## Rebrand: "Stock360" → "Inventário 360", e nova identidade visual da tela de login

O usuário pediu pra reformular a identidade visual da tela de login e, ao esclarecer o
escopo (`AskUserQuestion`), confirmou que o nome exibido no app inteiro deveria mudar de
"Stock360" pra **"Inventário 360"** — não só o texto da tela de login. Decisão importante:
isso é só o **nome de marca exibido dentro do app**. O repositório GitHub
(`AlissonSilva-svg/Stock360`) e a pasta local (`/home/user/Stock360`) continuam se
chamando `Stock360` — não foram renomeados (renomear repo/pasta não foi pedido e quebraria
os links já existentes). Se o usuário pedir pra renomear o repo/pasta também no futuro,
isso é uma ação separada e mais delicada — perguntar antes.

**Onde "Inventário 360" passou a aparecer** (substituindo "Stock360"): `<title>` da página,
`apple-mobile-web-app-title`, `manifest.json` (`name`/`short_name`), `TopBar` (brand-text
mobile), `Sidebar` (product name desktop), título da tela de login, assunto padrão do
e-mail de envio de relatório (`ReportSendPanel`). Nomes de arquivo gerados (relatório
Excel, modelo de importação) passaram a usar `Inventario360_...` (sem acento/espaço,
convenção de nome de arquivo). O tagline curto ao lado do nome no topbar/sidebar virou
"Controle Cíclico" (era "Inventário Cíclico" — evita repetir "Inventário" duas vezes ao
lado de "Inventário 360").

**Tela de login — identidade nova, só para essa tela** (`LoginScreen`, `.login-*` no
`<style>`): pedido explícito do cliente foi fugir de uma cara de "template Bootstrap
genérico" e parecer software corporativo/ERP (referências dadas: SAP Fiori, Dynamics 365,
Oracle Fusion, Power BI Service) — branco predominante, azul-marinho, laranja
institucional, sem gradiente forte, sem glassmorphism, sem ilustração grande.

- Paleta nova, escopada só pra tela de login (variáveis `--login-navy` `#0F172A`,
  `--login-gray-50/100/200/400/500`) — não mexe nas variáveis `--bg`/`--panel`/`--ink`
  usadas pelo resto do app (tablet do operador continua exatamente como estava).
- Fonte **Inter** (`--font-login`), carregada junto das fontes já existentes no mesmo
  `<link>` do Google Fonts — só usada dentro de `.login-*`; o resto do app continua
  Oswald/IBM Plex Sans/JetBrains Mono.
- `.login-card`: 500px de largura máxima, `border-radius:8px`, sombra bem suave (`0 1px 2px
  + 0 10px 28px`, opacidade baixa), com uma borda superior de 3px em navy — único toque de
  "software" mais forte, sem exagerar.
- Ícones lineares (SVG inline, `stroke`, sem preenchimento) em vez de emoji: `LoginFieldIcon`
  (usuário/cadeado dentro dos campos), `EyeIcon` (mostrar/ocultar senha, substituiu o botão
  de texto "mostrar"/"ocultar" antigo), `ShieldIcon` (título do card de credenciais de
  demonstração). Emoji (`Ic`) continua normalmente no resto do app (Home, Sidebar etc.) —
  troca foi só nos ícones da tela de login, pra bater com a referência "software B2B".
- `.demo-creds .dc-row` virou layout empilhado (credencial em cima, papel embaixo, com
  divisor sutil entre linhas) em vez de `justify-content:space-between` — o formato antigo
  quebrava feio em telas estreitas (linha "roberto.alves / lider123" + "Líder de Estoque"
  não cabia lado a lado no mobile).
- Rodapé fixo abaixo do card: "Acesso restrito • Uso exclusivo de colaboradores" — precisou
  de `.login-screen{flex-direction:column}` (era só `align-items/justify-content:center`
  sem direção definida, o que jogava o rodapé do lado do card em vez de embaixo).
- `.login-card .role-note` tem override local (fonte Inter, cores navy/cinza) só dentro da
  tela de login, pra o aviso da etapa "esqueci minha senha"/"nova senha" não destoar do
  resto do card — `.role-note` em si (usado em várias outras telas do app) não mudou.
- Testado via Playwright nos três estados (login, erro de senha, "esqueci minha senha" com
  e sem sucesso, "nova senha") e em dois viewports (1280px e 390px) — sem regressão visual
  no resto do app (Home/Sidebar/TopBar só mostram o texto novo "Inventário 360", nada de
  layout mudou fora da tela de login).

## Dashboard novo ("painel") — segundo pedido de redesign, estilo SaaS B2B/ERP

Depois do rebrand e da tela de login, o cliente pediu pra redesenhar "o dashboard
principal" com o mesmo tipo de referência (SAP Fiori, Dynamics 365, Oracle Fusion, Jira
Cloud, Monday Enterprise, Teamcenter, FactoryTalk) — grid de 12 colunas, espaçamento em
múltiplos de 8, paleta navy/branco/laranja, tipografia Inter, ícones lineares (Lucide),
cards com raio de 10px e sombra discreta.

**Decisão de escopo original (perguntada ao usuário via `AskUserQuestion`)** — **SUPERADA
logo em seguida, ver seção "Dashboard vira a tela inicial" mais abaixo, não usar esta
parte como referência do estado atual**: o app já tinha DUAS telas diferentes — "Início"
(`view==='home'`, o que abre depois do login, com KPIs e atalhos) e "Dashboard"
(`view==='dashboard'`, uma tela de analytics à parte só com gráficos simples). O pedido
novo não mencionava "Início" na lista de menu, só "Dashboard" — o cliente escolheu de
início manter as duas telas antigas E criar a nova como um terceiro destino separado
(view `painel`, só na `Sidebar` desktop). Ao ver o resultado, o cliente pediu pra
simplificar: excluir "Início" e a `Dashboard` nova passar a ser a própria tela inicial —
é isso que está implementado hoje, não o esquema de 3 telas descrito no parágrafo acima.

- **`dashboard`** (a tela de analytics antiga) — não mudou de conteúdo, só de **nome**:
  virou "Indicadores" (label na `Sidebar`, em `VIEW_TITLES['dashboard']`, e nos 3 lugares
  do `Home` que apontavam pra ela — KPI card, quick-access card, home-card mobile) pra
  não colidir com o item "Dashboard" no menu. O `goto('dashboard')` continua indo
  pro mesmo componente `Dashboard` de sempre, só o texto visível mudou.

**Paleta/tipografia compartilhada com o login**: as variáveis CSS que a tela de login já
tinha (`--login-navy`, `--login-gray-*`, `--font-login`) foram renomeadas pra
`--navy`/`--gray-*`/`--font-corp` (sem o prefixo "login") porque agora servem os dois —
login e dashboard novo. Resto do app (tablet do operador, Início, Inventários por
dentro, etc.) continua no design system original (`--bg`/`--ink`/Oswald/IBM Plex/mono).

**Sidebar e header viraram compartilhados entre TODAS as telas desktop** (diferente da
tela de login, que tinha uma paleta 100% isolada): como `Sidebar`/`DesktopTopbar` são
componentes únicos renderizados pelo `App()` ao redor de qualquer `view`, não dava pra
ter uma sidebar "nova" só na tela Dashboard sem afetar as outras — a atualização de
cor/fonte/ícone da moldura desktop (fundo `var(--navy)` em vez do `#12151C` antigo,
ícones lineares em vez de emoji, header de 72px) vale pra Inventários, Configurações etc.
também. O CONTEÚDO interno de cada tela (o que tem dentro de `.content`) continua com o
design antigo — só a moldura (sidebar + header) e o Dashboard em si (hoje é a própria
tela `home`, ver seção abaixo) usam a paleta nova. Mobile (tablet do chão de fábrica) não
foi tocado em nada.

**Ícones "Lucide"**: o projeto não tem build step (React/Babel via CDN, sem bundler), e
não faz sentido puxar mais uma dependência CDN pra um pacote de ícones sem componentes
React prontos pra uso direto. Em vez disso, os ícones foram desenhados à mão no mesmo
estilo visual do Lucide (`DICON_PATHS`/`DIcon`, perto dos ícones da tela de login) —
stroke 1.8-2px, viewBox 24×24, cantos arredondados. Usado só na sidebar/header desktop e
no Dashboard novo; o resto do app continua com emoji (`Ic`), não foi trocado.

**KPIs — só dado real, nada fabricado**: os 5 KPIs (Inventários em Andamento,
Recontagens Pendentes, Itens Divergentes, Contagens Concluídas Hoje, Acuracidade do
Estoque) vêm todos de `counts`/`inventories` já existentes. O pedido queria "indicador de
tendência + comparação com período anterior" em todos, mas o app não guarda snapshot
histórico de estado (não dá pra saber quantos "inventários em andamento" existiam ontem
sem um log de eventos que não existe). Solução: onde dá pra calcular uma comparação real
(Itens Divergentes, Contagens Concluídas Hoje, Acuracidade — todos cumulativos a partir
do campo `data` de cada `count`, comparando "até hoje" vs. "até ontem", ver
`acumuladoAte()`/`pnlTrendPct()` em `MainDashboard`), mostra a variação de verdade. Onde
não dá (Inventários em Andamento, Recontagens Pendentes — puro estado atual, sem
histórico), mostra uma nota contextual real (ex: "1 aguardando início", "Nenhuma
pendência") em vez de inventar uma porcentagem sem base. Se o backend real (Supabase)
um dia guardar histórico de verdade, essas duas notas podem virar tendência real também.

**Situação Geral dos Inventários (donut) e Status dos Inventários (tabela de barras)**:
o pedido queria 4 categorias (Planejados/Em andamento/Concluídos/Cancelados), mas hoje só
existem 2 status reais no campo `inventories[].status` (`pendente`, `em_andamento`) — não
existe fluxo de "cancelar inventário" no app. Em vez de fabricar dado, as 4 categorias são
DERIVADAS de campos que já existem e são 100% reais: Planejados = `contados===0`, Em
andamento = `0<contados<qtdItens`, Concluídos = `contados>=qtdItens`, Cancelados =
`status==='cancelado'` (sempre 0 hoje, honestamente — zero real, não fabricado — porque
não existe essa ação ainda; se um dia o app ganhar "cancelar inventário", essa categoria
passa a preencher sozinha).

**Filtro de período** (canto direito do header, só aparece na tela `painel` via prop
`rightExtra` do `DesktopTopbar`): "Últimos 7 dias" / "Últimos 30 dias" / "Todo o período".
Afeta só a tabela "Últimas Atividades" (filtra quais `counts` aparecem, por `data`) — os
5 KPIs têm semântica fixa própria (“hoje”, cumulativo) e não mudam com o filtro, pra não
ficar ambíguo o que cada número significa. Estado (`dashboardPeriod`) mora em `App()`,
não persiste (é navegação/UI, mesmo critério já usado pra `view`/`flowState`).

**Notificações e "últimas atividades"**: uma decisão ANTERIOR (na época do primeiro
layout desktop com sidebar, ver seção mais acima) tinha tirado sino de notificação,
filtro de período e feed de atividades do escopo. Esse pedido novo trouxe os três de
volta explicitamente — decisão atual substitui a anterior. O sino (`.desktop-bell`) é
decorativo/honesto: abre um dropdown fixo dizendo "Nenhuma notificação por enquanto" (não
existe sistema de notificações no app, então não finge que existe uma lista real).

**Menu do usuário**: o botão de logout solto ao lado do avatar (como era antes) virou um
dropdown (`.desktop-user-menu`) com nome+perfil e o botão "Sair" dentro — só no
`DesktopTopbar`. O `TopBar` mobile não mudou (continua com o botão de logout solto de
sempre).

**Rodapé** ("© Selgron" / "Política de Privacidade" / "Termos de Uso"): não existem
páginas reais de política/termos no protótipo, então os dois últimos são `<span>` inertes
(sem `href`), não `<a>` — evita fingir um link funcional que não leva a lugar nenhum.

**Bug encontrado e corrigido durante o teste desta feature (não é parte do pedido, mas
era regressão do rebrand anterior)**: o topbar mobile (`.topbar`/`.brand-text`) quebrava
em 3 linhas em telas estreitas (~390px) porque "Inventário 360" é mais longo que
"Stock360" (nome anterior). Corrigido com uma media query `max-width:400px` que reduz o
`.brand-text` e esconde o texto do `.role-pill` (fica só o ícone), mantendo o topbar numa
linha só. Ver comentário no CSS perto de `.logout-btn`.

## Dashboard vira a tela inicial (fundiu com "Início")

Depois de ver o Dashboard novo funcionando ao lado de "Início" na sidebar, o cliente
simplificou o pedido: **"pode excluir a Início e tornar a Dashboard como Início"**. Ou
seja, o esquema de 3 telas (Início / Dashboard / Indicadores) descrito na seção anterior
durou pouco — virou 2: **Dashboard** (agora É a tela que abre depois do login) e
**Indicadores** (a tela de analytics antiga, sem mudança).

O que foi feito, tecnicamente — a view `painel` (que tinha sido criada como destino
separado) foi **removida**, e o conteúdo dela (KPIs, atividades, ações rápidas, donut)
foi **movido pra dentro do bloco desktop do componente `Home`** (`view==='home'`),
substituindo o antigo `desktop-kpi-grid`/`desktop-quick-grid`/`desktop-cta-row`. Os
helpers ficaram onde estavam (`pnlPeriodCutoff`, `pnlTrendPct`, `KpiTrend`, `PnlDonut`,
perto do comentário "DASHBOARD (agora é a tela home)") — só o componente `MainDashboard`
em si foi apagado, sua lógica interna virou parte do corpo de `Home`.

- **`Sidebar`**: os dois itens antigos ("Dashboard" apontando pra `painel`, "Início"
  apontando pra `home`) viraram **um único item** — `{id:'home', ic:'layoutDashboard',
  label:'Dashboard'}`, primeiro da lista.
- **`VIEW_TITLES.home`**: era `'Início'`, agora é `'Dashboard'` (usado pelo header
  desktop e como fallback; a tela `home` não passa pelo `SubBar`, então essa mudança não
  afeta a barra de "← Voltar" em lugar nenhum).
- **`VIEW_SUBTITLES`**: chave trocou de `painel` pra `home` (mesmo valor, "Resumo
  operacional do inventário").
- **Filtro de período** (`rightExtra` do `DesktopTopbar`) trocou a condição de
  `view==='painel'` pra `view==='home'`.
- **Mobile — decisão deliberada de NÃO renomear**: o `BottomNav` (barra inferior do
  tablet) continua com o item `{id:'home', label:'Início'}` — não virou "Dashboard" no
  mobile. Motivo: o conteúdo que `Home` renderiza pro mobile (o `grid-cards` simples de
  atalhos) não mudou em nada — só o bloco desktop ganhou o Dashboard novo. Como o mobile
  continua sendo literalmente a tela "Início" de sempre (não o dashboard com KPIs/donut,
  que é desktop-only), manter o rótulo "Início" lá é mais honesto do que chamar de
  "Dashboard" algo que visualmente não é um. Se um dia o Dashboard novo ganhar uma versão
  mobile de verdade, aí sim faz sentido renomear o `BottomNav` também.
- **Bug que essa mudança quase reintroduziu**: as classes `.pnl-*` (KPIs, tabela de
  atividades, donut etc.) só tinham regra CSS dentro do `@media (min-width:1024px)` — ao
  virarem parte do `Home` (que renderiza em qualquer largura de tela), sem uma regra
  `display:none` por padrão elas apareciam SEM ESTILO ALGUM no mobile, empilhadas em cima
  do `grid-cards` de sempre. Corrigido adicionando `.pnl-wrap` à lista de seletores com
  `display:none` por padrão (perto de `.desktop-kpi-grid` etc.) e `display:block` de volta
  dentro do media query. Se algum dia mover mais conteúdo `.pnl-*`/`desktop-*` pra dentro
  de um componente que também renderiza no mobile, checar sempre esse padrão.

**Atualização — rótulo voltou a ser "Início"**: o cliente pediu pra trocar o nome do
item da `Sidebar` de volta pra "Início" (com o ícone de casa, `ic:'home'`) — o conteúdo
da tela (KPIs, atividades, donut) não mudou, só o nome exibido. Ajustado em 3 lugares pra
não ficar inconsistente entre sidebar e header: `Sidebar.items[0]` (`label:'Início'`,
`ic:'home'`), `VIEW_TITLES.home` (`'Início'`, usado pelo título do `DesktopTopbar`), e o
fallback `VIEW_TITLES[view] || 'Início'` no próprio `DesktopTopbar`. O ícone
`layoutDashboard` continua definido em `DICON_PATHS` mesmo sem uso no momento — barato
manter, pode servir de novo se precisar de um ícone de dashboard em outro lugar.

## Tela de login vira o mockup de 2 colunas (referência exata do cliente)

A primeira versão da tela de login (card único centralizado, ver seção "Rebrand" acima)
seguia o *texto* do pedido original ("card centralizado 460-520px", "não utilizar
ilustrações grandes") — mas o cliente tinha mandado uma imagem de referência desde o
início que era, na real, um mockup de **duas colunas** (ilustração à esquerda + formulário
à direita). Quando o cliente viu o resultado e pediu explicitamente **"quero que deixe a
tela de login igual esta segunda imagem"**, a instrução concreta (a imagem) passou a
valer mais que a descrição textual anterior — reconstruí a tela pra bater com o mockup.

- **`.login-card` virou `display:flex`**, largura máxima 900px (era 500px, card único),
  `border-radius:20px`, dividido em duas colunas-filhas com `align-items:stretch` (as
  duas colunas ficam sempre com a mesma altura, a da direita — que tem mais conteúdo —
  dita a altura da esquerda).
- **`.login-illustration`** (coluna esquerda, ~38% da largura, fundo `var(--gray-50)`):
  logo Selgron no topo, `CycleIcon` (ícone novo — duas setas em arco formando um ciclo em
  volta de uma caixa isométrica, desenhado à mão em SVG pra representar "contagem
  cíclica", mesmo raciocínio dos ícones estilo Lucide) + "Inventário 360" + tagline "Visão
  completa. Controle eficiente." centralizados, e um recorte diagonal decorativo
  (`.login-illust-decor`, `clip-path` + `repeating-linear-gradient` pra sugerir linhas de
  prateleira + gradiente laranja) no canto inferior — like a imagem de referência, mas
  **sem foto real de estoque** (o app não tem esse asset; a textura foi desenhada só com
  CSS, mantendo o espírito "sem foto de estoque" do pedido original enquanto imita a
  composição visual pedida agora).
- **Coluna esquerda: nunca `display:none` — vira uma faixa compacta em telas
  estreitas, em vez de sumir**. Primeira versão escondia a ilustração inteira abaixo de
  760px (`display:none`), mas o cliente testou num tablet mais estreito que isso e viu só
  o formulário puro, sem nenhuma identidade visual — pediu pra aparecer "aquele padrão"
  em qualquer tamanho de tela. Virou mobile-first de verdade: por padrão (telas
  estreitas) é uma faixa horizontal só com logo + `CycleIcon` pequeno (36px, tamanho via
  classe `.login-cycle-icon`, não mais via prop `size` do componente — o SVG não tem
  `width`/`height` fixo, só `className`, pra CSS conseguir redimensionar por breakpoint),
  sem título nem tagline nem o recorte diagonal (`display:none` nesses elementos por
  padrão) — não cabe tudo numa faixa baixa sem atrapalhar o formulário abaixo. A partir de
  `@media (min-width:760px)` vira a coluna alta e centralizada de antes (título 23px,
  tagline, ícone 104px, recorte diagonal) — `.login-card` também troca de
  `flex-direction:column` (empilhado) pra `row` (lado a lado) nesse breakpoint.
- **Coluna direita** (`.login-form-panel`): título "Inventário **360°**" (o `°` faz parte
  do texto, como na imagem), barrinha laranja decorativa (`.login-rule`) embaixo do
  subtítulo, campos com ícone à esquerda, e o toggle de senha virou ícone + texto
  "Mostrar"/"Ocultar" lado a lado (`.pw-toggle` ganhou `gap`+texto, antes era só ícone) —
  bate com a imagem, que mostra "👁 Mostrar" por extenso.
- **Divisor "ou"** (`.login-or`, linha horizontal dos dois lados) entre o botão Entrar e
  "Esqueci minha senha" — elemento novo que não existia na v1.
- **Credenciais de demonstração**: veio com avatar circular (ícone de pessoa) por linha e
  um **pill colorido por papel** (`dc-role-pill.admin` azul, `.lider` verde, `.operador`
  laranja/pêssego) em vez do texto cinza uppercase simples de antes — bate com os pills
  coloridos da imagem.
- **Faixa de confiança** (Seguro/Confiável/Eficiente, `.login-trust-row`) e **rodapé**
  ("Acesso restrito..." + "© Selgron") ficaram FORA do card, abaixo dele, exatamente como
  na imagem — não são parte do formulário.
- Paleta/tipografia continuam as mesmas variáveis `--navy`/`--gray-*`/`--font-corp`
  compartilhadas com o Dashboard (ver seção acima) — só a composição/layout mudou.
- **Fundo da `.login-screen`**: era `var(--gray-100)` sólido, virou esse mesmo cinza com
  dois gradientes radiais bem sutis por cima — navy no canto superior esquerdo, laranja
  no canto inferior direito (`rgba(15,23,42,0.07)` / `rgba(246,162,0,0.09)`, ambos com
  `transparent` a ~40-42%). Mantém a mesma paleta corporativa da marca sem virar
  "gradiente exagerado" nem glassmorphism — só profundidade discreta atrás do card.

## Breakpoint do layout desktop baixou de 1024px pra 768px

O cliente testou no tablet real dele e viu a tela `home` ainda no formato mobile antigo
(grid de atalhos simples) em vez do Dashboard novo (sidebar + KPIs + donut). A causa: o
bloco de layout desktop inteiro (`Sidebar`, `DesktopTopbar`, o Dashboard novo) só entrava
a partir de `@media (min-width:1024px)` — e a largura CSS real do tablet dele (pelo
print, ~800px de largura, formato retrato) fica ABAIXO desse limiar, então caía no layout
mobile mesmo sendo um tablet de verdade, não um celular.

- Breakpoint baixado pra `768px` (um tablet 10" comum em retrato já bate isso; um celular
  em pé, mesmo grande, normalmente fica entre 360-430px — segue caindo no layout mobile
  como antes). Testado nos dois limites: 800px (o caso real do cliente) já mostra
  sidebar/Dashboard; 390px continua mostrando `BottomNav`/grid de atalhos sem alteração.
- É **um único número pra trocar** — só existe um `@media (min-width:1024px)` no arquivo
  (linha do comentário "LAYOUT DESKTOP (sidebar)"), todo o resto do CSS desktop
  (`.sidebar`, `.desktop-topbar`, `.pnl-*`, etc.) já estava aninhado dentro desse mesmo
  bloco, então baixar o número move o breakpoint inteiro de uma vez.
- Em larguras~768-900px (tablet retrato, sidebar de 264px fixos comendo proporcionalmente
  mais espaço) o cabeçalho (`DesktopTopbar`) pode quebrar título/subtítulo em 2 linhas —
  é esperado e não quebra o layout, só fica menos folgado que num monitor. O grid de KPIs
  já cai pra 3 colunas nessa faixa (regra existente `@media (max-width:1360px)`).
- Se o cliente reportar de novo que "não mudou" depois de substituir o arquivo, antes de
  mexer em breakpoint de novo, perguntar a largura real da tela (em pixels CSS, não
  polegadas) — ele não sabe de cabeça, então uma forma prática é pedir pra abrir
  `chrome://version` ou simplesmente testar visualmente com o breakpoint atual primeiro.

## Sidebar com botão de esconder/mostrar (telas menores que um monitor de mesa)

Cliente testando num tablet notou que a sidebar de 264px ocupa proporcionalmente mais
espaço numa tela menor que um monitor — pediu um botão pra esconder o menu lateral.

- Estado `sidebarCollapsed` mora em `App()` (`useState(false)`, não persiste — mesmo
  critério de `view`/`flowState`, é navegação/UI, não dado).
- Botão `.sidebar-toggle`: círculo azul (`var(--accent2)`, a mesma cor de link usada no
  resto do app), 28px, ícone `chevronLeft`/`chevronRight` (`DIcon`), renderizado como
  **irmão** de `<Sidebar>` dentro de `.app` (não como filho) — `position:absolute` grudado
  na borda direita da sidebar (`left:250px` expandido, `left:8px` colapsado, com
  `transition:left`). Fica fora da `Sidebar` de propósito: se estivesse dentro, o
  `overflow:hidden` que colapsa a sidebar escondia o botão junto, e o usuário perdia o
  jeito de reabrir o menu.
- `.sidebar{width:264px→0, overflow:hidden, transition:width}` quando `.collapsed` — as
  4 seções internas (`sidebar-brand`, `sidebar-nav`, `sidebar-shortcuts`,
  `sidebar-footer`) ganharam `width:264px;flex-shrink:0` fixo cada uma, pra não
  espremer/quebrar texto durante a transição — em vez disso elas deslizam pra fora de
  vista junto com o container pai, cortadas pelo `overflow:hidden`.
- Com a sidebar em 0px, `.app-main{flex:1}` ocupa o espaço todo automaticamente (flexbox
  já resolve isso sozinho, sem CSS extra) — é isso que dá a sensação de "mais espaço" no
  tablet.
- Só existe no bloco desktop (originalmente `@media (min-width:1024px)`, depois baixado
  pra 768px e depois virou uma faixa própria — ver seção seguinte, "Dashboard novo
  funciona em qualquer largura de tela", que já superou esses dois números) — abaixo do
  limiar mínimo a sidebar nem existe, então o botão também fica `display:none` por padrão
  (mesma lista de seletores escondidos de `.sidebar`/`.desktop-topbar`).

## Dashboard novo funciona em qualquer largura de tela (celular incluso)

O cliente reportou repetidamente que o tablet dele "ainda tá no modelo antigo" mesmo após
baixar o breakpoint pra 768px — e explicitamente pediu suporte pra "tela de iPhone 13 e
superior" (390px). Ficou claro que o aparelho de teste dele é um celular/tablet mais
estreito que 768px, e que a expectativa mudou: o Dashboard novo (sidebar + KPIs + donut)
deveria funcionar em QUALQUER tela, não só telas de tablet/monitor — o layout mobile
antigo (`TopBar`/`BottomNav`/`grid-cards`) deixou de ser o destino para telas estreitas.

**O problema técnico de simplesmente baixar o breakpoint pra ~390px**: a sidebar tem
264px fixos — nesse modelo antigo (`width:264px→0` "empurrando" o conteúdo), numa tela de
390px sobrariam só 126px pro conteúdo. Preciso virar a sidebar num **painel flutuante
(overlay)** nas telas estreitas, em vez de continuar empurrando o conteúdo.

- **Breakpoint principal do bloco desktop baixou pra 360px** (cobre qualquer celular
  moderno, iPhone 13 mini incluso a 375px) — dentro dele, uma sub-media-query
  `@media (max-width:767px)` (aninhada, mesma técnica já usada pra `.pnl-kpi-row` em
  1360px) muda o comportamento da sidebar:
  - `.sidebar` vira `position:fixed` (sai do fluxo do flexbox), com
    `transform:translateX(0)`/`translateX(-100%)` pra abrir/fechar (em vez de
    `width:264px→0` como no modo "empurra" de telas largas) — desliza por cima do
    conteúdo, não empurra.
  - `.sidebar-backdrop` (novo elemento, `<div>` escuro semi-transparente cobrindo a tela
    toda) aparece atrás da sidebar aberta — clicar nele fecha a sidebar. Só existe/aparece
    nessa faixa estreita; em telas largas fica sempre `display:none`.
  - `.sidebar-toggle` também vira `position:fixed` nessa faixa (em vez de `position:
    absolute` relativo à `.app`), grudado na borda da sidebar mesmo com ela flutuando por
    cima do resto.
  - `.desktop-topbar` ganha `height:auto` + `flex-wrap:wrap` nessa faixa — em telas
    muito estreitas o título e os controles da direita (filtro de período, sino, avatar)
    podem quebrar em duas linhas em vez de ficar cortados numa altura fixa de 72px.
  - `.pnl-kpi-row` cai pra 2 colunas (era 3 na faixa 768-1360px, 5 acima disso).
- **Estado inicial esperto**: `sidebarCollapsed` em `App()` agora começa como
  `window.innerWidth < 768` (calculado uma vez, no mount, via `useState(() => ...)`) — não
  é branching de layout contínuo (isso continua 100% CSS via media query), só a decisão
  de abrir com a sidebar visível (telas de tablet/monitor, como já era) ou escondida
  (celular, senão o painel cobriria a tela toda ao abrir o app pela primeira vez).
- **Fecha sozinha ao navegar em tela estreita**: `gotoAndCloseSidebar` (em `App()`) chama
  `goto()` normal e, se `window.innerWidth<768`, também fecha a sidebar — passada como
  prop `goto` pro componente `<Sidebar>` (só pra ele; o resto do app continua usando o
  `goto` puro). Sem isso, a sidebar ficaria aberta por cima da tela nova depois de trocar
  de página no celular. Em telas largas (empurra, não sobrepõe) não faz sentido fechar
  sozinha, então essa função não faz nada acima de 768px.
- `TopBar`/`BottomNav`/`grid-cards` (o layout mobile antigo) continuam no código e no DOM
  — só não aparecem mais em NENHUMA largura de tela normal (o CSS que os esconde entra a
  partir de 360px agora, era 768px/1024px antes). Só telas menores que 360px (praticamente
  inexistentes hoje) ainda cairiam nesse layout antigo.

## Primeiro pedaço do backend real aplicado: catálogo de produtos via Supabase

O cliente pediu pra "criar o banco de dados" e mandou uma planilha (`SB2`, 85.357 códigos
únicos de produto/descrição/grupo — bem mais que os 300 do cache estático embutido no
JS). Em vez de fazer a migração inteira de uma vez (login, usuários, inventários,
contagens — tudo isso continua 100% `localStorage`, sem mudança nenhuma), esse primeiro
passo ficou escopado só no catálogo, que é a dor imediata do cliente: item sem saldo no
cache de 300 SKUs não achava descrição/endereço nenhum durante a contagem manual.

- **Projeto Supabase real criado** (não é mais só `backend/schema.sql` sem aplicar) —
  `https://geeqfpzamexmeketcecu.supabase.co`, região São Paulo. Passei o cliente pelo
  fluxo todo no chat (criar projeto → SQL Editor pra aplicar o schema → Table Editor pra
  importar CSV) porque eu não tenho like nenhuma ferramenta que crie projeto Supabase ou
  rode SQL nele à distância — só ele tem acesso ao painel.
- **`produtos_import.csv`** (gerado a partir da planilha `SB2` do cliente, 85.357 linhas
  únicas por código, duplicatas descartadas) foi importado direto pela função "Import
  data from CSV" do Table Editor — mais simples que gerar INSERT gigante em SQL pra esse
  volume.
- **`SUPABASE_URL`/`SUPABASE_PUBLISHABLE_KEY`** ficam como constantes no topo do
  `<script>` do `index.html` (perto de `RAW_SB2_PRODUCTS`) — a "publishable key" (nome
  novo do Supabase pra o que antes chamava "anon key") é segura de expor no client-side
  por design, protegida por RLS nas tabelas sensíveis. `produtos` hoje não tem RLS
  habilitado (só leitura pública de um catálogo código→descrição, sem dado sigiloso) —
  revisar isso quando o Supabase Auth entrar de verdade.
- **`searchSupabaseCatalog(query)`** — função nova, perto da inicialização do client.
  Busca por código OU descrição (`ilike`) com join aninhado em `estoque_enderecos` →
  `enderecos` pra trazer o endereço também, se já tiver cadastrado (hoje essas duas
  tabelas estão vazias — só o catálogo foi importado — então na prática sempre volta sem
  endereço por enquanto; a função já está pronta pra quando o cadastro de endereço migrar
  pro Supabase também). Monta um produto sintético com `saldoSistema: null` — mesmo
  padrão já usado pelo fallback de item fora do cache local na importação de lista
  (`foraDoCacheLocal: true`), então `CountStep` já sabe tratar como "sem saldo pra
  comparar" sem nenhuma mudança lá.
- **Só `ManualCountFlow` (Nova Contagem avulsa) foi conectado por enquanto** — é onde o
  operador digita um código à mão e mais sentia falta disso (buscar item aleatório fora
  da lista de um inventário). A busca local (300 SKUs) continua instantânea e roda
  primeiro; a busca no Supabase (85 mil+) só dispara com debounce de 350ms **e só quando
  a busca local não achou nada** — evita gastar request à toa pro caso mais comum (item
  já no cache). `ImportedListCountFlow` não precisou de mudança — já tinha seu próprio
  fallback usando os dados que a própria planilha de importação traz.
- **Testado com resposta mockada** (`page.route` no Playwright), não contra o Supabase de
  verdade — o sandbox onde rodo os testes não tem saída de rede pra domínios externos
  (mesma restrição que bloqueou testar o link do GitHub Pages direto por `curl`). Validei
  a URL da query REST gerada (sintaxe do `select`/`or`/`limit` do PostgREST), a
  renderização do resultado, e que buscas com hit local não disparam request nenhum ao
  Supabase — mas a leitura ao vivo do banco de produção só o próprio app, rodando no
  navegador do cliente (sem essa restrição de rede), consegue confirmar de fato.

**Bug de dado encontrado e corrigido na importação — códigos numéricos perderam
formatação**: a planilha `SB2` que o cliente mandou guarda a coluna "Código do Produto"
como **número** em vez de texto no Excel, sempre que o código só tem dígitos (ex:
`2108000206`). Isso é uma perda de dado real e definitiva causada pelo próprio Excel no
momento em que o arquivo foi salvo — o valor original com zero à esquerda e pontos
(`021.080.00206`) não existe mais dentro do `.xlsx`, só o número puro sobrevive. Códigos
que já tinham letra ou mais de um ponto (ex: `000.09610.1`) não sofrem isso, porque o
Excel é obrigado a guardá-los como texto.

- O cliente confirmou as 3 formatações válidas de código: `XXX.XXXXX` (8 dígitos),
  `XXX.XXXXX.X` (9 dígitos) e `XXX.XXX.XXXXX` (11 dígitos). Cruzando com a distribuição
  real de tamanho dos códigos 100% numéricos na planilha (só apareceram tamanhos 8, 9, 10
  e 11 — nenhum caso de 7), a reconstrução ficou sem ambiguidade: tamanho 10 é sempre um
  código de 11 dígitos que perdeu exatamente o zero à esquerda (recoloca o zero e formata
  `XXX.XXX.XXXXX`); tamanhos 8, 9 e 11 já estão completos, só formata direto.
  8.680 dos 85.357 códigos (≈10%) precisaram dessa correção.
- Reimportado: `truncate table produtos cascade;` (precisa `cascade` porque
  `estoque_saldo`/`estoque_enderecos`/etc. têm FK pra `produtos`, mesmo vazias — Postgres
  não deixa truncar uma tabela referenciada sem isso) seguido de reimportar o CSV
  corrigido via Table Editor.
- Se um dia vier uma planilha nova do Protheus com o mesmo problema, o script de conserto
  (não faz parte do repo, foi rodado uma vez no scratchpad da sessão) reaplica a mesma
  regra: para código 100% numérico, se tiver 10 dígitos acrescenta um zero à esquerda,
  depois insere os pontos conforme o tamanho final (8→`XXX.XXXXX`, 9→`XXX.XXXXX.X`,
  11→`XXX.XXX.XXXXX`). Códigos que já vierem com letra/ponto na planilha não precisam de
  nenhum tratamento.
- **O mesmo bug de formatação também existia no cache local de 300 SKUs** embutido no
  `index.html` (`RAW_SB2_PRODUCTS`) — 41 dos 300 códigos estavam sem pontuação, herdado
  de uma exportação Excel anterior com o mesmo problema. Corrigido com a mesma regra,
  direto no array embutido (não é mais um arquivo externo, então o conserto foi um
  find/replace no próprio `index.html`). Isso também corrigiu um efeito colateral: esses
  códigos crus colidiam com buscas parciais (ex: buscar "021" batia em vários códigos sem
  ponto por acidente) e "escondiam" o fato de que o item de verdade só existia no catálogo
  Supabase — a busca local "encontrava" algo (errado) e nunca deixava a busca remota
  disparar. Ver `hasSaldoLocal`/`localResults.length>0` em `ManualCountFlow`.

**Bug de permissão encontrado e corrigido: RLS bloqueava a tabela `produtos` por
padrão**. Depois de importar os 85 mil produtos, a busca no app não trazia nada — nem um
teste direto na REST API (`.../rest/v1/produtos?...`) trazia resultado, mesmo os dados
existindo (confirmado via `select count(*) from produtos` no SQL Editor, que roda como
superusuário e ignora RLS). Causa: `create table produtos (...)` no painel do Supabase
**vem com RLS ativado por padrão** hoje em dia — o `schema.sql` original não previa isso
(só ativava RLS explicitamente em `estoque_saldo`/`enderecos`/`contagens`, achando que
`produtos` ficaria sem RLS = acesso liberado por padrão). Com RLS ativo e **nenhuma
policy**, a regra do Postgres é bloquear tudo, até leitura pública — silenciosamente,
sem erro visível, só resultado vazio.

- Corrigido ao vivo com `create policy "leitura pública" on produtos for select using
  (true);` (mesma coisa depois aplicada em `enderecos` e `estoque_enderecos`,
  preventivamente, antes de essas tabelas serem realmente usadas).
- `backend/schema.sql` foi atualizado pra refletir isso e documentar um problema
  relacionado, mais sutil: como o app **ainda não usa Supabase Auth** (login próprio, ver
  `App()`), toda chamada sai como `anon`, nunca `authenticated` — então qualquer policy
  escrita como `using (auth.role() = 'authenticated')` (como as 3 originais do schema)
  bloqueia o próprio app do mesmo jeito, só que ainda não apareceu porque
  `estoque_saldo`/`contagens` não são lidas do Supabase ainda. Deixado documentado no
  comentário do schema pra não repetir o mesmo susto quando essas tabelas entrarem em
  uso — usar `using (true)` pra leitura de tabela sem dado sigiloso até a migração real
  pro Supabase Auth acontecer.
- **Se criar uma tabela nova no Supabase a partir de agora**: sempre checar
  `select relrowsecurity from pg_class where relname = '<tabela>';` logo depois de criar
  — se vier `true` e a tabela precisa ser lida pelo app hoje (sem Supabase Auth), criar a
  policy de leitura pública na hora, não depois.

## Segundo pedaço do backend real: contagens gravam no Supabase (só isso, por enquanto)

Depois do catálogo, o cliente pediu **"começar a trabalhar em salvar os dados lançados no
app"**, especificamente as contagens ("precisamos trabalhar para começar a salvar as
contagens feitas"). Perguntei o escopo (via `AskUserQuestion`, que falhou e caiu pra texto
puro) entre duas opções — migração completa (Supabase Auth + inventários reais + FK de
verdade) vs. uma versão leve só das contagens, sem mexer em login/inventários — e o cliente
escolheu a opção leve ("1").

- **Login, usuários e inventários continuam 100% locais** (`localStorage`, ver seção
  "Persistência local" acima) — nada mudou aí. Só a contagem individual (o que já vira um
  objeto `count` dentro de `CountStep.finalize()`) passou a ser gravada TAMBÉM no Supabase,
  além de continuar indo pro `localStorage` como sempre (`localStorage` continua sendo a
  fonte de verdade do app hoje — o Supabase aqui é só um espelho/histórico, o app não lê de
  lá ainda).
- **`contagens` no Supabase é denormalizada de propósito**: sem FK pra `usuarios` nem pra
  `inventarios` (essas tabelas não têm dado real nenhuma, já que login/inventário são só
  locais) — `usuario` grava o nome em texto puro (`user.nome`), `inventario_id` grava o id
  local do inventário (`inv.id`, tipo `"INV-XXXXXX"`, ou `"—"` pra contagem avulsa sem
  inventário). `produto_codigo` também não tem FK pra `produtos` — contagem de item fora do
  catálogo/cache local (`fora_do_cache_local`) precisa gravar do mesmo jeito, travar com FK
  quebraria exatamente esse caso. `backend/schema.sql` foi reescrito (a versão antiga da
  tabela, com UUID + FKs pra `usuarios`/`inventarios`/`produtos`, nunca tinha sido usada de
  verdade — só existia como CREATE TABLE vazio desde a aplicação inicial do schema).
- **`foto_url text` virou `tem_foto boolean`**: conferido no código (`CountStep`, variável
  `photo`) que a "foto" hoje é só um `blob:` local via `URL.createObjectURL` — nunca é
  enviada pra lugar nenhum, não existe upload real. Guardar uma "URL" que não existe seria
  fingir um dado que não tem. Se um dia entrar upload de verdade (Supabase Storage), aí sim
  a coluna vira `foto_url` de novo.
- **`classificacao`** grava só o `label` (texto) do objeto `classification` que o app já
  calcula (`classifyDivergence`), não o objeto inteiro — a coluna é `text`, não `jsonb`.
- **`saveContagemToSupabase(count)`** (perto de `searchSupabaseCatalog`, no `index.html`) —
  função `async`, chamada uma única vez dentro de `CountStep.finalize()` (o motor de
  contagem compartilhado por TODOS os fluxos: aleatória, manual, rota, lista importada e
  recontagem — um único ponto de gravação cobre todos eles, não precisou duplicar em cada
  `Flow`). **"Fire and forget"**: não usa `await` no ponto de chamada, não bloqueia
  `onComplete(count)` nem a navegação, e qualquer erro (offline, RLS, o que for) só vira um
  `console.warn` — o app continua funcionando 100% normal via `localStorage` mesmo se a
  gravação no Supabase falhar. Isso é proposital: a persistência local continua sendo a
  única coisa de que o fluxo de contagem depende para funcionar.
- **RLS**: `contagens` recebeu policy de INSERT liberada pra `anon`
  (`create policy "inserção pública" on contagens for insert with check (true);`) — mesma
  razão já documentada acima pra `produtos`/`enderecos`: sem Supabase Auth, toda chamada sai
  como `anon`, então `auth.role()='authenticated'` (a policy original do schema) bloquearia
  a própria gravação. Aceitável pro protótipo (qualquer um com a publishable key pode
  inserir), não pra produção — revisar junto com a migração pro Supabase Auth.
- **Testado via Playwright com o insert do Supabase mockado** (`page.route`, sandbox sem
  saída de rede — mesma limitação/técnica já usada pro catálogo): completei uma contagem
  manual ponta a ponta (endereço manual → quantidade → foto/observação → motivo de
  divergência, perfil admin) e confirmei que o payload de `POST .../rest/v1/contagens`
  bate exatamente com as colunas da tabela nova, incluindo `fora_do_cache_local: false`,
  `classificacao: "Divergência moderada"` (string, não objeto) e `tem_foto: false`. Não
  testei contra o Supabase de verdade (mesma restrição de rede do sandbox) — falta o
  usuário aplicar o `backend/schema.sql` atualizado (recriar a tabela `contagens`) no
  projeto real e confirmar ao vivo, mesmo padrão de handoff já usado pro catálogo.
- **Se pedir pra migrar mais alguma coisa pro Supabase** (endereços, inventários, usuários):
  o padrão agora é: perguntar se é versão leve (denormalizada, sem FK, sem Auth) ou
  migração completa antes de desenhar o schema — a resposta muda a modelagem inteira, como
  ficou claro aqui.

## Terceiro pedaço do backend real: inventários e contagens sincronizam entre aparelhos

O cliente testou o passo anterior (contagens gravando no Supabase) de dois aparelhos
diferentes e viu que o Dashboard do computador não mostrava a contagem feita pelo celular
— esperado, já que só a GRAVAÇÃO existia (write-only), ninguém lia do Supabase ainda.
Perguntei o escopo (via `AskUserQuestion`) em duas rodadas: primeiro se quer só
sincronizar o histórico de contagens ou também os inventários (progresso compartilhado
entre tablets contando o mesmo inventário) — escolheu inventários também. Depois, ao
saber que resetar senha de OUTRO usuário via Supabase Auth exigiria a service role key
(não pode ficar no navegador — abriria uma falha grave) e uma Edge Function extra pra
publicar via CLI, decidiu **adiar a migração do login** e focar só em inventários e
contagens. Ou seja: **login/usuários continuam 100% locais** (`localStorage`,
`attemptLogin` em `index.html`) — nada mudou lá, só a camada de dados de
inventários/contagens passou a ser compartilhada.

- **`inventarios` no Supabase, denormalizada** (mesmo espírito de `contagens`): sem FK pra
  `usuarios` (`responsavel` é texto puro) — `backend/schema.sql` foi reescrito, a versão
  anterior (com `inventario_itens` congelando saldo por item) nunca tinha sido usada e não
  batia com a realidade: o app não guarda lista de itens por inventário, exceto quando
  `tipo==='Lista Importada (Excel)'` — nesse caso a lista vai como `itens_importados jsonb`
  na própria linha, mais simples que uma tabela filha pra um dado que só é lido, nunca
  consultado item a item. Pros outros tipos (Aleatória/Curva ABC/Manual/Rota), a lista de
  itens é recalculada a partir do catálogo a cada vez que o fluxo de contagem monta (ver
  `RandomCountFlow`) — só o contador `contados` (quantos itens já foram contados, usado como
  offset pra saber por onde retomar) precisa persistir e sincronizar.
- **`increment_contados(p_id)`**: função SQL que faz `update inventarios set contados =
  contados + 1` dentro do banco, em vez do client ler o valor, somar e gravar de volta — evita
  perder um incremento se dois aparelhos completarem uma contagem do mesmo inventário quase
  ao mesmo tempo (a versão "lê e soma no navegador" teria essa corrida; a função no banco
  não).
- **Funções novas no `index.html`** (perto de `saveContagemToSupabase`):
  `saveInventarioToSupabase(inv)` (insert fire-and-forget, chamado no `onCreate` de
  `NewInventory`), `incrementContadosSupabase(invId)` (chama a RPC acima, fire-and-forget,
  chamado nos 3 lugares que já incrementavam `contados` localmente —
  `RandomCountFlow`/`RouteCountFlow`/`ImportedListCountFlow`), `fetchInventoriesFromSupabase()`
  e `fetchContagensFromSupabase()` (leitura, mapeando snake_case→camelCase de volta pro
  formato que o app já usa — `contagemRowToLocal` reconstrói `classificacao` como
  `{label, level:undefined, rule:''}` já que o banco só guarda o label em texto).
- **Sincronização por polling, não realtime**: um `useEffect` em `App()` (logo depois do
  efeito de logout por inatividade) roda `sync()` assim que loga e depois a cada 30s
  (`setInterval`), enquanto a sessão está ativa. Escolhido em vez de Supabase Realtime
  (WebSocket) pra não introduzir uma peça de infraestrutura nova — o app não tem nenhum
  canal realtime hoje, e polling a cada 30s é suficiente pro ritmo de uma contagem manual
  (não precisa aparecer em menos de 1 segundo). Pode virar realtime depois se o cliente
  achar o atraso perceptível.
- **Merge nunca perde dado local**: `counts` só recebe registros com `id` que ainda não
  existem localmente (aditivo puro — nunca sobrescreve). `inventories` só aceita o registro
  remoto quando `contados` remoto ≥ local (evita "voltar" o progresso se o poll chegar
  antes do próprio incremento do aparelho ainda não ter sido gravado no Supabase — testado
  via Playwright simulando essa corrida, contados local não regride). Se a rede cair, o
  `sync()` simplesmente não traz nada nesse ciclo e o app segue 100% funcional com o que já
  tinha — mesma tolerância a falha já usada em `saveContagemToSupabase`.
- **Limitação conhecida, documentada e não resolvida agora**: o "próximo item" de um
  inventário Aleatório/Curva ABC/Rota é `allItems[contados]` — um índice, não uma reserva
  por item. Se dois aparelhos contarem o MESMO inventário ao mesmo tempo de verdade (não só
  um olhando o progresso do outro depois de pronto), os dois podem pegar o item de mesmo
  índice antes do incremento propagar pelo polling de 30s, gerando uma contagem duplicada
  do mesmo item. Resolver isso de verdade (reservar item por aparelho) é escopo maior, fica
  como limitação conhecida — mesmo padrão de transparência já usado em outras partes do
  projeto.
- **Testado via Playwright com `inventarios`/`contagens` mockados simulando dois
  "aparelhos"** (sandbox sem saída de rede, mesma técnica de sempre): confirmei que um
  inventário e uma contagem criados só no mock (simulando outro tablet) aparecem no
  `localStorage` do aparelho de teste depois do sync inicial, sem apagar os dados locais
  que já existiam; e que um `contados` remoto desatualizado (menor que o local) NÃO
  sobrescreve o progresso local mais avançado. Não testei contra o Supabase de verdade —
  falta o usuário rodar o SQL atualizado (recriar `inventarios`, criar
  `increment_contados`) no projeto real e testar em dois aparelhos de verdade.
- **Login continua igual**: nenhuma mudança em `LoginScreen`, `Settings`,
  `UserManagementPanel`, ou nas funções de auth em `App()` (`attemptLogin`,
  `requestPasswordReset`, `applyAdminPasswordAction`, etc.) — senha em texto puro,
  aprovação de reset pelo admin, tudo como estava. Se o cliente pedir pra migrar login
  pro Supabase Auth no futuro, isso é um projeto à parte — precisa decidir antes como fica
  o reset de senha de outro usuário sem expor a service role key no navegador (opções já
  discutidas com o cliente: e-mail real do Supabase Auth, ou uma Edge Function publicada
  via CLI mantendo o admin no controle).

## Descrição dos grupos de produto (antes só mostrava o código numérico cru)

O cliente mandou a planilha original (`SB2`) só com o código numérico do grupo
(`grupo`, ex: `61`), então o app sempre mostrou "Grupo 61" cru no campo "Família" —
tanto pro cache local de 300 itens quanto pro resultado da busca no catálogo real do
Supabase (`searchSupabaseCatalog`). Depois ele conseguiu uma segunda planilha
(`Grupo_de_Produtos.xlsx`, código → descrição, 248 grupos, sem duplicado nem lacuna)
e pediu pra incluir.

- **`GRUPO_DESCRICOES`** (perto de `USERS_SEED`/`RAW_SB2_PRODUCTS` no `index.html`) —
  objeto estático `{"1":"ACRILICOS", "2":"ADESIVOS", ...}` com os 248 grupos embutido
  direto no JS, mesmo raciocínio já usado pro cache de 300 produtos: essa taxonomia
  muda raramente, não precisa de tabela nova no Supabase nem de round-trip de rede pra
  resolver um dado que é essencialmente fixo. **Decisão consciente de não criar uma
  tabela `grupos` no Supabase** — menos infraestrutura pra manter, e o cache local de
  300 itens já é embutido do mesmo jeito (ficaria inconsistente ter só a parte da
  descrição do grupo puxando de rede enquanto o produto em si é estático).
- **`describeGrupo(grupo)`** — helper logo depois do objeto, faz o lookup e cai de
  volta pro rótulo antigo `'Grupo ' + grupo` se algum código não estiver no mapa
  (protege contra grupo novo que apareça no catálogo antes de o cliente atualizar essa
  lista).
- Usado nos dois lugares que antes montavam o rótulo cru: `PRODUCTS` (mapeamento do
  cache local de 300 itens) e `searchSupabaseCatalog` (resultado da busca no catálogo
  de 85 mil produtos do Supabase) — os dois agora chamam `describeGrupo(...)` em vez de
  concatenar `'Grupo ' + código` na mão.
- **Se o cliente mandar uma atualização dessa planilha no futuro** (grupo novo, nome
  corrigido): o padrão é regenerar o objeto `GRUPO_DESCRICOES` inteiro a partir da
  planilha nova e substituir no `index.html` — mesmo tratamento que já é dado a
  atualizações do `RAW_SB2_PRODUCTS`.
- Testado via Playwright (sandbox sem rede, produtos/inventários/contagens mockados
  vazios): busquei um item do cache local com `grupo:61` e confirmei que o campo
  "Família" mostra "MAT EXPEDIENTE (NÃO ENTRA MRP)" em vez de "Grupo 61".

## Recontagem: "Solicitar nova contagem" vs. "Recontar" (bug + mudança de fluxo)

O cliente reportou dois problemas ligados ao painel "Aguardando Análise do Líder"
(`RecountsPanel`): (1) clicar em "Solicitar nova contagem" levava direto pra tela de
recontagem com o PRÓPRIO usuário logado (líder/admin) — não fazia sentido, porque
"solicitar" deveria só encaminhar o item pra fila, não fazer o líder contar na hora;
(2) ao clicar, a tela quebrava com "Item ... não encontrado na base de produtos" pra
um item que tinha sido contado via busca no catálogo Supabase (fora do cache local de
300 SKUs).

- **Bug real corrigido em `RecountFlow`**: `PRODUCTS.find(p=>p.codigo===...)` só
  procura no cache local de 300 itens — qualquer contagem original vinda da busca no
  catálogo Supabase (`ManualCountFlow`) ou de lista importada tinha o código ausente
  dali, e a recontagem quebrava. Corrigido com o mesmo padrão de fallback já usado no
  `ImportedListCountFlow`: se não achar no `PRODUCTS`, monta um produto sintético a
  partir do que a própria contagem anterior (`original`) já registrou (descrição,
  endereço, saldo do sistema) — `foraDoCacheLocal:true`, sem precisar de nova consulta
  ao Supabase, já que os dados relevantes já estavam salvos na contagem.
- **Dois botões agora, dois comportamentos diferentes** (só no bloco `canApprove` de
  "Aguardando Análise do Líder"):
  - **"Solicitar nova contagem"** → `requestRecountFromOperator(countId)` (novo, em
    `App()`), só muda `statusAprovacao` do item pra `'aguardando_segunda'` — não
    navega pra lugar nenhum. Isso move o item pra fila "Aguardando Segunda Contagem"
    (mesma seção que já existia, sempre visível pra qualquer perfil incluindo
    operador — ver `RecountsPanel`), de onde QUALQUER operador pode pegar depois.
  - **"Recontar"** (novo botão, ícone 🔁) → mesmo comportamento que "Solicitar nova
    contagem" tinha antes: `goto('recount', c)`, abre `RecountFlow` com o usuário
    atualmente logado fazendo a recontagem ali mesmo, na hora.
- **Segundo bug encontrado durante o teste, também corrigido**: a seção "Aguardando
  Segunda Contagem" nunca tinha sido alcançável por um item sem saldo local
  (`percentual: null`) antes dessa mudança — só chegava lá via `computeStatus` na 1ª
  contagem com divergência leve (`level==='warn'`), que sempre tem saldo. Como agora o
  líder pode empurrar QUALQUER item (inclusive sem saldo) pra essa fila via "Solicitar
  nova contagem", a linha `c.percentual.toFixed(1)` (sem checar null) quebrava a tela
  com `Cannot read properties of null (reading 'toFixed')`. Corrigido com o mesmo
  guard já usado na seção "Aguardando Análise do Líder"
  (`c.diferenca==null ? '— (sem saldo local)' : ...`).
- Testado via Playwright ponta a ponta (sandbox sem rede, catálogo Supabase mockado):
  contei um item fora do cache local até virar divergência sem saldo (mesmo cenário do
  print do cliente), confirmei que "Recontar" abre `RecountFlow` normalmente (sem o
  erro de "não encontrado") e que "Solicitar nova contagem" move o item pra
  "Aguardando Segunda Contagem" sem navegar e sem quebrar a tela.

## Bloqueio de contagem duplicada + diferenciar card de recontagem rejeitada

Dois pedidos do cliente na sequência do ajuste anterior: (1) "não permitir lançar
contagem de item que já está com documento de contagem aberto" — o mesmo código de
produto podia ser contado de novo em outro lugar do app (ex: "Nova Contagem" avulsa)
enquanto já tinha uma contagem aguardando análise do líder ou aguardando recontagem em
algum inventário, gerando dois documentos conflitantes pro mesmo item; (2) diferenciar
visualmente, na fila "Aguardando Segunda Contagem", o card de um item que foi pra lá
porque o **líder rejeitou a divergência** (via "Solicitar nova contagem") do card de um
item que caiu lá sozinho pela regra automática da 1ª contagem (divergência leve).

- **`getOpenCountForProduct(counts, productCode)`** (perto de `STATUS_INFO`) — acha o
  registro de contagem mais recente (a PONTA da corrente de recontagem, sem uma rodada
  seguinte ainda) pra um código, se o `statusAprovacao` dele estiver em
  `OPEN_STATUSES` (`aguardando_segunda` ou `aguardando_analise_lider`). Mesma lógica de
  "ponta da corrente" que o `RecountsPanel` já usava (`byOriginal`), só que extraída
  como função reutilizável.
- **Bloqueio central em `CountStep`**: recebe `counts` como prop agora (threaded a
  partir de `App()` por `RandomCountFlow`/`ManualCountFlow`/`RouteCountFlow`/
  `ImportedListCountFlow` — só `RecountFlow` não precisa, ver abaixo). Logo no topo do
  componente, se `numeroContagem===1` (ou seja, é uma contagem NOVA, não uma
  recontagem) e `getOpenCountForProduct` encontra um documento aberto pro código, o
  componente retorna uma tela de bloqueio (🔒 "já tem uma contagem em aberto", com
  quem contou, quando e o status atual) em vez da UI normal de contagem — nenhum campo
  de quantidade aparece, não dá pra prosseguir. Como TODOS os fluxos de contagem
  passam por `CountStep`, um único ponto de checagem cobre todos eles (mesmo padrão já
  usado pra `saveContagemToSupabase`). `RecountFlow` passa `numeroContagem =
  original.numeroContagem+1` (sempre ≥2), então nunca é bloqueado — é exatamente o
  fluxo que resolve o documento aberto, não pode travar nele mesmo.
- **Escopo consciente**: o bloqueio acontece quando o item é SELECIONADO pra contar
  (ex: ao clicar num resultado de busca ou entrar no `CountStep` dentro de uma fila de
  inventário) — não filtra o item de antemão das listas geradas automaticamente
  (`RandomCountFlow`/`RouteCountFlow`/`ImportedListCountFlow` continuam incluindo o
  item na fila/rota; ele só fica bloqueado quando chega a vez dele). Suficiente pro
  pedido original (impedir o LANÇAMENTO duplicado), mas se o cliente notar que um item
  bloqueado ainda aparece "na vez" dentro de um inventário e achar confuso, o próximo
  passo seria filtrar esses itens da lista antes de montar a fila.
- **Card diferenciado em "Aguardando Segunda Contagem"**: `requestRecountFromOperator`
  (em `App()`) agora também grava `recontagemSolicitadaPeloLider:true`,
  `recontagemSolicitadaPor` (nome de quem clicou) e `recontagemSolicitadaEm` (data/hora)
  na contagem, além de mudar o `statusAprovacao`. `RecountsPanel` usa esses campos pra
  trocar a `StatusTag` do card de "warn"/label da classificação pra "danger"/"Divergência
  rejeitada", acrescentar uma faixa de aviso (`divergence-alert`) explicando quem
  rejeitou e quando, e uma borda esquerda vermelha (`var(--danger)`) no card inteiro —
  itens que caíram ali sozinhos pela regra automática (sem essa flag) continuam com a
  aparência de antes (tag "warn" com o label da classificação, sem borda/aviso extra).
- Testado via Playwright (sandbox sem rede): contei um item até virar divergência,
  tentei contar o MESMO código de novo via "Nova Contagem" avulsa e confirmei a tela de
  bloqueio (sem campo de quantidade); depois, a partir do mesmo item em "Aguardando
  Análise do Líder", cliquei "Solicitar nova contagem" e confirmei que o card em
  "Aguardando Segunda Contagem" mostra a tag "Divergência rejeitada", o aviso com nome
  de quem solicitou, e a borda vermelha (`rgb(196, 41, 27)`, confere com `--danger`).

## "Minhas Contagens" não reabre contagem concluída + relatório filtrável por dia

Dois pedidos do cliente: (1) tirar o botão "Recontar este item" de "Minhas Contagens"
(`MyCounts`) — ele aparecia pra qualquer contagem com `statusAprovacao==='aguardando_segunda'`,
mas o cliente notou que uma contagem já concluída não devia poder ser reaberta por ali;
(2) um campo de calendário na tela de Relatórios pra tirar um relatório só das contagens
de um dia específico, pra análise.

- **`MyCounts`**: removido o bloco condicional que renderizava "Recontar este item"
  (e a variável `byOriginal`/`jaRecontado` que só existia pra calcular isso). O botão
  continua existindo — e é o lugar certo pra essa ação — em `RecountsPanel` (seção
  "Aguardando Segunda Contagem"), que é a tela dedicada a gerenciar recontagem
  pendente. "Minhas Contagens" agora é histórico puro, só leitura, sem ação de reabrir
  nada.
- **Filtro de data em `ReportsScreen`**: campo `<input type="date">` (estado
  `filtroData`, formato `YYYY-MM-DD` — já bate direto com o campo `data` de cada
  `count`, sem precisar converter) no painel "Baixar Relatório". Vazio = sem filtro,
  comportamento de antes (relatório com todas as contagens). Preenchido, `downloadWorkbook`
  passa `countsFiltrados` (em vez de `counts`) pra `generateReportWorkbook` — afeta as 4
  abas do Excel (Resumo, Contagens, Contar, Solicitação de Ajuste), já que todas recebem
  o array de contagens como parâmetro em vez de ler estado global. `buildSummaryRows`
  não precisou mudar — a única linha que usa `inventories` (contagem de "Inventários
  ativos") continua com a lista cheia de propósito, não faz sentido filtrar isso por dia.
  Nome do arquivo baixado passa a usar a data filtrada em vez de "hoje"
  (`Inventario360_Relatorio_2026-07-14.xlsx`) quando há filtro.
  Envio por e-mail (`handleSendEmail`) usa a mesma `downloadWorkbook`, então também
  respeita o filtro automaticamente — não precisou de mudança separada ali.
- Testado via Playwright (sandbox sem rede, `counts` semeado direto no `localStorage`
  antes de carregar a página pra simular duas contagens em dias diferentes): confirmei
  que "Minhas Contagens" não mostra mais "Recontar este item" em nenhum card (inclusive
  o que estava com `aguardando_segunda`), que o mesmo botão continua funcionando
  normalmente em "Recontagens", que selecionar uma data no relatório atualiza o resumo
  ("1 contagens em 2026-07-14") e que um dia sem nenhuma contagem desabilita o botão de
  baixar com a mensagem "Nenhuma contagem registrada nesse dia."

## Cards de valor em estoque (por armazém + total) em "Indicadores"

O cliente pediu, junto com o aviso de que vai mandar a planilha SB2 pra atualizar os
saldos: "nesses cards somar tudo que temos em estoque, separar um card por valor por
armazém e card de total em estoque" — referindo-se à tela `Dashboard` (renomeada pra
"Indicadores", ver seção acima).

- Nova seção **"Estoque"** entre "Operação" e "Qualidade": um card por `almoxarifado`
  presente em `PRODUCTS` (soma de `valorFinanceiro` dos itens daquele armazém) +
  um card fixo "Valor Total em Estoque" (soma de todos os armazéns). Os cards por
  armazém são gerados dinamicamente (`Object.keys(porArmazem).sort()`), não hardcoded
  — se amanhã existir mais de um armazém no cache, aparece um card por armazém
  automaticamente, sem precisar mexer no código de novo.
- **Fonte do dado, hoje**: `PRODUCTS` (que vem do cache local de 300 SKUs,
  `RAW_SB2_PRODUCTS`) — por isso hoje só aparece "Almox 01" (único armazém que existe
  nesse cache) e o valor total bate com a soma de só 300 itens (~R$ 5,3 milhões), não
  o estoque real da empresa inteira. Isso é esperado e será resolvido quando o cliente
  mandar a planilha SB2 atualizada — a intenção dele é justamente atualizar os saldos
  antes de confiar nesse número. Quando isso migrar pra fonte real (provavelmente a
  tabela `estoque_saldo` do Supabase, hoje desenhada no `backend/schema.sql` mas nunca
  populada — mesma pendência documentada na seção "Backend desenhado, ainda não
  aplicado"), a conta em si (agrupar por armazém + somar total) não muda, só troca de
  onde os dados vêm.
- `fmtReais(v)` — helper local no `Dashboard`, formata com separador de milhar
  (`toLocaleString('pt-BR')`) por causa da escala dos valores (esses cards somam
  milhões, diferente do "Valor Divergente" já existente ali do lado, que soma só
  divergências pontuais e por isso nunca precisou de separador).
- Testado via Playwright (sandbox sem rede, cache local de 300 itens): confirmei que
  aparece 1 card "Valor em Estoque — Almox 01" e 1 card "Valor Total em Estoque",
  ambos mostrando "R$ 5.296.875" (batem entre si porque só existe 1 armazém no cache
  hoje), sem erros de console.

## Saldo real em estoque: upload manual e diário da planilha SB2

O cliente mandou a planilha SB2 de saldo de verdade (12.577 linhas, 8 armazéns) e
avisou algo importante: **"enquanto não puxamos do banco de dados preciso carregar
essa planilha diariamente"** — ou seja, isso não é um import único (como foi o
catálogo de 85 mil produtos): precisa ser um botão que o próprio cliente usa
repetidamente, sem depender de mim rodando SQL a cada vez.

- **`StockSyncPanel`** (componente novo, renderizado dentro de `Settings`, só pra
  `isAdmin`) — botão de upload (.xlsx), mostra um resumo depois de ler o arquivo
  (linhas totais, válidas, quantos armazéns) e só grava no Supabase depois de
  "Confirmar atualização" (nunca automático ao selecionar o arquivo, dá chance de
  cancelar se for o arquivo errado). Mesmo padrão visual/fluxo já usado no upload da
  "Lista Importada (Excel)" (`NewInventory`/`parseImportedListRows`), mas escrevendo
  direto no Supabase em vez de virar um inventário local.
- **`parseSB2Rows(rawRows)`** (perto de `saveInventarioToSupabase`) — lê as colunas do
  export padrão SB2 do Protheus (`Produto`, `Almoxarifado`, `DT.Ult.Saida`,
  `Saldo Atual`, `Sld.Atu.` — essa última é o valor financeiro do saldo, não precisa
  calcular saldo×custo na mão). `reconstructNumericCode` reaplica a MESMA regra já
  usada pro catálogo de 85 mil produtos e pro cache local de 300 SKUs (código 100%
  numérico no Excel perde zero à esquerda/pontos — reconstrói por tamanho: 8→
  `XXX.XXXXX`, 9→`XXX.XXXXX.X`, 10→repõe zero e vira 11, 11→`XXX.XXX.XXXXX`). Datas
  vêm via `cellDates:true` no `XLSX.read` (sem isso viriam como número serial do
  Excel); linhas com "DT.Ult.Saida" vazia (texto placeholder tipo "  /  /    ", não
  uma data de verdade — 845 das 12.577 linhas reais do cliente) viram `null`.
- **`replaceEstoqueSaldoInSupabase(linhas, onProgress)`** — **REPLACE completo, não
  upsert**: apaga toda a tabela `estoque_saldo` primeiro, depois insere a planilha
  nova em lotes de 500 (12.577 linhas → 26 requisições). Decisão deliberada: a
  planilha é sempre um retrato do saldo "agora" vindo do Protheus — um upsert por
  chave incremental deixaria lixo (item que saiu do armazém ou zerou continuaria
  aparecendo com o valor antigo). `onProgress(inseridas, total)` alimenta o texto
  "X de Y linhas enviadas…" no painel durante o upload.
- **`backend/schema.sql` — `estoque_saldo` perdeu a FK pra `produtos(codigo)`**: a
  SB2 de saldo é um export separado do catálogo, testado e confirmado que os dois não
  precisam bater 100% em formatação — travar o upload inteiro por causa de um código
  desalinhado seria pior que aceitar sem FK (mesma razão já documentada pra
  `contagens`/`inventarios`). RLS trocou de "só service role" (pensada pra uma Edge
  Function que nunca foi aplicada) pra `using(true)` — mesmo trade-off já aceito nas
  outras tabelas de escrita client-side sem Supabase Auth.
- **`estoque_valor_por_almoxarifado()`** — função SQL nova (`sum`/`group by` direto no
  Postgres) que soma valor e saldo por armazém sem precisar trazer 12 mil+ linhas pro
  navegador. `fetchEstoqueValorPorAlmoxarifado()` no `index.html` chama essa RPC.
- **`Dashboard` agora busca o saldo real primeiro**: `useEffect` no mount chama
  `fetchEstoqueValorPorAlmoxarifado()`; se vier vazio (tabela ainda não populada) ou a
  rede falhar, cai de volta pro cálculo a partir do `PRODUCTS` local (cache de 300
  itens) — mesmo espírito de fallback já usado em outros pontos. Um aviso pequeno
  ("cache local de demonstração — atualize a planilha SB2 em Configurações") aparece
  ao lado do título "Estoque" só quando está no fallback, some sozinho assim que
  existir saldo real gravado.
- Testado via Playwright ponta a ponta com a planilha SB2 real de 12.577 linhas que o
  cliente enviou (sandbox sem rede, `DELETE`/`POST .../rest/v1/estoque_saldo`
  mockados): confirmei o resumo pós-parse ("12577 linhas · 12577 válidas · 8
  armazéns"), 1 chamada de DELETE, 26 lotes de INSERT totalizando as 12.577 linhas, e
  o formato exato de uma linha gravada (`produto_codigo`, `almoxarifado` como texto,
  `saldo`, `valor_financeiro`, `data_ultima_saida`). Testei também os dois caminhos do
  Dashboard: com a RPC mockada retornando dado real (sem aviso de fallback, valores
  batendo) e retornando vazio (aviso de fallback aparece, valores do cache local de
  sempre). Não testei contra o Supabase de verdade — falta o cliente rodar o SQL
  atualizado (`estoque_saldo` sem FK, policy nova, função `estoque_valor_por_
  almoxarifado`) no projeto real e fazer o primeiro upload de verdade pelo painel.

## Data/hora da última atualização do saldo (facilita saber se está desatualizado)

Pedido rápido do cliente logo depois do upload da SB2: um campo mostrando quando foi a
última atualização, pra facilitar saber se o saldo em tela está em dia (já que a
atualização é manual/diária, não automática).

- **`fetchUltimaAtualizacaoEstoque()`** (perto de `fetchEstoqueValorPorAlmoxarifado`) —
  não precisou de coluna nova nem de função SQL: `estoque_saldo.sincronizado_em` já é
  preenchido automaticamente (`default now()`) em cada linha inserida por
  `replaceEstoqueSaldoInSupabase`. A função só busca a linha com o `sincronizado_em`
  mais recente (`order by ... desc limit 1`) — como todas as linhas de um mesmo upload
  são inseridas dentro do mesmo replace, esse valor é essencialmente "hora do último
  upload confirmado".
- Aparece em dois lugares: **`StockSyncPanel`** (Configurações) — logo acima do botão
  de upload, atualiza sozinho depois de um upload bem-sucedido (sem precisar recarregar
  a página); e **`Dashboard`** (seção "Estoque") — ao lado do título, só quando já
  existe saldo real (`usandoSaldoReal`), no formato "(atualizado em 14/07/2026,
  18:30:00)". Quando ainda está no cache local de demonstração, continua mostrando o
  aviso de fallback no lugar (os dois avisos são mutuamente exclusivos, nunca aparecem
  juntos).
- Testado via Playwright (sandbox sem rede, `estoque_saldo`/RPC mockados): confirmei
  que os dois lugares mostram a data/hora formatada em pt-BR a partir do mesmo dado
  mockado, sem erros de console.

## Bug real no upload da SB2: valor sempre zerado + reformulação dos cards de estoque

Depois do primeiro upload de verdade (planilha SB2 real do cliente, 12.577 linhas, 8
armazéns), os cards mostraram **R$ 0 em todos os armazéns** — só os nomes dos armazéns
(1, 11, 3, 4, 5, 6, 99, EX) vieram certos, o valor não. Cliente também achou os 9 cards
grandes (8 armazéns + total) muito "poluído" visualmente e pediu pra rotular como
"Armazém 01" em vez do código cru "1".

- **Causa raiz do valor zerado**: a coluna "Sld.Atu." (valor financeiro) na planilha
  real do cliente tem **formato contábil do Excel** (moeda, `numFmtId 44`) aplicado na
  célula do CABEÇALHO — e esse número format tem uma seção de texto (`_-@_-`) que
  adiciona espaço de preenchimento nas pontas quando o conteúdo da célula é texto (não
  número). O SheetJS respeita isso ao montar as chaves do `sheet_to_json`: a chave real
  virou `" Sld.Atu. "` (com espaço) em vez de `"Sld.Atu."` — meu código lia
  `row['Sld.Atu.']` (sem espaço), sempre batia `undefined`, e o fallback
  `Number.isNaN(...) ? 0 : ...` silenciosamente virava `0` sem nenhum aviso. Confirmado
  reproduzindo com o SheetJS vendorizado direto em Node contra o arquivo real do
  cliente (`XLSX.read` + `sheet_to_json` + inspecionar `Object.keys(rows[0])`) — foi
  assim que apareceu a chave com espaço.
- **Correção em `parseSB2Rows`**: em vez de acessar colunas pelo nome cru, agora
  normaliza TODAS as chaves da linha (`Object.keys(row).forEach(k=>{ norm[k.trim()] =
  row[k]; })`) antes de qualquer leitura — resolve o problema pra "Sld.Atu." e protege
  contra o mesmo formato pintar outra coluna numa exportação futura (ex: "C Unitario",
  que tinha o mesmo padding no arquivo real, mesmo sem ser usada hoje).
- **Cards redesenhados** (pedido do cliente: "diminuir... ficou muito poluído, ou outra
  sugestão"): trocado 1 card grande por armazém (9 cards ao todo) por **1 card grande
  só pro total** + uma lista compacta em barras (`bar-row`/`bar-track`/`bar-fill`,
  mesmo componente visual já usado em "Produtividade por Operador" nesta mesma tela) —
  bem mais compacto e escala melhor conforme mais armazéns aparecerem. Como o valor de
  cada armazém varia MUITO (ex: Armazém 01 tinha R$13,8 milhões contra R$1.356 do
  Armazém 11 no teste real), o valor formatado (`fmtReais`) foi colocado **fora** da
  barra colorida (coluna de texto à direita, largura fixa) em vez de dentro dela — a
  primeira versão colocava o texto dentro da barra (`<span>` no `.bar-fill`, mesmo
  padrão do "Produtividade por Operador") e cortava/sobrepunha o texto em barras muito
  finas, confirmado visualmente via screenshot do Playwright antes de trocar.
- **`formatArmazemLabel(codigo)`** (perto de `parseSB2Rows`) — "1"→"Armazém 01"
  (2 dígitos, mesmo padrão de nomenclatura já usado no cache local "Almox 01"), mantém
  como veio se não for só dígito (ex: "EX", código real visto na planilha do cliente).
- Testado via Playwright ponta a ponta com a planilha real do cliente de novo: soma de
  `valor_financeiro` das 12.577 linhas gravadas confere (~R$ 16,9 milhões, não mais
  zero), rótulos "Armazém 01"/"Armazém EX"/etc. corretos, e conferi visualmente via
  screenshot que os valores de todos os armazéns — incluindo os bem menores que
  Armazém 01 — ficam legíveis fora da barra.

## Cards de estoque no modelo de referência (SaaS B2B, sem inventar métrica)

Cliente mandou uma imagem de referência (dashboard estilo SAP/Fiori) e pediu pra deixar
os cards de estoque "neste modelo" — card grande de total + badges coloridos por
armazém + mini-cards de resumo + toggle Valor/%. A imagem também tinha uma tendência
("+8,6% vs. mês anterior") e um sparkline no card de total.

- **Tendência/sparkline NÃO foram implementados** — decisão deliberada, mesmo critério
  já usado nos KPIs do Dashboard novo ("KPIs — só dado real, nada fabricado"): cada
  upload da SB2 faz um REPLACE completo de `estoque_saldo` (apaga e insere de novo, ver
  `replaceEstoqueSaldoInSupabase`), não existe nenhum histórico de snapshots anteriores
  guardado — não tem como calcular "vs. mês passado" de verdade. Se um dia existir uma
  tabela de histórico de saldo, essa tendência pode ser adicionada honestamente; até lá,
  o card de total não mostra nenhuma variação.
- **3 mini-cards de resumo, todos com dado real**: "Armazéns ativos" (contagem de
  armazéns distintos), "Itens distintos" (códigos distintos com saldo carregado) e
  "Cobertura do catálogo" — esse último é **novo conceito, mas real**: % dos 85 mil+
  códigos da tabela `produtos` que têm ALGUM saldo carregado em `estoque_saldo`
  (`count(distinct produto_codigo) / count(*) de produtos`). Só ~12% no teste real do
  cliente — mostra honestamente que a maior parte do catálogo ainda não tem saldo
  importado, em vez de esconder isso ou inventar um número mais bonito.
- **`estoque_resumo_geral()`** — nova função SQL (`backend/schema.sql`) que calcula os
  3 números acima direto no Postgres (evita trazer as ~12 mil linhas de
  `estoque_saldo` OU as 85 mil de `produtos` pro navegador). `fetchEstoqueResumoGeral()`
  no `index.html` chama essa RPC; cai pra `null` (mini-cards mostram dado do cache
  local ou "—" pra cobertura, que não faz sentido sem o total do catálogo real) se
  falhar ou a tabela estiver vazia — mesmo padrão de fallback já usado no resto do
  Dashboard.
- **Badges coloridos por armazém**: array fixo `ARMAZEM_COLORS` (8 cores, cicla por
  índice — `laranja Selgron, azul, verde, rosa, roxo, teal, cinza, laranja escuro`),
  não pega cor aleatória nem depende de mapeamento fixo por código de armazém (novo
  armazém que apareça no futuro só pega a próxima cor do ciclo automaticamente).
  Ícone dentro do badge continua emoji (🏭), mesmo critério já documentado antes:
  conteúdo de `Indicadores` usa o sistema de ícone antigo (`Ic`/emoji), não o
  `DIcon`/Lucide-style reservado pra sidebar/header/Dashboard novo (Início).
- **Toggle "Valor (R$)" / "% do Total"**: estado `modoValor` em `Dashboard`, controla só
  qual número aparece na coluna à direita de cada barra (o comprimento da barra em si
  já é proporcional ao valor nos dois modos — o toggle não muda o gráfico, só o texto).
  Funcional de verdade (não é só estético): testado clicando e conferindo que os
  números viram porcentagem (somando ~100% entre os armazéns).
- Testado via Playwright com as duas RPCs mockadas (`estoque_valor_por_almoxarifado` e
  `estoque_resumo_geral`) e screenshot comparado visualmente com a imagem de
  referência do cliente — layout, badges coloridos, mini-cards e toggle batem.

## Saudação da Home por horário (trocou "Bem-vindo, {perfil}")

Cliente achou repetitivo mostrar o perfil ("Bem-vindo, Administrador") logo acima do
nome na Home, já que o perfil já aparece no avatar do topbar/sidebar ao lado. Pediu uma
saudação por horário do dia em vez disso.

- `saudacaoPorHorario()` (perto de `Home`) — "Bom dia" (antes das 12h), "Boa tarde"
  (12h–18h), "Boa noite" (depois das 18h), usando `new Date().getHours()` do próprio
  aparelho (sem fuso horário fixo — cada tablet mostra conforme o horário local dele).
  `roleName` (que só existia pra essa linha) foi removido, já não tem mais uso.
- Testado via Playwright confirmando que a saudação bate com a hora do navegador no
  momento do teste ("Boa noite" às 19h).

## Correção do `CycleIcon` (setas "bugadas" na tela de login)

Cliente reportou que as setas do ícone de ciclo (`CycleIcon`, tela de login) pareciam
"bugadas". Causa: a ponta de seta era desenhada com um path de 2 segmentos só com
`stroke` (`M80 37 L90 47 L77 50`) — sem preenchimento, um "V" aberto. Em `stroke-width`
proporcional ao viewBox 100×100, isso já ficava fino de mais pra parecer uma seta de
verdade; no tamanho pequeno usado na faixa mobile do login (36px, `.login-cycle-icon`),
ficava ilegível — mais um risco torto do que uma ponta de seta.

- Recalculei a geometria com Python (arco + tangente no ponto final) e troquei os
  chevrons por **triângulos preenchidos** (`<polygon fill="var(--safety)">`) com o
  vértice exatamente na direção tangente do arco — path e cálculo completo documentados
  no commit. Preenchido continua nítido em qualquer tamanho, ao contrário de um stroke
  fino.
- Testado via Playwright com screenshot da tela de login inteira nos dois tamanhos reais
  usados no app (390px mobile → ícone 36px; 1280px desktop → ícone 104px) — as duas
  setas ficam claramente legíveis nos dois casos, sem erros de console.

## Recontagem de item sem cadastro reaproveita o endereço da 1ª contagem

Cliente reportou (com print) que recontar um item sem endereço cadastrado (comum —
Protheus ainda não tem esse dado) mostrava "ENDEREÇO: não cadastrado" na tela de
recontagem, mesmo o operador da 1ª contagem já tendo informado onde encontrou o item.
Quem recontava não tinha pista nenhuma de onde ir.

- **`RecountFlow`**: depois de montar o produto (do cache local `PRODUCTS` ou o
  fallback sintético, ver seção "Solicitar nova contagem..." acima), se o item não tem
  `enderecoCadastrado` e não tem `endereco` próprio, o código agora preenche
  `product.endereco` com `original.enderecoContado` (endereço que o operador da 1ª
  contagem de fato leu/informou) ou `original.endereco` como segunda opção.
- **De propósito, `enderecoCadastrado` continua `false`**: só o campo `endereco` é
  preenchido, pra exibição. Isso evita forçar uma etapa de leitura de QR Code
  (`expectAddressCheck`/`hasAddress` em `CountStep`) pra um endereço que nunca foi
  formalmente cadastrado/validado pelo líder — a recontagem continua indo direto pra
  quantidade, só que agora mostrando onde o item foi encontrado da primeira vez.
- **`CountStep`**: a linha do card que mostra o endereço trocou de
  `product.enderecoCadastrado ? product.endereco : 'não cadastrado'` pra
  `product.endereco || 'não cadastrado'` — mesmo resultado em todos os casos já
  existentes (nos dois lugares que constroem produto, `endereco` só é preenchido
  quando `enderecoCadastrado` também é `true`), mas agora também mostra o endereço
  reaproveitado da recontagem, que fica com `enderecoCadastrado:false` de propósito.
- Testado via Playwright (sandbox sem rede, contagem semeada no `localStorage`
  simulando o cenário exato do print do cliente — item `000.35310`, sem cadastro no
  cache local, 1ª contagem com `enderecoContado:'035-A-1'`): confirmei que a tela de
  recontagem mostra "035-A-1" em vez de "não cadastrado", e que o campo de quantidade
  continua aparecendo direto (sem forçar leitura de QR Code).

## Três correções: saldo real no catálogo Supabase, leitor de código de barras, campos de ação no topo

Pedido do cliente com 3 pontos:

**1. "A quantidade considerada como saldo é a coluna de Empenho, não Saldo Atual"** —
investiguei a fundo (comparei o cache local de 300 itens e o `parseSB2Rows` contra a
planilha SB2 real, cruzando 263 códigos que existem nos dois: 134 batiam exatamente com
"Saldo Atual", só 5 com "Empenhado" — coincidência de valores baixos, não confusão de
coluna) e **não encontrei nenhum lugar do código lendo "Empenhado" como saldo** — nem no
cache local, nem em `parseSB2Rows`. A causa real do sintoma ("muita recontagem") era
outra: `searchSupabaseCatalog` (usado pela "Contagem Manual" pra buscar no catálogo de
85 mil+ produtos) sempre devolvia `saldoSistema: null`, mesmo depois do cliente subir a
planilha SB2 real — o saldo carregado em `estoque_saldo` nunca tinha sido conectado à
busca de contagem, só aos cards do Dashboard. Resultado: qualquer item fora do cache
local de 300 SKUs (ou seja, quase tudo) ia direto pra "análise do líder" por falta de
saldo pra comparar, nunca por erro de coluna — mas o efeito prático (muita recontagem
desnecessária) era o mesmo que o cliente descreveu.
  - **Corrigido**: `searchSupabaseCatalog` agora busca também em `estoque_saldo`
    (coluna `saldo`, que é exatamente "Saldo Atual" da SB2 — `estoque_saldo` não tem
    coluna de empenho nenhuma) pros códigos encontrados, somando entre armazéns
    quando o item existe em mais de um (a busca não é presa a um almoxarifado
    específico). Consulta separada, não join automático do PostgREST, porque
    `estoque_saldo` não tem FK pra `produtos` (decisão já tomada antes, ver seção do
    upload da SB2).
  - Texto do aviso "fora do cache local" ajustado — antes dizia "veio da própria
    planilha importada (coluna Sistema)" mesmo quando o saldo agora pode vir do
    catálogo Supabase via `estoque_saldo`; ficou genérico ("planilha importada ou
    saldo real do catálogo").

**2. "Corrigir leitor para começar a ler código de barras"** — o `CameraScanner`
(`html5-qrcode`) já pedia `formatsToSupport` incluindo formatos de barra 1D
(CODE_128, CODE_39, EAN_13, EAN_8, UPC_A, ITF), então a configuração de formatos já
estava certa. O problema real (confirmado via documentação oficial da lib, pesquisada
porque o sandbox não tem câmera pra testar ao vivo): o decodificador padrão da
`html5-qrcode` é uma implementação em JS puro (ZXing-js) — funciona bem pra QR Code,
mas é conhecida por ser bem menos confiável pra código de barras 1D. A lib tem uma opção
`useBarCodeDetectorIfSupported: true` que usa a API nativa `BarcodeDetector` do
navegador (bem mais rápida e precisa pra 1D) em vez do ZXing, quando o navegador
suporta — e Chrome/Android (a plataforma alvo do app, tablets Android) suporta. Ativado
esse flag no construtor do `Html5Qrcode`; cai pro ZXing sozinho em navegadores sem
suporte (ex: Safari/iOS), sem quebrar nada lá. **Não testado ao vivo** (sandbox sem
câmera) — precisa o cliente confirmar no tablet real.

**3. "Campos de endereço/quantidade no topo, primeira coisa que a pessoa vê"** —
`CountStep` mostrava a ficha inteira do produto (unidade, família, almoxarifado,
endereço cadastrado, valor em estoque) ANTES de qualquer campo de ação, obrigando
rolar a tela pra chegar no que realmente importa contando. Reestruturado: agora só um
cabeçalho compacto (código + descrição, pra confirmar qual item é) aparece no topo,
seguido IMEDIATAMENTE pelo campo de ação da etapa atual (endereço manual, scan de QR,
ou quantidade) — a ficha completa do produto (`infoComplementar`, mesmo conteúdo de
antes) virou um card de referência que aparece DEPOIS, sempre visível mas fora do
caminho principal. Nenhuma mudança na lógica de estados/etapas, só na ordem visual.
- Testado via Playwright: confirmei por posição no HTML que tanto o campo "Endereço
  onde o item foi encontrado" quanto "Quantidade encontrada" aparecem antes do card
  `item-meta` (unidade/família/almoxarifado/endereço) no DOM, e por screenshot que o
  layout fica limpo — cabeçalho compacto, campo de ação em destaque, ficha do produto
  embaixo. Confirmei também (ponto 1) que buscar um item fora do cache local com saldo
  mockado em `estoque_saldo` já não cai mais no aviso de "sem saldo disponível".

## Remoção do cache local de 300 SKUs — usa só o Supabase agora

O cliente perguntou "o cache local, foi substituído pelos dados da SB2?" — a resposta
honesta era não: o cache estático de 300 itens (`RAW_SB2_PRODUCTS`/`PRODUCTS`, embutido
no `index.html`) continuava sendo consultado PRIMEIRO em vários fluxos, e só quando um
código não estava nesses 300 é que o app buscava o dado vivo no Supabase. Na prática,
contar um dos 300 itens do cache mostrava saldo **congelado antigo** (de quando o cache
foi gerado), enquanto qualquer outro código já usava o saldo real e atualizado — uma
inconsistência visível pro cliente. Ele pediu pra remover o cache de vez e usar só o
Supabase em tudo (confirmado via `AskUserQuestion`, escolheu a opção de remoção completa
em vez de só inverter a prioridade de busca).

Isso foi mais profundo do que só busca: o cache também **gerava a lista de itens** das
contagens "Aleatória"/"Curva ABC" (`RandomCountFlow`) e agrupava por corredor/rua na
"Rota de Endereço" (`RouteCountFlow`) — removê-lo exigiu portar essa lógica pra consultas
no banco.

**Achado que reduziu o risco da remoção**: `ANY_ADDRESS_REGISTERED` (que liberava o
módulo de Rota) era `RAW_SB2_PRODUCTS.some(p=>p.enderecoCadastrado)` — e as 300 linhas
do cache tinham `enderecoCadastrado:false` em 100% dos casos. Ou seja, "Contagem por
Rota de Endereço" já estava **sempre desligada** (empty-state permanente) antes desta
mudança — não era um comportamento funcionando que a remoção fosse quebrar.

**O que mudou**:

- **`backend/schema.sql`** ganhou a função `contagem_itens_prioritarios(p_limit)` — uma
  RPC que junta `estoque_saldo`+`produtos`+`estoque_enderecos`+`enderecos` e ordena por
  `(sem_movimento_recente desc, valor_financeiro desc)`, reproduzindo a mesma prioridade
  que o `RandomCountFlow` já usava sobre o cache local (item parado primeiro, depois por
  valor). **Assunção nova, documentada e ajustável**: "sem movimento recente" = sem saída
  há 90+ dias (ou nunca teve saída) — esse critério não existia em lugar nenhum antes (o
  campo `semMovimentoRecente` do cache era só um valor fixo sem regra visível); 90 dias é
  um padrão razoável de giro lento, mas o cliente pode pedir outro número.
- **Três funções novas no `index.html`** (perto de `fetchEstoqueValorPorAlmoxarifado`):
  `fetchContagemItensPrioritarios(limit)` (chama a RPC acima, mapeia pro mesmo formato de
  objeto "produto" que o app sempre usou, via `estoqueRowToProduct`), `fetchAnyAddressRegistered()`
  (substitui `ANY_ADDRESS_REGISTERED` — `count:'exact', head:true` em `estoque_enderecos`;
  continua retornando `false` hoje porque a tabela está vazia, então o módulo de Rota
  continua com o mesmo empty-state de sempre) e `fetchProdutosByCodigos(codigos)` (busca
  em lote — `produtos`+`estoque_saldo` via `.in('codigo', codigos)` — usada pela lista
  importada e pela recontagem).
- **`ManualCountFlow`**: parou de checar o cache local primeiro — busca sempre via
  `searchSupabaseCatalog` (já buscava em `produtos`+`estoque_saldo`+`estoque_enderecos`
  desde a correção da sessão anterior), debounce de 350ms mantido.
- **`RandomCountFlow`**/**`RouteCountFlow`**: `allItems`/`grouped` deixaram de ser
  `useMemo` síncrono sobre `PRODUCTS` e viraram `useState`+`useEffect` chamando
  `fetchContagemItensPrioritarios` — com estado de carregamento ("Carregando itens para
  contagem…"/"Verificando endereços cadastrados…") enquanto a lista não chega.
- **`Dashboard`**: a seção "Estoque" perdeu o fallback pro cache local — se
  `estoque_valor_por_almoxarifado`/`estoque_resumo_geral` voltarem vazios, mostra um
  empty-state honesto ("nenhum saldo carregado ainda — envie a planilha SB2 em
  Configurações") em vez de calcular a partir de 300 itens estáticos.
- **`NewInventory`/`buildImportTemplateWorkbook`**: o exemplo no modelo de planilha
  (`PRODUCTS[0]`) virou um exemplo fixo hardcoded (`000.35310`/"Exemplo de item"), não
  amarrado a nenhum produto real.
- **`parseImportedListRows`**: os checks síncronos `PRODUCTS.some(...)` (pra achar "não
  encontrados"/"sem saldo disponível") viraram um passo assíncrono novo,
  `computeImportSummaryExtras(itens)`, chamado por `NewInventory.handleFileUpload` depois
  do parse síncrono inicial — busca todos os códigos da planilha de uma vez (1 request) e
  completa o resumo sem travar a exibição inicial.
- **`ImportedListCountFlow`**: troca `PRODUCTS.find` por `fetchProdutosByCodigos` (lote,
  uma vez ao montar) — o catálogo prevalece quando o item é achado, mas a planilha
  continua tendo prioridade pra endereço/saldo próprios quando ela trouxe esses dados
  (mesma regra de antes). Tela de carregamento ("Carregando itens da lista importada…")
  enquanto isso não resolve.
- **`RecountFlow`**: troca `PRODUCTS.find(...)` por busca ao vivo via
  `fetchProdutosByCodigos([original.productCode])` — se não encontrar ou a rede falhar,
  cai pro MESMO fallback sintético de sempre (montado a partir de `original`, que já
  carrega descrição/endereço/saldo da 1ª contagem) — rede cair não quebra a recontagem.
- **`PickCountType`** (tela "Nova Contagem" avulsa, escolha do tipo de contagem) também
  usava `ANY_ADDRESS_REGISTERED` direto pra habilitar/desabilitar o botão "Contagem por
  Rota de Endereço" — não tinha sido identificado na pesquisa inicial (só apareceu na
  varredura final de verificação `grep`), corrigido com o mesmo padrão async de
  `fetchAnyAddressRegistered()`.
- **`RAW_SB2_PRODUCTS`, `PRODUCTS` e `ANY_ADDRESS_REGISTERED` foram removidos por
  completo** do `index.html` (a linha gigante ~90KB do array estático e as duas
  constantes derivadas dela) — reduz bastante o tamanho do arquivo. Alguns textos
  visíveis no app que citavam "cache local"/"300 SKUs" também foram ajustados: o aviso
  amarelo do `CountStep` pra item sem saldo (antes dizia "código não está no cache local
  de 300 SKUs do protótipo" mesmo quando o saldo já vinha do catálogo real — texto
  simplificado pra só aparecer quando realmente não há saldo nenhum pra comparar) e o
  `rule` da classificação de item sem saldo (usado como texto de status em telas de
  recontagem/relatório, antes dizia "fora do cache local do protótipo").

**Fora de escopo, decisão consciente**:
- Filtro por almoxarifado em `RandomCountFlow`/`RouteCountFlow`/`PickCountType`: hoje
  `inv.almoxarifado` é texto livre tipo "Almox 01", mas os códigos reais de armazém no
  Supabase são "1", "4", "EX" etc. — não bate. A RPC nova busca em TODOS os armazéns por
  enquanto; resolver esse mapeamento de nomes é um problema separado.
- O limiar de "sem movimento recente" (90 dias) é uma escolha razoável, não uma regra já
  validada com o cliente — ajustável se ele pedir outro número depois de ver o resultado.

**Precisa rodar no Supabase**: a função `contagem_itens_prioritarios` (SQL completo em
`backend/schema.sql`) ainda não foi aplicada no projeto real — falta o cliente colar no
SQL Editor.

- Testado via Playwright (sandbox sem rede, todas as chamadas Supabase mockadas):
  `ManualCountFlow` busca só remoto (sem "vencedor" local); `RandomCountFlow` mostra o
  item "sem movimento recente" primeiro (respeitando a ordenação da RPC mockada) e monta
  a etapa de contagem normalmente; `NewInventory` gera o modelo de planilha e cria um
  inventário Aleatório sem erro nenhum sem `PRODUCTS`; `Dashboard` mostra o empty-state
  novo quando as RPCs de estoque voltam vazias, sem número nenhum de cache; lista
  importada mostra o 1º item na ordem original da planilha já enriquecido com a descrição
  vinda do catálogo mockado; `RecountFlow` recontou um item com código ausente do
  catálogo (mesmo cenário do bug `000.07514` corrigido antes) sem quebrar, reaproveitando
  o endereço da 1ª contagem. Não consegui exercitar via Playwright o caminho de
  `RouteCountFlow` com endereços cadastrados de verdade (`anyAddress:true`) — o mock de
  `count:'exact', head:true` do Supabase-js depende do header `content-range` numa
  resposta `HEAD`, e o Chromium do sandbox descarta esse header em respostas `HEAD`
  mockadas (confirmado isolando o `fetch` puro) — limitação do ambiente de teste, não do
  código; a lógica de agrupamento por corredor/rua é a mesma já usada antes, só trocando
  a fonte dos dados.

## Padrão de planilha do cliente — histórico importado + export alinhado

O cliente mandou `Base_Analise_Contagens_2026.xlsx`, a planilha de análise que a Selgron já
usava para controlar contagens ANTES do Inventário 360 (aba **BD_Contagens**, 3.659 linhas
reais, fev/2026–jul/2026, mais as abas SB2/BD_Descrição/Resumos_Calculo/Indicadores de
apoio). Pediu duas coisas: (1) mandar esse histórico pra nossa base, e (2) usar essa
planilha como padrão de geração de `.xlsx` do app. Confirmado via `AskUserQuestion`:
histórico numa **tabela separada** (não a `contagens` que o app usa ao vivo), export do
relatório ajustado pro mesmo layout, e **Classe/SA não capturados no fluxo de contagem por
enquanto**.

**Descoberta importante durante a análise**: as colunas da aba BD_Contagens têm fórmulas
derivadas, não são todas dado bruto — confirmei comparando várias linhas reais:
`Custo = Diferença × Custo Unitário` (com sinal), `Acc = max(0, 1 - |Diferença|/Sistema)`
(acuracidade do item, 0 a 1), `Sem. = número da semana ISO` (mesma regra do
`getWeekInfo`/gráficos semanais do Dashboard — bateu exato), e `Doc` é só a `Data`
reformatada `DDMMYY` (não é um ID à parte). `Status` tem 6 estados (OK/Recontar/Ajustado/
Sem Ajuste/Pendente/Ajustar) — mais granular que os 5 estados internos do app (não
distingue "ajuste já aplicado no Protheus" de "aprovado, sem ajuste necessário").

### Histórico: `contagens_historico` (Supabase, tabela separada)

- **Por que separada da `contagens` viva**: `getOpenCountForProduct` usa a tabela
  `contagens` pra bloquear lançar uma contagem NOVA de item que já tem "documento em
  aberto" (status `aguardando_segunda`/`aguardando_analise_lider`). Linhas históricas com
  Status tipo "Recontar"/"Pendente"/"Ajustar" — já resolvidas há meses na vida real, só não
  no vocabulário que o app entende — se misturadas na mesma tabela fariam um item real
  aparecer "bloqueado" hoje por causa de um registro de fevereiro. `contagens_historico`
  é só leitura/relatório — nenhuma tela do app consulta essa tabela pra decidir nada ainda
  (não tem UI de navegação pelo histórico implementada, só o armazenamento).
- **Colunas ficam com o vocabulário CRU da planilha original** (`status`, `classe`,
  `causa`, `solicitacao_ajuste` como texto livre) em vez de mapeadas pro vocabulário
  interno do app — são conceitos de workflow diferentes (ver "Status" acima), forçar a
  correspondência perderia informação real sem necessidade.
- **`unique(produto_codigo, data, endereco)` + upsert (não insert/replace)**: o arquivo
  master do cliente só cresce com novas rodadas — ele provavelmente vai re-subir o mesmo
  arquivo mais de uma vez ao longo do tempo. Upsert nessa chave composta faz o re-upload
  não duplicar linhas já importadas antes. **Assunção documentada**: não existem duas
  contagens do MESMO item, MESMO endereço, MESMO dia na planilha original — plausível,
  mas linhas sem `Data` preenchida (460 das 3.659 no arquivo real do cliente — a coluna
  às vezes vem vazia) não dedupicam direito, porque `NULL` conta como valor distinto numa
  unique constraint do Postgres.
- **`parseHistoricoContagensRows`/`HistoricoImportPanel`** (Configurações, só admin) —
  mesmo padrão visual/fluxo do `StockSyncPanel` (upload → resumo → confirmar → progresso
  em lotes de 500), mas o PARSER é diferente: a planilha tem um bloco de indicadores
  ANTES da tabela de verdade (linhas 1-5 do arquivo original — título, metas, resumo), então
  lê a aba como matriz crua (`sheet_to_json(sheet, {header:1})`) e PROCURA a linha que tem
  "Código" numa das colunas, em vez de assumir cabeçalho na linha 1 como todo o resto do
  app. Resolve colunas pelo NOME (não posição) — robusto a reordenação numa exportação
  futura do cliente.
- **Testado com o arquivo real do cliente** (não só mockado): rodei o parser contra
  `Base_Analise_Contagens_2026.xlsx` de verdade via Playwright (`setInputFiles` com o
  arquivo real) — confirmou 3.659 linhas válidas, 0 sem código, 8 lotes de upsert
  (3.659/500), e o payload da 1ª linha batendo exatamente com os valores reais da
  planilha (`000.41707`, Custo -13.65, Acc 0, Sem. 9, Doc "250226", SA "71813" etc.).
  Não testei contra o Supabase de verdade — falta o cliente rodar o SQL da tabela nova
  (`backend/schema.sql`) no projeto real e confirmar o upload ao vivo, mesmo padrão de
  handoff de sempre.

### Export do relatório alinhado ao padrão do cliente

- **`buildCountRows`** (aba "Contagens" do relatório .xlsx) foi reordenada: as colunas
  no MESMO nome/ordem da planilha do cliente vêm primeiro (Código/Descrição/End/Sistema/
  Fisico/Diferença/Custo/Acc/Data/Sem./Status/Classe/Causa/OBS/SA/Dias S/Mov./Doc) — ele
  pode colar/importar direto na análise dele sem reformatar — seguidas das colunas extras
  que só o app tem (ID Contagem, Inventário, Endereço Contado, Rodada, Usuário,
  Divergência %, Classificação, Status detalhado, Endereço Pendente Validação, Hora), que
  não existem na planilha original.
- **`statusLabelPadrao`** — mapa pro vocabulário curto do cliente
  (`aprovado_auto`/`aprovado_segunda`→`OK`, `aguardando_segunda`→`Recontar`,
  `aguardando_analise_lider`→`Pendente`, `aprovado_lider`→`Sem Ajuste`). Aproximado por
  natureza: o app não distingue "ajuste já aplicado no Protheus" de "aprovado, sem ajuste
  necessário" (os dois caem em `aprovado_lider`) — não temos como saber se o ajuste foi
  de fato lançado no Protheus depois da aprovação, então os dois mapeiam pra "Sem Ajuste".
- **`valorDivergenteComSinal`** — o app só guarda o valor ABSOLUTO em `valorDivergente`
  (ver `CountStep.finalize`); a coluna "Custo" do cliente é assinada, então recupera o
  sinal a partir de `diferenca` na hora de montar a linha do relatório, sem mudar como o
  app guarda o dado internamente.
- **`acuracidadeItem`**/**`formatDocFromData`** — mesma fórmula confirmada na planilha
  original (`max(0, 1-|diferença|/sistema)` e data reformatada `DDMMYY`).
- **"Classe" e "SA" sempre em branco no export, de propósito** (decisão confirmada: "não
  por enquanto") — o app não captura ABC nem número de solicitação de ajuste em nenhum
  lugar do fluxo de contagem hoje. **"Dias S/ Mov." também fica em branco** pelo mesmo
  motivo prático: não é salvo dentro do objeto `count` (só existe em `estoque_saldo`, que
  o relatório não teria como cruzar sem uma consulta extra ao Supabase na hora de gerar o
  arquivo — fora do escopo desta rodada). Se o cliente quiser esses três campos
  preenchidos de verdade no futuro, o próximo passo é decidir onde capturar Classe/SA no
  fluxo ao vivo (ex: líder informa o nº do ajuste ao aprovar a divergência; Classe viria
  do catálogo/`estoque_saldo`, que já tem a lógica de valor financeiro pra derivar ABC).
- Testado via Playwright (sandbox sem rede): baixei o relatório com 2 contagens seedadas
  (incluindo o MESMO código `000.41707` do arquivo real do cliente) e confirmei, abrindo
  o `.xlsx` gerado, que a aba "Contagens" tem as 27 colunas na ordem esperada e que
  Custo/Acc/Sem./Doc batem com os valores reais da planilha original do cliente pra esse
  código.

## Itens "Recontar" do histórico entram de verdade na fila de recontagem

Depois de ver o histórico importado, o cliente esclareceu que os itens com Status=
"Recontar" na planilha **não estão resolvidos** — precisam mesmo aparecer pra recontar
dentro do app, não só ficar arquivados em `contagens_historico` pra consulta. Ajustado o
`HistoricoImportPanel` pra, além de gravar tudo no histórico, também **semear esses itens
na fila real de recontagem**.

- **`buildRecontarSeedsFromHistorico(linhas)`** filtra só `status==='Recontar' &&
  produto_codigo && data` (linhas sem `data` — 460 das 3.659 no arquivo real — são
  puladas aqui, mas continuam indo pro histórico normalmente) e monta uma linha no MESMO
  formato que `saveContagemToSupabase` grava em `contagens` — `status_aprovacao:
  'aguardando_segunda'`, `numero_contagem: 1`, `usuario: 'Importação Histórica'` (não
  inventa nome de operador, já que a planilha não guarda quem contou), `classificacao`
  calculada com o mesmo `classifyDivergence(percentual)` que o resto do app usa.
- **`id` determinístico** (`CNT-HIST-<código sem pontuação>-<data sem traço>`) em vez de
  aleatório — junto com `seedRecontarQueueFromHistorico` usando `.upsert(lote,
  {onConflict:'id', ignoreDuplicates:true})`, isso faz o re-upload do mesmo arquivo (o
  master do cliente só cresce) não duplicar entradas na fila. `ignoreDuplicates:true` vira
  `ON CONFLICT DO NOTHING` no Postgres — **não precisa de policy de UPDATE em
  `contagens`** (que não existe de propósito, só INSERT — ver schema), diferente de um
  upsert comum que exigiria permissão de update também.
- **Nenhuma tela nova**: como o item semeado tem exatamente o mesmo formato que qualquer
  outro `aguardando_segunda` gerado ao vivo pelo app, ele aparece sozinho em
  "Recontagens" → "Aguardando Segunda Contagem" assim que o `sync()` de 30s (ou o login)
  buscar a tabela `contagens` do Supabase — reaproveita 100% o mecanismo de merge aditivo
  que já existia (`fetchContagensFromSupabase`, nunca sobrescreve local, só adiciona por
  `id` novo). Qualquer operador pode clicar "Recontar este item" e cai no `RecountFlow`
  normal.
- **`fetchContagensFromSupabase`: limite subiu de 500 pra 2000** — os itens semeados
  gravam `criado_em=now()` no momento da importação, então ficam no topo da ordenação
  (mais recentes primeiro) e podiam empurrar contagens reais mais antigas pra fora da
  página de 500 num aparelho que ainda não tinha sincronizado tudo. Ainda sem paginação de
  verdade, só um limite maior — mesmo tipo de limitação já documentada em outras buscas.
- **Painel mostra o total ANTES de confirmar** ("N itens marcados 'Recontar' vão entrar
  na fila de recontagem do app") e confirma depois quantos entraram de fato — mesmo
  padrão de transparência do resto da importação.
- Testado com o arquivo real do cliente via Playwright: 116 das linhas "Recontar" (de
  452 no total — as com `data` preenchida) viraram entradas na fila, confirmei o payload
  exato de uma delas (`000.02788`, motivo "Chapas/Barras e Tubos", classificação
  "Divergência crítica", `valor_divergente` absoluto batendo com o `Custo` assinado da
  planilha) e que um código com Status="Ajustado" (`000.41707`) NÃO foi semeado. Depois,
  simulando esse item já sincronizado localmente (mesmo formato que `contagemRowToLocal`
  produz), confirmei que ele aparece em "Recontagens" → "Aguardando Segunda Contagem"
  com "Importação Histórica" como quem contou, e que "Recontar este item" abre o
  `RecountFlow` normalmente, sem erro de "item não encontrado". Não testei contra o
  Supabase de verdade — falta o cliente rodar o SQL de `contagens_historico` (já
  compartilhado) e confirmar a importação ao vivo.

## Reset geral de contagens/inventários antes de importar o histórico real

O cliente testou o app antes de importar a planilha de análise e pediu pra "zerar tudo"
(contagens e inventários de teste) antes de começar a usar o histórico real. Perguntou se
dava pra fazer isso só via SQL — não dá: o `localStorage` é local de cada navegador/
aparelho, nenhum SQL no Supabase alcança isso. A solução foi o mecanismo que o próprio
código já previa pra esse cenário (`STORAGE_VERSION`, comentário original: "se o formato
dos dados mudar... basta subir a versão pra ignorar dados antigos").

- **`inventories`/`counts` viraram `inventories_v2`/`counts_v2`** (só essas duas chaves —
  `users`, `passwordHistory`, `enderecosPropostos` etc. continuam nas chaves antigas, não
  fazia sentido derrubar login/senhas dos usuários cadastrados). Qualquer aparelho que
  abrir o app depois deste deploy procura uma chave que não existe mais no
  `localStorage` e começa vazio sozinho — sem precisar de comando manual em cada tablet.
- **Removida também a seed de 2 inventários fake** (`INV-001`/`INV-002`, do início do
  protótipo, hardcoded como valor padrão de `usePersistedState`) — um aparelho novo, sem
  nenhum dado local ainda, não fazia mais sentido reabrir mostrando esses dois
  inventários de mentira agora que o app trabalha com dado real.
- **Ainda assim precisa limpar o Supabase por SQL** (isso sim é possível e necessário):
  `delete from contagens; delete from inventarios;` — o reset de `localStorage` só
  cuida do lado do navegador; sem isso os dados de teste continuariam voltando pro
  aparelho via o `sync()` de 30s (que traz o que está no Supabase pro local).
- Testado via Playwright simulando dois cenários: aparelho com dado salvo na chave
  antiga (`stock360:v1:counts`/`stock360:v1:inventories`) — confirma que o app ignora e
  mostra as telas vazias; e aparelho sem nenhum dado — confirma que os 2 inventários
  fake não aparecem mais.

## Histórico de contagens/inventários único e centralizado entre aparelhos

O cliente zerou contagens/inventários de teste (ver seção anterior) pra ter um ponto de
partida limpo antes de importar o histórico real, e isso expôs um problema maior: ele
perguntou se dava pra garantir que **todo aparelho veja o mesmo histórico**, e a resposta
honesta na hora era não — o app não garantia isso. Investigando o código, a causa raiz
tinha um gap concreto: as ações do líder de **aprovar ou rejeitar uma divergência**
(`approveDivergence`/`requestRecountFromOperator`) só mudavam o estado local do aparelho
dele, nunca eram gravadas no Supabase (a tabela `contagens` nem tinha policy de UPDATE) —
um líder aprovando num tablet nunca aparecia em nenhum outro. `deleteInventory` tinha o
mesmo problema. E toda gravação (`saveContagemToSupabase`, `saveInventarioToSupabase`,
`incrementContadosSupabase`) era fire-and-forget sem retry — se falhasse (aparelho sem
sinal naquele instante), o dado ficava só ali pra sempre.

Confirmado com o cliente (`AskUserQuestion`, duas rodadas — a 2ª depois dele perguntar
explicitamente "não terei problema de alguma informação aparecer só num tablet
específico?"): a contagem em si continua rápida/local (chão de fábrica não pode travar
esperando internet), mas as ações do líder passam a aguardar confirmação do Supabase, E
o app ganhou uma fila de reenvio automático pra contagem/incremento — fechando
exatamente a lacuna que a pergunta dele expôs.

### `backend/schema.sql` — colunas e policies novas

`contagens` ganhou `aprovado_por`, `aprovado_em`, `recontagem_solicitada_pelo_lider`,
`recontagem_solicitada_por`, `recontagem_solicitada_em` (persistem o que
`approveDivergence`/`requestRecountFromOperator` já setavam localmente, mas nunca
gravavam) e `atualizado_em timestamptz default now()` (usada pela sincronização pra saber
qual lado — local ou remoto — é mais recente ao reconciliar, mesmo papel que `contados`
já cumpre pra `inventarios`). Policy de UPDATE nova em `contagens` (só tinha SELECT/
INSERT) e policy de DELETE nova em `inventarios` (só tinha SELECT/INSERT/UPDATE) — sem
essas duas, aprovar/rejeitar/excluir continuariam batendo na parede do RLS mesmo depois
do código já tentar gravar. Bloco de `alter table` separado no fim do arquivo pra rodar
no projeto real (que já tinha as tabelas criadas antes desta mudança).

### `index.html` — funções Supabase novas/alteradas

- **`updateContagemStatusToSupabase(id, patch)`** — nova, `await`ada (diferente do
  padrão fire-and-forget de sempre), sempre inclui `atualizado_em: new Date().
  toISOString()`. `deleteInventarioFromSupabase(id)` — nova, também `await`ada.
  `saveInventarioToSupabase` mudou de não retornar nada pra retornar `{ok, erro}` também.
- **`fetchInventoriesFromSupabase`** passou a retornar `null` (não `[]`) quando a busca
  FALHA, distinto de `[]` (busca funcionou, lista genuinamente vazia) — essencial pra
  sincronização poder remover um inventário local ausente do Supabase com segurança, sem
  confundir "sem inventário nenhum" com "a rede caiu bem na hora de checar".
- **`contagemRowToLocal`** mapeia as 5 colunas novas de decisão do líder + `atualizadoEm`.

### Ações do líder/admin agora aguardam confirmação, com erro visível

`approveDivergence`, `requestRecountFromOperator` e `deleteInventory` (em `App()`) viram
`async`: chamam a função Supabase primeiro, só atualizam o estado local se `res.ok` —
`RecountsPanel` ganhou `busyId`/`erros` (desabilita só o botão clicado, mostra erro
inline naquele card específico, sem travar a tela toda) e `InventoryList` ganhou
`excluindo`/`erroExclusao` no mesmo bloco de confirmação inline que já existia. Criação de
inventário (`onCreate` em `App()`, chamado por `NewInventory`) também virou aguardada —
`NewInventory` ganhou `salvando`/`erroCriacao`, com o botão "Criar Inventário" desabilitado
durante o envio e o formulário preenchido continuando visível se falhar (nada se perde).

### Fila de reenvio automático pra contagem/incremento — sem tela nova

A contagem em si (`CountStep.finalize`) continua **instantânea e local** — só ganhou um
campo `_syncPendente:true`, sem mudança de UX pro operador. O que muda: os 5 pontos que
antes faziam `setCounts(p=>[c,...p])` direto (`RandomCountFlow`/`ManualCountFlow`/
`RouteCountFlow`/`ImportedListCountFlow`/`RecountFlow`, todos via prop `onFinish` em
`App()`) agora chamam **`registerFinishedCount`**, um ponto único que adiciona local
E tenta `saveContagemToSupabase` — se der certo (caso comum), o flag vira `false` na
hora; se falhar, continua `true`.

O ciclo de sync de 30s (que já existia) virou **também o mecanismo de retry**: no início
de cada `sync()`, reenvia qualquer `counts` com `_syncPendente===true` (lidos via
`countsRef`, não direto do state, pra não pegar um closure desatualizado dentro do
`setInterval`) e qualquer id em **`getPendingIncrements()`** (fila de incrementos de
inventário que falharam, guardada direto no `localStorage`, fora do estado React de
propósito — assim os 3 pontos que chamam `incrementContadosSupabase`
(`RandomCountFlow`/`RouteCountFlow`/`ImportedListCountFlow`) continuam chamando exatamente
como antes, sem precisar receber um callback novo de `App()`). Resultado: um tablet que
ficou sem sinal no meio de uma contagem sincroniza sozinho assim que a internet voltar —
não precisa ninguém abrir aquele aparelho especificamente, só que o app continue
aberto (ou seja reaberto em algum momento) com conexão de novo.

**Indicador visual mínimo**: rodapé da `Sidebar` (mesmo lugar de "Sistema operacional ·
Versão 1.0.0") mostra "N contagens aguardando conexão" quando há algo pendente (conta
`_syncPendente` de `counts` + `pendingIncrementsCount`, atualizado a cada ciclo de sync),
some sozinho quando tudo sincroniza. Não é tela nova, só uma linha condicional.

### Sincronização — de "só soma" pra "reconcilia de verdade"

- **Contagens**: continua aditivo pra id novo, mas agora TAMBÉM atualiza uma já
  conhecida localmente quando `remoto.atualizadoEm >= local.atualizadoEm` — é isso que
  faz a aprovação/rejeição do líder aparecer nos outros aparelhos.
- **Inventários**: mantém "só sobrescreve se `contados` remoto ≥ local", e agora TAMBÉM
  remove localmente um inventário ausente da busca remota (a exclusão em outro aparelho
  se propaga). Só é seguro porque criação de inventário virou uma ação aguardada (não
  tem mais risco de remover um inventário recém-criado que ainda não tinha propagado) e
  porque `fetchInventoriesFromSupabase` agora distingue "busca falhou" de "lista vazia
  de verdade" (ver acima).

### Fora de escopo (decisão consciente)

- Não migra login/usuários pro Supabase — decisão já tomada antes, continua 100% local.
- Não elimina a janela de até 30s entre um aparelho gravar e outro ver — duas pessoas
  contando o mesmo item ao mesmo tempo em aparelhos diferentes ainda podem colidir
  dentro dessa janela (limitação já documentada antes). Isso resolve consistência ao
  longo do tempo, não elimina a corrida em tempo real (precisaria de Realtime/WebSocket).
- RLS continua `using(true)`/`with check(true)` em tudo — sem Supabase Auth ainda, mesma
  ressalva de sempre.

Testado via Playwright (sandbox sem rede, Supabase mockado incluindo simulação de dois
"aparelhos" compartilhando um mesmo objeto de banco em memória): aprovar/rejeitar
divergência com sucesso e com falha simulada (card mantém estado + mostra erro na
falha); excluir e criar inventário nos dois cenários; uma contagem cujo 1º save falha
(mock 500) — confirma o indicador "aguardando conexão" aparecendo e, depois do próximo
ciclo de 30s (esperado de verdade no teste, sem mock de relógio), o reenvio automático
funcionando e o indicador sumindo; e o cenário completo de dois aparelhos — um líder
aprova uma divergência no aparelho A, o aparelho B (que via o item pendente antes) deixa
de mostrá-lo como pendente depois de reabrir. Toda a suíte de regressão já existente no
scratchpad também rodou de novo sem quebrar (algumas precisaram só de um ajuste pontual:
duas ainda seedavam a chave antiga `stock360:v1:counts` em vez de `counts_v2`, um teste
navegava pro botão "Criar Inventário" que só existe quando a lista já tem pelo menos 1
item — trocado pelo atalho "Criar novo inventário" da Sidebar, que sempre existe).
Não testei contra o Supabase de verdade — falta o cliente rodar o SQL novo (`alter
table`/policies, seção no `backend/schema.sql`) no projeto real.

## Bug real na importação do histórico: linhas duplicadas na mesma planilha quebravam o upsert

Ao rodar a importação de verdade (`Base_Analise_Contagens_2026.xlsx`, 3.659 linhas) contra
o Supabase real do cliente pela primeira vez, o upload falhou no 4º lote (linha 1500) com
`ON CONFLICT DO UPDATE command cannot affect row a second time` — erro nativo do Postgres
quando um único `INSERT ... ON CONFLICT DO UPDATE` recebe, no mesmo lote, duas linhas que
colidem na MESMA chave de conflito (`produto_codigo, data, endereco`, a unique constraint
de `contagens_historico`). O Postgres não consegue aplicar um upsert duas vezes na mesma
linha dentro da mesma instrução — precisa que cada chave apareça no máximo uma vez por
lote de `upsert()`.

- **Causa**: a planilha master do cliente tem, de fato, linhas com o mesmo
  produto+data+endereço repetidas (provavelmente um lançamento duplicado ou uma correção
  que foi adicionada como linha nova em vez de substituir a antiga) — a suposição
  documentada antes ("não existem duas contagens do MESMO item, MESMO endereço, MESMO
  dia") não se sustentou 100% no arquivo real.
- **Correção em `parseHistoricoContagensRows`**: depois de montar `linhas`, um passo novo
  deduplica por chave `produto_codigo+data+endereco`, mantendo a ÚLTIMA ocorrência (arquivo
  master só cresce, a linha mais abaixo tende a ser a versão mais recente/corrigida) —
  antes de qualquer lote ser montado, então nenhum lote pode mais conter a mesma chave
  duas vezes.
- **Cuidado importante pra não regredir a limitação já documentada das ~460 linhas "sem
  data"**: o Postgres trata `NULL` como sempre distinto de qualquer outro valor, mesmo de
  outro `NULL` — então duas linhas com `data` ou `endereco` vazios NUNCA colidem de
  verdade na unique constraint, não importa quantas vezes o mesmo `produto_codigo` se
  repita sem data. A primeira versão deste dedupe usava uma chave que tratava `null` como
  `''`, o que teria colapsado incorretamente linhas distintas sem data do mesmo produto
  (perda real de histórico) — corrigido pra só deduplicar quando os TRÊS campos da chave
  são não-nulos e batem, espelhando exatamente a semântica do Postgres. Linhas com
  data/endereço vazios continuam passando direto, sem dedupe (mesma limitação já aceita
  antes, documentada na seção "Padrão de planilha do cliente").
- **Resumo pré-confirmação ganhou mais um contador**: `resumo.duplicadas` (visível no
  `HistoricoImportPanel` como "N duplicadas (mesmo código+data+endereço, mantida a mais
  recente)"), mesmo padrão de transparência já usado pros outros contadores
  (`semCodigo`/`semData`).
- Testado com uma planilha sintética reproduzindo exatamente o cenário (duas linhas com
  mesma chave completa — dedupe corretamente pra 1, mantendo o valor da última; duas
  linhas do mesmo produto com data/endereço nulos — as duas mantidas, sem dedupe
  incorreto) via script Node isolado (função copiada, sem depender do browser). Depois,
  reproduzido via Playwright contra o `Base_Analise_Contagens_2026.xlsx` REAL do cliente
  (o mesmo arquivo que gerou o erro original) com o upsert do Supabase mockado: a
  importação completa passou a suceder — 3.658 linhas gravadas (3.659 válidas menos
  exatamente 1 duplicata real colapsada), 8 lotes, nenhum lote com chave não-nula
  repetida, sem o erro "ON CONFLICT DO UPDATE command cannot affect row a second time",
  e os 116 itens "Recontar" continuaram entrando na fila normalmente (mesmo número já
  documentado antes). Falta o cliente re-tentar o upload real no Supabase de verdade pra
  confirmar ao vivo.

## Sessão de login sobrevive a recarregar a página

O cliente reclamou que atualizar a página estava sempre mandando de volta pro login — esse
era um comportamento DELIBERADO desde o início do app (documentado antes como "não faz
sentido reabrir no meio de um fluxo de contagem... manter sessão logada automaticamente
teria implicação de segurança maior, tablet compartilhado no chão de fábrica"), mas na
prática, com o uso real, ficou claro que é mais incômodo que protetor — o cliente prefere
continuar logado entre recarregamentos e confiar só no logout automático por inatividade
(que já existia, 15 min, `SESSION_TIMEOUT_MS`) pra cobrir o caso do tablet compartilhado.

- **`SESSION_STORAGE_KEY = 'stock360:v1:session'`** (constante módulo, perto de
  `usePersistedState`) — guarda só `{userId, lastActivity}` no `localStorage`, nunca
  senha nem nada além do id. Funções `loadSession`/`saveSession`/`touchSession`/
  `clearSession`, mesmo padrão simples já usado pra `pendingIncrements`
  (leitura/escrita direta, fora do estado React, com `try/catch` silencioso se
  `localStorage` não estiver disponível).
- **`currentUserId` inicializa via `useState(() => ...)`** lendo `loadSession()`: se não
  tem sessão salva, se ela já passou de `SESSION_TIMEOUT_MS` desde a última atividade, ou
  se o usuário não existe mais / foi bloqueado / está com `deve_definir_senha` — volta
  `null` (login normal). Senão, restaura a sessão direto, sem passar pela tela de login.
  Funciona porque `users` (via `usePersistedState`) já está carregado síncronamente antes
  desse `useState` rodar (hooks executam em ordem dentro do mesmo render).
- **`attemptLogin`/`selfSetNewPassword` chamam `saveSession(user.id)`** depois de logar
  com sucesso; **`logout` chama `clearSession()`** — mesmos 3 pontos de entrada/saída de
  sessão de sempre, só ganharam a chamada extra.
- **O timer de inatividade continua sendo a única forma de expirar a sessão sozinha**,
  mas precisou de um ajuste pra não virar uma sessão eterna: sem isso, um F5 a cada 14
  min reiniciaria o timer pra 15 min inteiros de novo, todo santo dia. Agora, ao montar o
  efeito, o PRIMEIRO timer usa `SESSION_TIMEOUT_MS - (tempo já decorrido desde
  lastActivity)` em vez de `SESSION_TIMEOUT_MS` cheio — e cada evento de atividade
  (`click`/`keydown`/`touchstart`/`mousemove`) agora também chama `touchSession()`, pra
  manter o `lastActivity` do `localStorage` atualizado (sem isso, o cálculo acima ficaria
  sempre baseado no momento do login, não da última atividade real).
- **Não mudou nesta rodada**: navegação (`view`/`flowState`) continuava só em memória —
  recarregar ainda voltava pra Home. **Atualização posterior**: o cliente pediu
  explicitamente pra isso também persistir (ver seção "Navegação sobrevive a recarregar
  a página" mais abaixo) — essa frase aqui documenta só a decisão original desta rodada,
  já superada. RLS/backend não têm nada a ver com isso — é 100% front-end/`localStorage`,
  mesmo escopo de sempre pra sessão.
- Testado via Playwright (sandbox sem rede): login seguido de reload mantém logado (sem
  cair na tela de login); uma sessão com `lastActivity` forçado pra 20 min atrás (>15 min)
  força de volta pro login e limpa a chave do `localStorage`; logout explícito (menu do
  usuário no `DesktopTopbar`) limpa a sessão e um reload posterior continua mostrando o
  login (não "ressuscita" a sessão já encerrada). Toda a suíte de regressão já existente
  no scratchpad (aprovar/rejeitar divergência, excluir/criar inventário, dashboard,
  recontagens por perfil, remoção do cache local) rodou de novo sem quebrar.

## Bug crítico: tela de Recontagens ficava em branco pra item vindo do histórico

O cliente reportou que clicar em "Recontagens" deixava a tela inteira em branco (sem
nenhum erro visível, só o topo do navegador). Causa: `RecountsPanel` lia
`c.percentual.toFixed(1)` protegido só por `c.diferenca==null` — assumindo que
`diferenca` e `percentual` são sempre os dois `null` ou os dois preenchidos juntos. Isso é
verdade no fluxo normal de contagem (`CountStep.finalize`, ambos vêm de `hasSaldoLocal ?
X : null` na mesma linha), mas **não** é verdade pros itens semeados pela importação do
histórico (`buildRecontarSeedsFromHistorico`, ver seção "Itens 'Recontar' do histórico
entram de verdade na fila de recontagem"): `percentual` só é calculado quando
`saldo_sistema` (coluna "Sistema" da planilha) está presente e diferente de zero, mas
`diferenca` (coluna "Diferença") vem direto da planilha independente disso — então um
item do histórico com "Diferença" preenchida mas "Sistema" vazio/zero tem `diferenca`
não-nulo e `percentual` nulo. Ao chamar `null.toFixed(1)`, o React (sem error boundary)
derruba a árvore inteira e a tela vira branca — foi exatamente o que aconteceu assim que
o cliente importou o histórico real (que tem itens assim) e teve algum desses itens
marcado "Recontar", indo pra fila "Aguardando Segunda Contagem".

- **Correção**: as duas linhas de `RecountsPanel` que montavam "Diferença X (Y%)"
  (seções "Aguardando Segunda Contagem" e "Aguardando Análise do Líder") passaram a
  checar `c.percentual==null` separadamente antes de chamar `.toFixed` — se `diferenca`
  existe mas `percentual` não, mostra só a diferença sem o percentual (em vez de tentar
  calcular uma porcentagem que não dá pra saber sem o saldo do sistema).
- Não mexi em `buildRecontarSeedsFromHistorico` — o comportamento de deixar `percentual`
  null quando não há saldo de sistema pra calcular a porcentagem está correto (a planilha
  genuinamente não trouxe saldo pra aquele item); o bug era a suposição errada de quem
  LÊ o dado, não de quem o gera.
- Testado via Playwright reproduzindo o cenário exato (item com `diferenca:-5,
  percentual:null`, mesmo formato que um item real do histórico sem "Sistema" produz):
  antes da correção isso derrubava a tela ao entrar em "Recontagens"; depois, a tela
  carrega normalmente e mostra "Diferença -5" sem percentual.

## Busca em Recontagens, "Itens Divergentes" vira tela própria, "Contagens Concluídas" vira painel de auditoria

Três pedidos do cliente na sequência, todos em cima do fluxo de recontagem/divergência:
(1) campo de busca por código/descrição em "Recontagens", pra achar um item específico sem
rolar a lista inteira; (2) "Itens Divergentes" deixar de mostrar tudo que já teve
divergência e passar a mostrar só o que ainda NÃO entrou em processo de recontagem — some
da lista assim que o item vira "Recontagem"; (3) "Contagens Concluídas" deixar de ser um
atalho pra "Minhas Contagens" e virar um painel de auditoria de verdade, com o ciclo de
vida completo de cada item (todas as rodadas, quem contou, quando, diferença de cada
etapa, quantidade final, se houve ajuste).

### 1. Busca em `RecountsPanel`

Campo de texto no topo (`busca`, mesmo padrão simples já usado em `UserManagementPanel` —
case-insensitive, sem normalização de acento), filtra a fila "Aguardando Segunda
Contagem" por `productCode`/`descricao` em tempo real (é só um `.filter` sobre o array já
carregado, sem chamada de rede). Continua sem precisar de nenhuma ação extra pra abrir a
recontagem — a busca só estreita a lista, o botão "Recontar este item" de cada card
continua fazendo `goto('recount', c)` como sempre.

### 2. `DivergentItemsPanel` — "Itens Divergentes" virou tela própria

A seção "Aguardando Análise do Líder" (itens com `statusAprovacao==='aguardando_analise_
lider'` — divergência real que ainda não foi decidida pelo líder) morava DENTRO de
`RecountsPanel`. Extraída pra um componente próprio, view `'divergentes'`, seguindo o
mesmo padrão já usado antes pra "Endereços Pendentes de Cadastro" (extrair o bloco tal
como está, criar a view, adicionar aos 3 pontos de entrada — Sidebar nav, Sidebar
atalhos, KPI da Home).

- **Regra pedida bate exatamente com o filtro que já existia**: "só mostrar o que ainda
  não entrou em recontagem" é literalmente `statusAprovacao==='aguardando_analise_lider'`
  — assim que o líder clica "Solicitar nova contagem" (ou a regra automática de
  divergência leve já cria o item direto em `aguardando_segunda`), o item sai desse
  status e desaparece da tela sozinho, sem precisar de nenhuma lógica nova.
- **Antes era invisível pro operador por completo** (`{!isOperador && (...)}` escondia a
  seção inteira); agora fica visível pra todos os papéis, só que em modo leitura — as
  ações "Solicitar nova contagem"/"Recontar"/"Aprovar divergência" continuam atrás de
  `canApprove` (líder/admin), operador vê a mesma mensagem que já existia
  ("Aguardando decisão do líder de estoque.") em vez de não ver a tela alguma. Decisão
  consciente: o KPI "Itens Divergentes" na Home é visível a todos os papéis (não é um
  card só de líder/admin), então a tela que ele abre também precisa ser.
- `RecountsPanel` ficou só com "Aguardando Segunda Contagem" — perdeu as props
  `role`/`currentUser`/`onApprove`/`onRequestRecount` (não usa mais nenhuma delas, a
  fila de recontagem em si nunca teve ação restrita por papel).

### 3. `ConcludedCountsPanel` — "Contagens Concluídas" virou painel de auditoria

Antes, o KPI "Contagens Concluídas Hoje" só levava pra `MyCounts` (a mesma tela de
"Minhas Contagens", uma lista plana de contagens individuais). Virou uma tela própria
(view `'concluidas'`), com uma ideia central: **agrupar por CADEIA, não por contagem
individual**. Uma cadeia é a sequência de rodadas do mesmo item ligadas por
`contagemAnteriorId`/`numeroContagem` (1ª contagem → recontagem → recontagem…) — 1 linha
na lista principal representa o ciclo INTEIRO de um item, não cada rodada separada.

- **`buildConcludedChains(counts)`** (helper puro, perto de `getOpenCountForProduct`,
  mesmo raciocínio de "ponta da cadeia" que essa função já usa) — acha toda contagem que
  é PONTA (nenhuma outra aponta pra ela via `contagemAnteriorId`) e que já saiu dos
  status abertos (`!OPEN_STATUSES.includes(...)`, ou seja chegou a um veredito:
  `aprovado_auto`, `aprovado_segunda` ou `aprovado_lider`). A partir da ponta, anda pra
  trás por `contagemAnteriorId` até reconstruir a cadeia completa (mais antiga →  mais
  recente). **100% derivado de campos que a contagem já grava** — nenhuma coluna nova no
  Supabase, nenhum dado novo capturado no fluxo de contagem.
- **"Houve ajuste de estoque"** = a rodada final tem `diferenca!=null && diferenca!==0`
  — é o sinal mais honesto disponível hoje (mesmo critério já usado em `acumuladoAte`/
  `divergentes` no Dashboard). O app não sabe dizer se o ajuste foi de fato lançado no
  Protheus depois — mesma limitação já documentada pro status "Sem Ajuste" no export do
  relatório (`statusLabelPadrao`). Valor do ajuste = `valorDivergente` da rodada final
  (já vem calculado e salvo em cada contagem, sem precisar de conta nova).
- **Lista principal** (cards, mesmo padrão visual do resto do app — não tabela, pra
  continuar funcionando em tablet): código, descrição, `StatusTag` com o status final,
  quantidade final, "N contagens", indicação de ajuste, data. Card inteiro é clicável
  ("Ver histórico completo →"), abre o detalhe.
- **Detalhe** (clique no card, estado local `selecionado` — SEM view/rota nova, é um
  drill-down dentro do mesmo componente): quantidade final validada, total de
  contagens, quantas foram recontagem (`numeroContagem-1`), se houve ajuste + valor,
  seguido da lista de TODAS as rodadas (usuário, data/hora, quantidade, diferença,
  status daquela rodada especificamente — reaproveita `STATUS_INFO`, o mesmo vocabulário
  de status que o resto do app já usa). Botão "← Voltar para a lista" (texto
  deliberadamente diferente do "← Voltar" do `SubBar`, que sempre vai pra Home — os dois
  botões apareceriam juntos na mesma tela e "Voltar" sozinho seria ambíguo sobre qual
  dos dois volta pra onde).
- **Busca por código/descrição** também nessa tela (mesmo padrão do item 1), filtra a
  lista de cadeias.
- **Fora de escopo, decisão consciente**: sem paginação (mesmo critério já aceito em
  `MyCounts`, que também é uma lista cheia sem paginar — se crescer demais, mesmo caminho
  que `UserManagementPanel` já percorreu pode ser aplicado aqui depois). "Classe"/"SA"
  (nº de solicitação de ajuste) continuam de fora, mesma limitação já documentada no
  export do relatório — o app não captura esses dois campos em nenhum lugar do fluxo de
  contagem hoje.

### Home — KPIs atualizados

- **"Itens Divergentes"**: valor mudou de "total cumulativo de divergências até hoje"
  (`hoje.divergentes`, olhando pra TODAS as contagens já feitas) pra
  "quantas estão pendentes agora" (`counts.filter(c=>statusAprovacao==='aguardando_
  analise_lider').length`) — o mesmo número que a tela nova mostra. Como isso é estado
  atual (não cumulativo), a tendência virou nota contextual ("Requer atenção"/"Nenhuma
  pendência"), mesmo padrão já usado em "Recontagens Pendentes" — não dá pra calcular
  uma variação percentual real sem um histórico de snapshot que o app não guarda (mesmo
  critério já documentado em "KPIs — só dado real, nada fabricado").
- **"Contagens Concluídas Hoje"**: só trocou o destino do clique (`goto('concluidas')`
  em vez de `goto('myCounts')`) — o número em si continua sendo "quantas contagens
  foram registradas hoje" (não mudou pra "quantas cadeias fecharam hoje", pra não misturar
  dois conceitos diferentes no mesmo KPI).

### Sidebar

Dois itens novos (`divergentes`/`ic:'alertTriangle'`, `concluidas`/`ic:'checkCircle'` —
mesmos ícones já usados nos KPIs correspondentes) entre "Recontagens" e "Minhas
Contagens". "Itens Divergentes" também entrou nos atalhos rápidos (mesmo grupo de
"Recontagens pendentes"); "Contagens Concluídas" ficou de fora dos atalhos — é mais uma
tela de referência/auditoria do que uma ação rápida do dia a dia, mesmo critério que já
deixa "Indicadores"/"Relatórios"/"Configurações" fora dos atalhos hoje.

- Testado via Playwright (sandbox sem rede): busca em Recontagens filtra por código e por
  descrição, mostra empty-state específico quando não acha nada; "Itens Divergentes"
  mostra o item pendente pros 3 papéis mas só líder/admin veem os botões de ação
  (operador vê "Aguardando decisão do líder de estoque"); item sai de "Itens Divergentes"
  e passa a aparecer em "Recontagens" assim que "Solicitar nova contagem" é confirmado;
  "Contagens Concluídas" mostra só cadeias resolvidas (não mostra itens ainda pendentes),
  agrupa corretamente uma cadeia de 2 rodadas numa linha só, abre o detalhe com as duas
  rodadas (usuários, diferenças, status de cada etapa), calcula "Recontagens Realizadas"
  e valor do ajuste corretamente, e "Voltar para a lista" funciona sem se confundir com o
  "Voltar" do `SubBar`. Os dois KPIs da Home levam pra tela nova certa. Rodei de novo toda
  a suíte de regressão já existente no scratchpad — precisou só atualizar alguns testes
  antigos que navegavam pra "Recontagens" esperando encontrar o que agora mora em "Itens
  Divergentes" (mudança esperada da extração, não regressão).

## Histórico importado passa a alimentar "Contagens Concluídas" e a Acuracidade do Estoque

Depois da reestruturação acima, o cliente reportou que "não estou encontrando os itens já
concluídos" e "os indicadores também não estão atualizando" — não era bug de
sincronização: `contagens_historico` (onde a planilha de análise antiga é importada, ver
seção "Padrão de planilha do cliente") sempre foi só uma tabela de consulta/relatório —
só os itens marcados "Recontar" (116 de 3.659 no arquivo real) eram replicados pra
`contagens`, a tabela viva que alimenta o resto do app. Os outros ~3.543 itens já
resolvidos na planilha antiga ("OK"/"Sem Ajuste"/"Ajustado"/"Ajustar") nunca tinham sido
gravados na tabela viva — ficavam invisíveis pra "Contagens Concluídas" e pros
indicadores, que só liam `contagens`. Confirmado com o cliente via `AskUserQuestion`: ele
escolheu incluir o histórico tanto no painel de auditoria quanto nos indicadores gerais
(a opção recomendada, entre "manter só como consulta separada" e "só nos indicadores").

- **`fetchContagensHistoricoConcluidas()`** (perto de `fetchUltimaImportacaoHistorico`)
  — busca só os status já CONCLUÍDOS na planilha (`status in ('OK','Sem Ajuste',
  'Ajustado','Ajustar')`), excluindo de propósito "Recontar" (já vem pela rota separada
  de sempre, incluir aqui duplicaria) e "Pendente" (fora de escopo por enquanto — decisão
  consciente, não foi pedido explicitamente e mistura com a semântica de "Itens
  Divergentes" mereceria pensar com mais calma antes). Sem paginação de verdade
  (`.limit(10000)`), mesmo tipo de limitação já aceita em `fetchContagensFromSupabase`.
  RLS já permitia leitura pública nessa tabela desde que foi criada — nenhuma mudança de
  schema/policy foi necessária, só front-end.
- **`historicoRowToConcludedChain(h)`** (perto de `buildConcludedChains`) — converte uma
  linha crua de `contagens_historico` no MESMO formato `{chaveId, tip, rodadas,
  houveAjuste}` que `buildConcludedChains` já produz pras cadeias ao vivo, pra aparecerem
  lado a lado em `ConcludedCountsPanel`. Como a planilha antiga não guarda a sequência de
  rodadas (1ª contagem → recontagem → …), cada linha vira uma cadeia de 1 rodada só, com
  `usuario:'Importação Histórica'` (mesma convenção já usada em
  `buildRecontarSeedsFromHistorico`, já que a planilha não registra quem contou) e
  `statusAprovacao: null` — sem equivalente 1:1 no vocabulário do app (5 estados) pro da
  planilha (6 estados via `status`), então o rótulo/cor de cada card vem de um campo novo,
  `_statusDisplay` (`{level, text}`), com `ConcludedCountsPanel` preferindo
  `tip._statusDisplay || STATUS_INFO[tip.statusAprovacao]` nos 3 pontos que mostravam
  status (lista, cabeçalho do detalhe, cada rodada do detalhe).
  - **Bug pego no teste antes de subir**: a primeira versão calculava `houveAjuste` pro
    histórico com o MESMO fallback já usado nas cadeias ao vivo (`diferenca!==0`) quando
    o status não era "Ajustado"/"Ajustar" — mas "Sem Ajuste" pode genuinamente ter uma
    diferença pequena registrada (dentro da tolerância, por isso não precisou ajustar) e
    esse fallback sobrescrevia errado pra "Ajuste necessário", contradizendo o que a
    própria planilha já afirmava. Corrigido pra usar só o `status` da planilha
    (`'Ajustado'||'Ajustar'`) sem nenhum fallback — a fonte já é explícita, diferente do
    caso das cadeias ao vivo (que precisam inferir por falta de um campo assim).
  - Cards de item vindo do histórico ganham uma tag discreta "· histórico importado" no
    cabeçalho (`tip._fromHistorico`), pra não parecer uma contagem feita ao vivo no app.
- **Acuracidade do Estoque (Home)**: `acumuladoAte(dataLimite)` passou a somar
  `[...counts, ...historicoConcluidas]` antes de filtrar por data — os dois arrays já
  usam os mesmos nomes de campo (`data`/`diferenca`), sem precisar de conversão. Sem essa
  mudança, o KPI ficava artificialmente 100%/vazio logo depois de um reset, ignorando os
  milhares de contagens já resolvidas na Selgron antes do Inventário 360 existir.
  **"Contagens Concluídas Hoje" e "Itens Divergentes" continuam só com dado ao vivo**,
  de propósito — misturar datas antigas da planilha (fev-jul/2026) num KPI rotulado
  "Hoje" distorceria o que ele significa, e "Pendente" do histórico ficou fora de escopo
  (ver acima).
- **Busca única por login, não no ciclo de 30s**: `historicoConcluidas` é buscado uma vez
  em `App()` quando `currentUser` muda (login), não entra no `sync()` recorrente — o
  histórico só muda quando alguém reimporta a planilha manualmente em Configurações, não
  em tempo real, e o payload (milhares de linhas) é grande de mais pra repetir a cada
  30s. **`HistoricoImportPanel` ganhou a prop `onImported`** (passada de `App()` via
  `Settings`), chamada no fim de `handleConfirmar` — assim quem já está logado vê o
  resultado atualizado em "Contagens Concluídas"/Indicadores na hora, sem precisar
  recarregar a página.
- Testado via Playwright (sandbox sem rede, `contagens_historico` mockada com uma linha
  de cada status concluído): confirmei a query filtra só os 4 status certos (`status=in.
  (...)`), que os 4 status aparecem com o rótulo/cor certos na lista e no detalhe
  (inclusive o bug do "Sem Ajuste" com diferença não-zero corrigido), que a Acuracidade
  do Estoque deixa de mostrar 100% quando há divergência no histórico, e — ponta a ponta
  — que subir uma planilha nova em Configurações atualiza "Contagens Concluídas" na
  mesma sessão, sem reload. Rodei de novo toda a suíte de regressão do scratchpad, sem
  quebrar nada.

## "Indicadores" ainda vazio + histórico ganha todos os campos pra auditoria

Depois do passo anterior, o cliente reportou que "os indicadores estão vazios ainda" e
pediu explicitamente pra incluir a data de cada contagem no histórico, "imagine que um
dia bata uma auditoria, preciso de toda informação necessária ali". Dois problemas
distintos, investigados e corrigidos juntos:

**1. "Indicadores" (a tela, `Dashboard`/`view==='dashboard'`) nunca tinha sido conectada
ao histórico** — só a Home (`view==='home'`, a tela que abre após login, com o card
"Acuracidade do Estoque") tinha sido ajustada no passo anterior. "Indicadores" é uma
tela SEPARADA (Operação/Estoque/Qualidade/Tendência Semanal/Produtividade/Top
Divergências), inteiramente calculada a partir de `counts` (contagens ao vivo) — sem
histórico, com pouca atividade recente ela aparece quase vazia por completo: several
seções (`Tendência Semanal`, `Produtividade por Operador`, `Principais Causas de Erro`)
nem renderizavam, escondidas por `length>0` guards.
- **`Dashboard` passou a receber `historicoConcluidas`** (mesmo dado já buscado em
  `App()`) e monta `todasParaQualidade = [...counts, ...historicoComoContagem]`
  (`historicoComoContagem` via `historicoRowToCountLike`, ver item 3 abaixo) — usado só
  em **"Qualidade"** (Acuracidade/Divergências/Valor Divergente), **"Principais Causas de
  Erro"** e **"Top Itens com Maior Divergência"**.
- **Deliberadamente FORA do merge**: "Itens Planejados/Contados/Pendentes" (progresso de
  inventário em andamento — conceito sobre a operação ATUAL, misturar com histórico de
  meses atrás não faz sentido), "Produtividade por Operador" (histórico não tem operador
  real por trás de cada linha, só `usuario:'Importação Histórica'` — incluir inflaria um
  "operador" fictício no ranking) e "Tendência Semanal" (histórico concentrado numa
  importação em massa criaria um pico artificial numa única semana, mais confuso que
  útil). Mesmo critério de "não misturar conceitos diferentes" já usado nos KPIs da Home.

**2. Filtro de status na busca do histórico não era resistente a formatação suja** — a
correção anterior usava `.in('status', ['OK','Sem Ajuste','Ajustado','Ajustar'])` no
PostgREST, uma comparação EXATA no servidor. Se uma linha já importada tivesse espaço
sobrando no valor (`"OK "` em vez de `"OK"` — a planilha real já mostrou mais de uma vez
ter esse tipo de sujeira, ver "Bug real no upload da SB2: valor sempre zerado"), o filtro
excluía a linha silenciosamente, sem erro nenhum — mesma categoria de bug silencioso já
vista com RLS bloqueando `produtos` sem aviso.
- **`fetchContagensHistoricoConcluidas()`** trocou o filtro `.in()` do servidor por um
  `.filter()` no cliente comparando `String(row.status||'').trim()` contra
  `HISTORICO_STATUS_CONCLUIDOS` — cobre tanto dado legado sujo quanto dado novo já limpo,
  sem precisar tocar no banco pra corrigir linhas antigas.
- **`parseHistoricoContagensRows`** (o parser que roda no UPLOAD) ganhou um helper `txt(v)`
  que aplica `.trim()` em TODOS os campos de texto (status, classe, causa, observação, SA,
  documento, endereço — antes só `produto_codigo`/`descrição` eram tratados) — fecha o
  ciclo pra reimportações futuras não repetirem o mesmo problema.

**3. Histórico ganhou TODOS os campos disponíveis, não só um resumo** — pedido explícito
do cliente. `historicoRowToConcludedChain` foi dividida em duas funções:
`historicoRowToCountLike(h)` (novo, retorna o objeto "contagem" completo, reutilizável em
qualquer lugar que já sabe ler `counts` — Dashboard incluso, ver item 1) +
`historicoRowToConcludedChain(h)` (agora só embrulha o resultado no formato de cadeia).
`historicoRowToCountLike` carrega **endereço**, **observação**, e os campos que só a
planilha antiga tem e a contagem ao vivo do app não — **classe (ABC)**, **SA (nº da
solicitação de ajuste no Protheus)**, **documento**, **dias sem movimento**.
- **`ConcludedCountsPanel`**: o resumo da cadeia (topo do detalhe) ganhou o campo
  "Endereço". Os cards de rodada foram reestruturados de spans soltos pra um
  `result-grid` com Usuário/Endereço/Saldo Sistema/Qtd. Contada/Diferença/Valor
  Divergente, seguido de Motivo/Observação quando presentes, e — só pra linhas vindas do
  histórico — uma linha extra com Classe ABC/SA/Doc/Dias s/ movimento quando a planilha
  trouxe esse dado.
- **Data sempre explícita, nunca some em silêncio**: tanto no card da lista quanto no
  detalhe, uma linha sem `data` (a planilha antiga tem ~460 dessas, campo genuinamente
  vazio na origem) mostra "Sem data registrada"/"Data não registrada na planilha" em vez
  de deixar um espaço em branco — importante justamente pro caso de auditoria que o
  cliente citou: fica claro que a AUSÊNCIA de data é um dado real da planilha original,
  não uma falha de exibição do app.
- Testado via Playwright com dado "sujo" de propósito (`status: 'Ajustar '` com espaço,
  `status: ' OK'` com espaço líder) pra confirmar o filtro client-side reconhece os dois;
  confirmei que o detalhe mostra endereço/saldo sistema/valor divergente/motivo/
  observação/classe/SA/documento/dias sem movimento todos juntos pra uma linha completa
  do histórico; que uma linha sem data mostra o aviso explícito em vez de ficar em
  branco, tanto na lista quanto no detalhe; e que "Indicadores" (Qualidade, Principais
  Causas de Erro, Top Itens com Maior Divergência) passa a refletir o histórico
  importado, com a Acuracidade do Estoque deixando de aparecer 100% artificial. Rodei de
  novo toda a suíte de regressão do scratchpad, sem quebrar nada.

## Bug real na Acuracidade Semanal + janela fixa das últimas 10 semanas

Cliente mandou print de "Tendência Semanal" (em Indicadores): só 3 semanas apareciam no
eixo, e a Acuracidade Semanal mostrava **0% nas três**, mesmo com 24/91/1 contagens
registradas — claramente errado (contagens acontecendo, mas "acuracidade zero" em toda
semana). Pediu pra sempre mostrar as últimas 10 semanas nos dois gráficos.

- **Causa do 0%**: `computeWeeklyStats` calculava divergência com
  `if(c.diferenca !== 0) buckets[key].divergentes += 1` — sem excluir `diferenca===null`
  (item sem saldo local pra comparar, ver `hasSaldoLocal`/`CountStep`). Como `null !== 0`
  é `true` em JS, TODO item sem saldo contava como "divergente", e como boa parte das
  contagens reais do cliente vem de itens fora do catálogo local ou sem saldo carregado
  ainda, praticamente qualquer semana com um desses itens despencava pra acuracidade
  perto de zero — mesmo tipo de bug (`diferenca!==0` sem checar `null`) já corrigido
  antes em outros lugares (`Home.acumuladoAte`), mas que continuava presente aqui, sem
  ninguém ter notado até esse gráfico específico.
- **Causa das só-3-semanas**: `computeWeeklyStats` só criava um "bucket" pra semana que
  já tinha pelo menos 1 contagem (`Object.values(buckets)...slice(-maxWeeks)`) — com
  atividade recente/esparsa, aparecem só as semanas que tiveram contagem de verdade, não
  uma janela fixa de tempo.
- **Correção**: `computeWeeklyStats(counts, maxWeeks)` agora gera as `maxWeeks` semanas
  civis terminando HOJE de antemão (zero-preenchidas), e só depois soma as contagens reais
  em cima disso — sempre retorna exatamente `maxWeeks` semanas, mesmo sem nenhuma
  contagem. Chamada trocada de `computeWeeklyStats(counts, 8)` pra
  `computeWeeklyStats(counts, 10)` (pedido do cliente). O guard
  `{weeklyStats.length>0 && (...)}` que escondia a seção inteira virou sempre-visível
  (a função nunca mais retorna array vazio).
- **Semana sem contagem nenhuma vira `acuracidade:null`, não `0`** — 0% seria enganoso
  (pareceria "semana péssima" em vez de "sem dado nenhum"). `WeeklyLineChart` trata isso
  como um buraco de verdade: quebra a linha/área em segmentos contínuos de semanas COM
  dado (em vez de um `<polyline>` só cobrindo tudo), desenha um pontinho apagado
  (`opacity:0.5`, sem % nem inclui na média) nas semanas vazias, e a média tracejada
  (`avg`) considera só as semanas com dado real. `WeeklyCountChart` (o de barras) não
  precisou de mudança — barra de altura 0 pra semana vazia já é o comportamento certo,
  sem ambiguidade.
- Testado via Playwright (sandbox sem rede, 3 contagens seedadas: 2 na semana atual —
  uma com saldo batendo, outra `diferenca:null` por estar fora do cache — e 1 divergente
  de verdade 5 semanas atrás): confirmei que o eixo sempre mostra exatamente 10 rótulos
  "Sem NN" nos dois gráficos; que a semana atual mostra 100.0% (o item sem saldo não
  conta mais como divergência); que a semana com divergência real mostra 0.0% (única
  contagem daquela semana, e ela erra); e que as 8 semanas sem nenhuma contagem aparecem
  como "sem contagens" no gráfico, não como um 0% escondido no meio da linha. Rodei de
  novo toda a suíte de regressão do scratchpad, sem quebrar nada.

## "Tendência Semanal" passa a somar histórico + meta de contagem fixa

Cliente esclareceu o que os dois gráficos de "Tendência Semanal" deveriam representar:
"Contagens na Semana" = quantidade de itens contados TOTAL (meta de 250/semana),
"Acuracidade Semanal" = acuracidade de TODOS os itens contados naquela semana — nos dois
casos, contando tudo (ao vivo no app + histórico importado), não só o que foi contado
dentro do Inventário 360. Perguntou por que estava "puxando zerado" com dado real na
planilha `BD_Contagens`.

- **Decisão anterior revista**: a seção "Bug crítico: tela de Recontagens..." e depois
  "'Indicadores' ainda vazio..." tinham decidido deixar `weeklyStats` de fora do merge
  com o histórico, com a justificativa de que "histórico concentrado numa importação em
  massa criaria um pico artificial numa única semana". Essa suposição estava ERRADA: cada
  linha da planilha carrega a **data real em que a contagem aconteceu** (fev-jul/2026),
  não a data em que foi importada — soma exatamente na semana certa, igual a qualquer
  contagem ao vivo, sem criar pico nenhum. `computeWeeklyStats(counts, 10)` virou
  `computeWeeklyStats(todasParaQualidade, 10)` — reaproveita o mesmo pool já usado pra
  Qualidade/Causas de Erro/Top Divergências (contagens ao vivo + histórico concluído, sem
  duplicar os itens "Recontar" que já entram via `counts`).
- **`META_CONTAGENS_SEMANAL = 250`** (constante isolada perto de `WeeklyCountChart`) —
  linha de referência fixa no gráfico de contagens, com rótulo "Meta: 250" visível.
  Substituiu a linha tracejada anterior que mostrava a MÉDIA das semanas exibidas (não
  representava nenhum objetivo real, só mudava conforme a janela de tempo). O eixo Y
  (`niceAxisTicks`) passou a considerar a meta no cálculo do teto, pra linha continuar
  visível mesmo em semanas bem abaixo de 250.
- Testado via Playwright com histórico mockado espalhado em semanas SEM nenhuma contagem
  ao vivo (única forma de confirmar que o merge está funcionando de verdade, e não só
  reaproveitando dado que já existia): confirmei que essas semanas passam a mostrar
  contagem/acuracidade reais vindos só do histórico, e que "Meta: 250" aparece no
  gráfico. Rodei de novo a suíte de regressão do scratchpad, sem quebrar nada.

## Meta de 95% na Acuracidade Semanal + acuracidade contínua + "Pendente" entra no volume

Cliente ajustou o pedido anterior depois de ver o resultado: (1) "Acuracidade Semanal"
precisa de uma meta de 95% (mesmo padrão do "Meta: 250" já adicionado em "Contagens na
Semana"), e os pontos do gráfico representam a MÉDIA de acuracidade das contagens da
semana — não a taxa binária de acerto exato que o app usa em todo o resto dos
indicadores; (2) "Contagens na Semana" ainda aparecia com menos dado do que deveria,
"visto que fazemos contagens diariamente" — apontando que ainda faltava informação
mesmo depois do histórico ter entrado nos indicadores.

- **`itemAcuracidade(c)`** (helper novo, perto de `computeWeeklyStats`) — usa o campo
  `acuracidade` já calculado pela própria planilha quando a contagem vem do histórico
  (0 a 1, mesma fórmula `max(0, 1-|diferença|/sistema)` documentada em "Padrão de
  planilha do cliente"), ou calcula na hora com a MESMA fórmula em cima de
  `diferenca`/`saldoSistema` pra contagem ao vivo do app. `computeWeeklyStats` passou a
  somar essa acuracidade contínua por item e tirar a média por semana, em vez do %
  binário de "quantos bateram exato" (`(total-divergentes)/total`) usado até agora.
  **Os dois convivem no mesmo app de propósito**: a "Qualidade"/"Acuracidade do
  Estoque" (Home) continuam com a taxa binária — o cliente não pediu mudança ali, só no
  gráfico semanal, que responde a uma pergunta diferente ("o quão perto, em média, a
  gente chega" vs. "quantos bateram 100%").
- **`META_ACURACIDADE_SEMANAL = 95`** (perto de `WeeklyLineChart`, mesmo padrão do
  `META_CONTAGENS_SEMANAL` já existente) — substitui a linha tracejada de média por uma
  meta fixa com rótulo "Meta: 95%".
- **`fetchContagensHistoricoParaTendencia()`** (nova, perto de
  `fetchContagensHistoricoConcluidas`) — causa real do "ainda falta dado": o histórico
  usado pelos gráficos semanais só incluía os 4 status já CONCLUÍDOS
  (`HISTORICO_STATUS_CONCLUIDOS`), excluindo "Pendente" (ainda aguardando decisão do
  líder) — mas pra fins de VOLUME/acuracidade semanal, um item pendente É uma contagem
  real que já aconteceu naquele dia, só ainda sem veredito. Essa busca nova traz TUDO
  menos "Recontar" (que já está representado em `counts` via
  `buildRecontarSeedsFromHistorico` — incluir de novo aqui duplicaria). Estado novo em
  `App()`, `historicoParaTendencia`, buscado junto com `historicoConcluidas` no mesmo
  `refreshHistoricoConcluidas()` (login + após reimportação) — só passado pra `Dashboard`,
  as outras telas (`ConcludedCountsPanel`, Home) continuam usando só `historicoConcluidas`
  (concluído), que não mudou de comportamento.
- Testado via Playwright: confirmei que "Meta: 95%" aparece; que um item histórico com
  `status:'Pendente'` passa a contar no volume semanal (antes ficava de fora); que um
  item histórico com `status:'Recontar'` continua de fora daqui (evita duplicar com o que
  já vem de `counts`); e que a acuracidade agora é contínua (ex: item com diferença de
  7 num saldo de 15 mostra 53,3%, não 0% como a taxa binária mostraria). Dois testes
  antigos (`verify_weekly_trend_fix.js`/`verify_weekly_historico_meta.js`) tinham
  asserção pra taxa binária antiga — atualizados pra esperar o valor contínuo certo
  (mudança de comportamento intencional, não regressão). Rodei de novo toda a suíte de
  regressão do scratchpad, sem quebrar nada.

## Navegação sobrevive a recarregar a página + filtro de período na Tendência Semanal

Dois pedidos do cliente na sequência do ajuste anterior: (1) recarregar a página estava
jogando de volta pra Home — igual ao problema já resolvido antes pra sessão de login
("Sessão de login sobrevive a recarregar a página"), só que dessa vez com a navegação em
si; (2) questionou se os gráficos de "Tendência Semanal" realmente consideravam TODAS as
contagens — investigado e confirmado: a janela fixa de 10 semanas (pedido de uma rodada
anterior) corta a maior parte do histórico importado, já que `BD_Contagens` cobre
fev-jul/2026 (~22-26 semanas). Perguntado via `AskUserQuestion` entre manter fixo, ampliar
pra sempre mostrar tudo, ou deixar o cliente escolher — ele escolheu poder escolher.

- **`view`/`flowState` viraram `usePersistedState`** (eram `useState` puro) — mesmo
  mecanismo já usado pro resto do estado do app, sem nada novo. `flowState` sempre foi um
  objeto simples (o inventário sendo contado, a contagem original de uma recontagem, os
  parâmetros de edição de usuário) — serializa em JSON sem problema, não tem função nem
  referência a DOM. `logout()` já forçava `view:'home'`/`flowState:null` antes disso (pra
  limpar a sessão) — isso continua valendo, então trocar de usuário no mesmo aparelho
  nunca "vaza" a tela de um pro outro, mesmo com a navegação agora persistindo.
- **Filtro de período em "Tendência Semanal"** (`weeklyPeriod`, estado local do
  `Dashboard` — não precisa ser global, só essa seção usa): `<select className="pnl-
  period-select">` no canto direito do título da seção (mesmo componente visual já usado
  no filtro de período da Home), com 3 opções — "Últimas 10 semanas" (padrão, mesmo
  comportamento de antes), "Últimas 26 semanas", "Todo o período" (calcula quantas
  semanas cabem da contagem mais antiga do pool até hoje, em vez de um número fixo — só
  assim as 3.659 linhas de `BD_Contagens` aparecem inteiras nos dois gráficos). Só afeta
  `computeWeeklyStats` — nenhuma outra parte do Dashboard/Home muda.
- **Trade-off assumido, não escondido**: com "Todo o período" (pode passar de 20 semanas),
  o gráfico fica mais compacto por semana (mesma largura fixa de 760px dividida por mais
  pontos) — mencionado explicitamente na pergunta feita ao cliente antes de implementar,
  pra ele decidir com essa informação em mãos.
- Testado via Playwright: reload numa tela diferente de Home mantém na mesma tela (não
  cai mais no login nem na Home); logout continua limpando `view`/`flowState` normalmente,
  e um login novo (usuário diferente) cai na Home, não onde o usuário anterior tinha
  parado; um item de histórico com 200 dias de idade fica de fora com "Últimas 10
  semanas" mas aparece com "Todo o período" (30 semanas no eixo nesse teste). Rodei de
  novo toda a suíte de regressão do scratchpad, sem quebrar nada.

## Bug real de causa raiz: teto de linhas do Supabase cortava semanas inteiras do histórico

Cliente questionou diretamente ("quer me dizer que nas semanas 23, 24 e 25 eu não tenho
nenhuma contagem feita??") depois de ver essas 3 semanas aparecerem vazias em "Tendência
Semanal" mesmo com a planilha `BD_Contagens` cheia de dado real. Pedi uma consulta SQL
direta (`select status, count(*) from contagens_historico group by status`) pra descartar
hipóteses — voltou 2.574+452+433+81+77+41 = **3.658**, batendo exatamente com o total
esperado da importação. Isso por si só não provava nada (uma consulta `count()`/`group by`
é uma AGREGAÇÃO — o Postgres calcula o resultado inteiro no servidor e devolve só o
número final, então ela NUNCA é afetada por um teto de linhas retornadas). O bug real
estava em `select *` (linhas de verdade, o que o app de fato busca).

- **Causa raiz confirmada**: todo projeto Supabase tem um limite de linhas por
  requisição configurado no PostgREST (Settings → API → Max Rows, geralmente 1000 por
  padrão) — e esse limite é aplicado **silenciosamente**: um `.limit(10000)` pedido pelo
  client nunca é honrado se o projeto está configurado pra um teto menor, e a resposta
  não vem com erro nenhum, só menos linhas do que existem. Mesma categoria de bug
  silencioso já vista antes neste projeto (RLS bloqueando `produtos` sem aviso, a coluna
  "Sld.Atu." com espaço quebrando o parser da SB2) — sempre que um número "bate" mas o
  outro não, vale suspeitar de um corte silencioso em algum nível.
- **`fetchTodasPaginado(buildQuery)`** (helper novo, perto de `fetchContagensFromSupabase`)
  — pagina com `.range(offset, offset+999)` em loop até uma página vir vazia ou menor que
  1000 linhas, não importa quantas existam ao todo nem qual teto o projeto tenha
  configurado. `buildQuery` é uma FUNÇÃO (não um builder já pronto) porque um query
  builder do supabase-js só pode ser executado (`await`) uma vez — cada iteração do loop
  monta um builder novo a partir do zero.
  - **Ordenação com tiebreaker (`id`) obrigatória**: paginar só por `data`/`criado_em`
    (colunas com muitos valores repetidos — vários registros no mesmo dia/timestamp) sem
    um desempate estável faz o Postgres devolver as linhas em ordem não-determinística
    entre uma página e outra, arriscando pular ou duplicar linhas exatamente na fronteira
    de duas páginas. Adicionado `.order('id', {ascending:true})` como segundo critério em
    TODAS as buscas paginadas — não precisa ter significado (é só desempate), só precisa
    ser único e estável.
- **As três buscas que liam a tabela inteira migraram pra paginação**:
  `fetchContagensFromSupabase` (contagens ao vivo, tinha `.limit(2000)`),
  `fetchContagensHistoricoConcluidas` e `fetchContagensHistoricoParaTendencia` (tinham
  `.limit(10000)`) — nenhuma das três depende mais de nenhum teto, nem no código nem no
  projeto Supabase, cliente pediu explicitamente "não quero que tenha limites".
- Testado via Playwright simulando o cenário exato do bug real: 2.500 linhas mockadas +
  um servidor mock que IGNORA o `limit` pedido pelo client e sempre corta em 1.000 por
  resposta (reproduzindo fielmente o comportamento real de um projeto Supabase com Max
  Rows configurado) — confirmei que `fetchTodasPaginado` faz 3 requisições
  (offset 0/1000/2000) e recupera as 2.500 linhas completas, incluindo um item que só
  existe na última página. Rodei de novo toda a suíte de regressão do scratchpad, sem
  quebrar nada.
- **Ainda não confirmado contra o Supabase real** — falta o cliente recarregar o app e
  conferir se as semanas 23-25 (e o resto do histórico) aparecem agora em "Tendência
  Semanal" com "Todo o período" selecionado.

## Metas sobrepostas nos gráficos, período personalizável e gráfico de acuracidade mensal

Depois da correção da paginação, o cliente confirmou que os dados voltaram a aparecer
("a principio deu certo") e trouxe três pedidos novos sobre a mesma seção de
Indicadores: (1) as etiquetas "Meta: X" dentro dos dois gráficos semanais estavam se
sobrepondo aos rótulos dos pontos de dado; (2) o filtro de período (antes só
10/26 semanas/"todo o período") devia ficar "mais personalizável, caso me peçam algum
período específico"; (3) um terceiro gráfico, do mesmo tamanho dos outros dois, com
acuracidade **mensal** (também com meta de 95%).

- **Causa da sobreposição**: `WeeklyLineChart`/`WeeklyCountChart` desenhavam o texto
  "Meta: X" DENTRO do próprio SVG, ancorado no canto superior direito
  (`x={W-padR}, y={y(meta)-6}`) — exatamente o mesmo canto onde o rótulo do último ponto
  de dado aparece quando a semana mais recente tem acuracidade alta (perto de 100%, ou
  seja perto do topo do gráfico). Não tinha como os dois nunca coincidirem sem
  depender do valor real dos dados a cada semana.
- **Correção**: o rótulo "Meta: X" saiu do SVG por completo e virou um badge HTML no
  cabeçalho do painel (`.chart-meta-badge`, pill pequeno com fundo teal claro), ao lado
  do título do gráfico (ex.: "Acuracidade Semanal (%)　Meta: 95%"). Como não depende
  mais de nenhuma coordenada calculada a partir dos dados, é estruturalmente impossível
  esse rótulo colidir com um ponto do gráfico de novo. A linha tracejada de referência
  continua dentro do SVG (agora só a linha, sem texto — ganhou um `<title>` como
  tooltip acessível).
- **`WeeklyLineChart`/`WeeklyCountChart` ganharam uma prop `meta`** (com o valor de
  `META_ACURACIDADE_SEMANAL`/`META_CONTAGENS_SEMANAL` como default, pra não quebrar
  quem já chamava sem passar a prop) — isso é o que permite reaproveitar
  `WeeklyLineChart` pro gráfico mensal novo, só passando `weeks={monthlyStats}` em vez
  de `weeks={weeklyStats}` (o componente não sabe nem precisa saber se cada "semana"
  do array é na verdade um mês — só usa `label`/`sublabel`/`total`/`acuracidade` de
  cada item, que `computeMonthlyStats` já produz no mesmo formato).
- **`computeWeeklyStats`/`computeMonthlyStats` trocaram de assinatura**: de
  `(counts, maxWeeks/maxMonths)` (janela fixa terminando "hoje") para
  `(counts, dataInicioStr, dataFimStr)` — intervalo de data explícito. Cada função gera
  todos os baldes (semana ou mês) entre o início e o fim informados (zero-preenchidos,
  com guarda de 300/120 iterações), depois soma as contagens reais que caem em cada
  balde. `getMonthInfo(dataStr)` é o par de `getWeekInfo` pra mês (`{key:'YYYY-MM',
  label:'Jul', sublabel:'2026'}`, via `NOMES_MESES`).
- **Período personalizável**: o `<select>` de período (10/26 semanas, todo o período)
  ganhou uma 4ª opção, "Período personalizado…", que revela dois `<input type="date">`
  (`.pnl-date-input`, mesmo estilo visual do `.pnl-period-select`) — `weeklyCustomFrom`/
  `weeklyCustomTo` em `Dashboard`. As 4 opções convergem pro mesmo par
  `dataInicioStr`/`dataFimStr` que alimenta os três gráficos (os dois semanais e o
  mensal novo) — não existe mais um cálculo separado de "quantas semanas cabem", só um
  intervalo de data, calculado a partir de "hoje - N×7 dias" pras opções fixas, do
  registro mais antigo do pool até hoje pra "todo o período", ou direto dos dois campos
  pra "personalizado" (com proteção contra data final antes da inicial, e `max`/`min`
  nos próprios campos pra a UI já impedir isso na maioria dos casos).
- **Terceiro gráfico "Acuracidade Mensal (%)"**: mesmo `weekly-charts-grid` (grid de 2
  colunas em telas ≥900px) dos outros dois — como são 3 itens num grid de 2 colunas, o
  terceiro cai sozinho na segunda linha (mesmo tamanho dos outros dois, só com uma
  lacuna vazia ao lado, aceito como trade-off simples em vez de criar um grid
  específico só pra esse caso). Reaproveita o MESMO pool de dados (`poolTendencia`,
  contagens ao vivo + histórico "para tendência") e o MESMO intervalo de data dos
  gráficos semanais — não é um filtro independente.
- **Título da seção**: "Tendência Semanal" virou só "Tendência" (agora cobre semanal E
  mensal).
- Testado via Playwright: com dado sintético de ~22 semanas (fev-jul/2026, acuracidade
  sempre 98-100%, o cenário onde a sobreposição era mais provável) — confirmei que os 3
  badges de meta aparecem no cabeçalho dos painéis (fora do SVG, `.chart-meta-badge`) e
  que nenhum `<text>` com "Meta" existe mais dentro de nenhum SVG; que trocar pra
  "Todo o período" não quebra nada; que selecionar "Período personalizado" revela os 2
  campos de data e que preencher março/2026 faz o gráfico semanal mostrar só as
  semanas de março (Sem 9-14) e o gráfico mensal mostrar só 1 balde ("Mar 2026");
  conferi visualmente por screenshot que os rótulos "99%"/"100%" dos pontos de dado não
  colidem mais com o badge "Meta: 95%" em nenhum dos três gráficos. Rodei de novo os
  testes de regressão da seção de Indicadores (`verify_weekly_*`,
  `verify_view_persist_period_filter`, `verify_dashboard_recount`, `verify_home_kpis`)
  — precisou só atualizar 4 scripts antigos que checavam o texto "Meta: X" dentro do
  SVG ou o título "Tendência Semanal" (mudanças de UI intencionais desta rodada, não
  regressão) para apontar pro badge/título novos.

## Filtro de período profissional (segmented control) + gráfico mensal em colunas, ano corrente

Feedback do cliente depois de ver a rodada anterior (metas em badge, filtro de período,
gráfico mensal novo): o `<select>` do filtro de período era pouco descobrível ("filtro de
data não aparece") e pedia algo "mais profissional"; o gráfico "Acuracidade Mensal" devia
ser em **colunas** (era o mesmo `WeeklyLineChart` de linha reaproveitado) e **mostrar
todos os meses com dados do ano**, não só os poucos meses cobertos pela janela de "10
semanas" (padrão do filtro semanal, ~2-3 meses); e faltava mais espaçamento entre o eixo
Y (0-100%) e o topo do gráfico/badge de meta, que ficavam "muito em cima".

- **Filtro de período virou um `.pnl-segmented`** (grupo de botões pill, fundo navy no
  ativo) em vez do `<select>` — mesmas 4 opções de sempre (10/26 semanas, todo o período,
  personalizado), só muda a forma de escolher: clique direto no botão em vez de abrir um
  dropdown. Quando "Personalizado" fica ativo, aparece ao lado um **widget de intervalo de
  datas** (`.pnl-daterange`) com ícone de calendário (`CalendarIcon`, SVG linear desenhado
  à mão — não usa `DICON_PATHS` porque esse conjunto é reservado pra sidebar/header/
  Dashboard, mas esse toolbar específico já tomava emprestada a paleta/tipografia corp do
  `.pnl-period-select` antes desta mudança, então um ícone linear combina mais que emoji
  aqui) e labels explícitos "De"/"Até" ao lado de cada campo — mais claro que dois
  `<input type="date">` soltos como estava antes. `weeklyPeriod`/`weeklyCustomFrom`/
  `weeklyCustomTo` (estado) não mudaram, só a UI que os controla.
- **"Acuracidade Mensal" virou `MonthlyAccuracyBarChart`** (componente novo, perto de
  `WeeklyCountChart`) — colunas em vez de linha, mas mantendo o eixo Y fixo 0-100% (como
  `WeeklyLineChart`, já que é acuracidade, não contagem absoluta) e o mesmo tratamento de
  meta (linha tracejada + badge no cabeçalho do painel, "no mesmo formato" dos outros
  dois, como pedido).
- **Gráfico mensal ficou INDEPENDENTE do filtro de período semanal** — decisão explícita
  pra resolver "mostrar todos os meses com dados do ano": um mês é um balde grande demais
  pro filtro "10/26 semanas" fazer sentido (10 semanas cobre só ~2-3 meses, deixando o
  gráfico mensal praticamente vazio a maior parte do tempo). Em vez de amarrar ao mesmo
  `dataInicioStr`/`dataFimStr` dos gráficos semanais, `Dashboard` calcula um intervalo
  próprio só pra ele — sempre 1º de janeiro do ano corrente até hoje
  (`String(new Date().getFullYear())+'-01-01'` até `hojeStr`) — e um subtítulo pequeno
  abaixo do título do painel ("Todos os meses de 2026 com dado registrado") deixa esse
  comportamento explícito, já que ele não segue mais o mesmo controle visível na tela.
- **Mais espaçamento**: `padT` (respiro entre o topo do SVG e a primeira grade/dado) subiu
  de 26 pra 34 em `WeeklyLineChart`/`WeeklyCountChart`, e pra 38 em
  `MonthlyAccuracyBarChart` (colunas costumam bater perto de 100%, com o rótulo do valor
  ACIMA da barra — precisa de um pouco mais de respiro que os outros dois pra não ficar
  espremido contra a grade de "100%"). `marginBottom` entre o cabeçalho do painel
  (título+badge) e o SVG também subiu de 10 pra 16px nos três painéis.
- Testado via Playwright (sandbox sem rede, contagens sintéticas espalhadas de jan a
  jul/2026): confirmei os 4 botões do segmented control (10/26/todo/personalizado), que
  "10 semanas" vem ativo por padrão, que clicar em "Personalizado" revela o widget de
  data com ícone+labels "De"/"Até", que o gráfico mensal usa `<rect>` (colunas) e não mais
  `<polyline>` (linha), que ele mostra os 7 meses (Jan-Jul) com dado mesmo com o filtro
  semanal em "10 semanas" (prova da independência), e que o subtítulo menciona o ano
  corrente. Conferi visualmente por screenshot que não há mais sobreposição entre o eixo
  "100%"/badge de meta e as barras/rótulos de valor. Rodei de novo a suíte de regressão da
  seção de Indicadores — só `verify_view_persist_period_filter.js` precisou de ajuste (
  usava `select.pnl-period-select` pra trocar de período, que não existe mais nessa seção;
  trocado pra clicar no botão "Todo o período" do segmented control — mudança de UI
  intencional desta rodada, não regressão).

## Painel "Filtros" — redesign completo estilo SaaS premium (Power BI/Stripe/Vercel)

O segmented control com "10/26 semanas/Todo o período" da rodada anterior ainda não
resolveu a queixa do cliente: mandou um crop mostrando "94%" encostando no "100%" do eixo
de novo, e pediu um redesign completo da barra de filtros, com referência explícita a um
mockup (Power BI, Linear, Notion, Vercel, Figma) — abandonar de vez o vocabulário
"10/26 semanas/todo período" por presets de calendário do dia a dia, mais um card
"Filtros" com cabeçalho, chip de intervalo aplicado e botão "Atualizar". O pedido veio com
uma especificação técnica pra React+TypeScript+TailwindCSS com componentes separados
(`DashboardFilters.tsx` etc.) e Framer Motion — **não seguida ao pé da letra**: este app
não tem build step nem TypeScript/Tailwind (ver topo deste arquivo, "Estado atual"), então
a implementação replicou o resultado visual/UX pedido dentro da arquitetura existente
(um componente de função React dentro do mesmo `index.html`, CSS puro escopado, Babel
Standalone) — trade-off já aceito antes nesse projeto (ex.: "Ícones Lucide" via SVG
desenhado à mão em vez de puxar o pacote real). Framer Motion também não entrou — as
transições pedidas (200ms no hover dos botões) saem só de CSS `transition`, sem lib nova.

- **`computeTrendRange(tipo, hojeStr, from, to)`** (função nova, perto de
  `computeWeeklyStats`) — traduz um preset (`hoje`/`semana`/`mes`/`30d`/`90d`/`ano`/
  `custom`) num par `{from, to}` de datas concretas. Presets fixos são SEMPRE recalculados
  a partir de "hoje" (não guardam data absoluta) — reabrir o dashboard amanhã com "Últimos
  30 dias" ainda selecionado desliza a janela sozinho. Só `custom` usa `from`/`to`
  (persistidos) como fonte de verdade.
- **`trendFilter` = `usePersistedState('dashboardTrendFilter', {tipo:'30d', from:'', to:''})`**
  — substituiu os três `useState` soltos da rodada anterior (`weeklyPeriod`/
  `weeklyCustomFrom`/`weeklyCustomTo`). Pedido explícito do cliente ("persistir o último
  filtro utilizado no localStorage") — antes o filtro resetava pra "10 semanas" toda vez
  que a tela era remontada (trocar de view e voltar), sem persistência nenhuma.
- **`.trend-filter-bar`** (card novo, substitui o antigo `.pnl-period-toolbar` dentro do
  `section-title` "Tendência" — essa seção perdeu o título "Tendência" por completo, o
  card "Filtros" agora cumpre esse papel de cabeçalho da área): `border-radius:18px`,
  `border:1px solid #EAEAEA`, `box-shadow:0 8px 30px rgba(0,0,0,.05)`, `padding:24px` —
  valores exatos pedidos pelo cliente. Estrutura: cabeçalho (`.tfb-icon-badge` com
  `FilterIcon`, título "Filtros", subtítulo, e à direita `.tfb-range-chip` mostrando o
  intervalo aplicado + `.tfb-refresh-btn` "Atualizar"), depois a linha de presets
  (`.tfb-period-label` + `.tfb-quick-buttons`), e por último — só quando `tipo==='custom'`
  — `.tfb-custom-row` com os dois campos "Data inicial"/"Data final".
- **8 toggle buttons** (`.tfb-pill`): Hoje/Esta semana/Este mês/Últimos 30 dias/Últimos 60
  dias/Últimos 90 dias/Este ano/Personalizado — lista original pedida (7 opções) mais
  "Últimos 60 dias", pedido numa rodada seguinte pra preencher o degrau entre 30 e 90 dias
  (`computeTrendRange`, `case '60d'`, mesmo padrão dos outros — `hoje.setDate(-59)`).
  Ativo: fundo `#0D9488` (mesmo teal já usado como
  `WEEKLY_CHART_COLOR` nos três gráficos — reaproveita a cor de destaque já estabelecida
  pra essa seção em vez de introduzir "mais um verde"), texto branco, `border-radius:10px`,
  sombra leve. Inativo: branco, borda cinza clara, hover com tingimento teal suave,
  `transition:200ms` — valores exatos pedidos. Clicar num preset fixo aplica o filtro NA
  HORA (`setTrendFilter({tipo, from:'', to:''})`, `from`/`to` ficam vazios porque não têm
  significado fora do modo custom) — "alterar rapidamente o período com apenas um clique",
  como pedido.
- **Modo "Personalizado"**: ao clicar, os campos de data são pré-preenchidos com o
  intervalo JÁ APLICADO (`dataInicioStr`/`dataFimStr` calculados a partir do preset
  anterior), não com "hoje até hoje" — evita a sensação de que o filtro "sumiu" ao entrar
  no modo. Editar os campos aplica direto (`setTrendFilter(f=>({...f, from:...}))`,
  reativo) — como não há mais nenhum jeito de editar essas datas fora do modo
  `custom`, a regra "ao alterar manualmente uma data, marcar automaticamente como
  Personalizado" fica satisfeita por construção (os campos só existem quando o modo já É
  personalizado).
- **Botão "Atualizar"** (`.tfb-refresh-btn`, ícone `RefreshIcon` com animação de spin
  via `.spin-icon`/`@keyframes tfb-spin` enquanto `atualizando`): diferente dos gráficos
  de tendência (recalculados na hora, em memória, sem custo de rede, a partir de
  `counts`/histórico já carregados), a seção "Estoque" depende de 3 RPCs do Supabase que
  só rodavam uma vez no mount (`fetchEstoqueValorPorAlmoxarifado`/
  `fetchUltimaAtualizacaoEstoque`/`fetchEstoqueResumoGeral`). Extraí essa lógica pra
  `carregarEstoque()` (função async reutilizável, chamada tanto no mount quanto no
  clique do botão) — dá ao "Atualizar" uma função de verdade (puxar o saldo mais recente
  sem recarregar a página inteira, útil se outro aparelho subiu uma planilha SB2 nova
  enquanto essa aba já estava aberta) em vez de um botão decorativo que só mexe em dado
  que já estava em memória.
- **Ícones Lucide-ish novos**: `FilterIcon` (funil, cabeçalho do card) e `RefreshIcon`
  (setas circulares, botão Atualizar) — mesmo padrão já usado pro `CalendarIcon` da rodada
  anterior (SVG desenhado à mão, não uma dependência real do pacote Lucide).
- **Responsividade**: `.tfb-quick-buttons`/`.tfb-head-actions` já usam `flex-wrap`, então
  telas médias (tablet) quebram os botões sozinhas sem CSS extra. Um
  `@media (max-width:640px)` (mesmo breakpoint já usado por `.kpi-grid`) empilha
  `.tfb-head-actions` (chip + botão) numa linha própria abaixo do título, e
  `.tfb-period-row`/`.tfb-custom-row` viram coluna — "mobile: filtros ficam em coluna",
  como pedido.
- **Classes antigas removidas**: `.pnl-period-toolbar`/`.pnl-segmented`/`.pnl-daterange`/
  `.pnl-date-input` (introduzidas na rodada anterior, só usadas nesse toolbar) foram
  apagadas do CSS — ficaram órfãs depois da substituição, nenhum outro lugar do app as
  usava (`.pnl-period-select`, usado pelo filtro de período da Home/`DesktopTopbar`, é uma
  classe DIFERENTE e continua intacta).
- Testado via Playwright (sandbox sem rede): confirmei os 7 botões na ordem certa,
  "Últimos 30 dias" ativo por padrão, o chip de intervalo mostrando as datas certas em
  pt-BR (`fmtDataBR`), que clicar em "Hoje" aplica em 1 clique (chip atualiza, botão fica
  ativo), que "Personalizado" revela os campos com labels "Data inicial"/"Data final",
  que editar as datas atualiza o chip E os gráficos na hora, que "Atualizar" refaz a
  chamada RPC de estoque, e que o filtro sobrevive a um reload da página (persistido em
  `stock360:v1:dashboardTrendFilter`). Rodei de novo a suíte de regressão da seção de
  Indicadores — os scripts que fixavam datas históricas específicas (`verify_weekly_
  historico_meta`, `verify_weekly_pendente_meta95`, `verify_weekly_trend_fix`,
  `verify_weekly_charts`, `verify_view_persist_period_filter`) precisaram selecionar
  explicitamente um período mais largo ("Este ano" ou um intervalo personalizado) já que
  o padrão mudou de "10 semanas" pra "Últimos 30 dias" (janela mais estreita) — mudança de
  UI intencional desta rodada, não regressão; um teste (`verify_weekly_trend_fix`) também
  teve a asserção "exatamente 10 semanas no eixo" relaxada pra "mesmo número de baldes nos
  dois gráficos", já que o conceito de janela fixa em N semanas foi removido de propósito.

## Quarto pedaço do backend real: usuários e endereços pendentes sincronizam entre aparelhos

O cliente reportou dois sintomas no mesmo dia: excluiu um usuário (Carlos Mendes) num
computador de tarde, mas ele continuava aparecendo em outro; e um segundo aparelho ainda
mostrava endereços pendentes de teste (ex.: "TRAVA ROLO PRESS") de uma limpeza que já
tinha sido feita antes. Investigando o código, os dois tinham a MESMA causa raiz: `users`
e `enderecosPropostos` nunca foram migrados pro Supabase — ficavam 100% no `localStorage`
de cada aparelho (login/usuários continuavam locais por decisão explícita anterior, ver
"Terceiro pedaço do backend real"; endereços nunca tinha entrado no escopo de nenhuma
sincronização). Confirmado com o cliente (`AskUserQuestion`, 3 perguntas): sincronizar
usuários (versão leve, sem Supabase Auth de verdade), sincronizar endereços propostos, e
aplicar o mesmo reset de dados de teste já usado antes (bump de chave) nos endereços.

### `backend/schema.sql` — tabela `usuarios` reescrita, `enderecos_propostos` nova

A tabela `usuarios` original (criada na 1ª aplicação do schema) tinha `id uuid`, nenhuma
coluna de senha, e um comentário dizendo "senha fica no Supabase Auth" — nunca foi usada
de verdade, porque login sempre autenticou 100% contra o `localStorage`. Reescrita pra
bater com a realidade: `id text` (o app já gera seus próprios ids, `'u'+Math.random()...`,
mesmo padrão de `inventarios`/`contagens`), `senha text` (texto puro, mesma limitação já
documentada no README), `atualizado_em` (mesmo papel que já cumpre em `contagens`, decidir
qual lado é mais recente ao reconciliar). Bloco de migração no fim do arquivo faz
`drop table if exists usuarios` + recria (seguro porque a tabela antiga nunca tinha dado
real) — **não** um `alter table add column`, que deixaria a estrutura errada por baixo.

`enderecos_propostos` é tabela nova, mesmo espírito denormalizado de sempre (sem FK pra
`usuarios`/`produtos`, mesmas razões já documentadas em `contagens`) — espelha
`addAddressProposal`/`resolveAddressProposal` no `index.html`. Nunca é deletada, só muda
de `status` (`pendente`→`confirmado`/`rejeitado`), por isso não tem policy de DELETE.
RLS de ambas: `using(true)` em tudo que precisa (mesma ressalva de sempre, sem Supabase
Auth real ainda).

### `index.html` — funções Supabase, mutators assíncronos, dois ciclos de sync

- **Funções novas** (perto de `fetchInventoriesFromSupabase`): `saveUsuarioToSupabase`/
  `updateUsuarioToSupabase`/`deleteUsuarioFromSupabase`/`fetchUsuariosFromSupabase` e o
  par equivalente pra `enderecos_propostos`. `fetchUsuariosFromSupabase` retorna `null`
  (não `[]`) quando a busca FALHA — mesma distinção já usada em
  `fetchInventoriesFromSupabase`, essencial pra sincronização poder remover um usuário
  ausente remotamente sem confundir "sem usuário nenhum" com "a rede caiu".
- **Todos os mutators de usuário viraram assíncronos** (`createUser`/`updateUser`/
  `deleteUser`/`toggleUserStatus`/`applyAdminPasswordAction`/`selfSetNewPassword`) —
  aguardam confirmação do Supabase ANTES de mudar o estado local, mesmo padrão já usado em
  `approveDivergence`/`deleteInventory`. Isso é o que resolve o bug relatado: antes,
  `deleteUser` só fazia `setUsers(prev=>prev.filter(...))`, sem tocar em rede nenhuma.
  `resolveAddressProposal` (confirmar/rejeitar endereço) segue o mesmo padrão;
  `addAddressProposal` (operador propondo um endereço) continua fire-and-forget, mesmo
  espírito de `saveContagemToSupabase` — não pode travar o operador no meio de uma
  contagem esperando rede.
- **Ciclo de sync de USUÁRIOS é separado do ciclo de 30s "principal"** e roda mesmo ANTES
  do login (`useEffect` com `[]` de dependência, não `[currentUser]`) — resolvia
  exatamente o problema relatado: se o ciclo só rodasse depois de autenticado, um usuário
  excluído em outro aparelho continuaria conseguindo logar neste até... nunca, porque a
  sincronização nunca teria chance de rodar antes da tentativa de login (`attemptLogin` lê
  `users` local, síncrono). Faz merge por `atualizadoEm` e REMOVE localmente um usuário
  ausente remotamente (propaga exclusão) — e, como efeito colateral bom, se o usuário
  logado neste aparelho for excluído em outro, `currentUser` recalcula pra `null` no
  próximo render (é só `users.find(u=>u.id===currentUserId)`) e o app cai pro login
  sozinho, sem precisar de nenhum código de logout explícito adicional.
- **Bootstrap pra primeira sincronização**: se `fetchUsuariosFromSupabase()` volta um
  array VAZIO (não `null` — a tabela existe mas ninguém sincronizou ainda, cenário típico
  logo depois do cliente rodar o SQL novo), o app empurra os usuários que já existem
  NESTE aparelho pro Supabase em vez de tratar "vazio" como "remove todo mundo local" —
  sem isso, o primeiro aparelho a sincronizar depois do deploy apagaria a lista de
  usuários de todo mundo por engano. Ids que colidem entre aparelhos fazendo bootstrap ao
  mesmo tempo (ex: `USERS_SEED`, idêntico em todo aparelho novo) só falham silenciosamente
  (linha já existe) — inofensivo.
- **Endereços propostos entraram no ciclo de sync "principal"** (o de 30s, já autenticado,
  junto de inventários/contagens) — só aditivo + atualiza por `atualizadoEm`, nunca
  remove (proposta nunca é deletada no app).
- **Chave `enderecosPropostos_v2`** (era `enderecosPropostos`) — mesmo reset já aplicado
  antes a inventários/contagens (ver "Reset geral de contagens/inventários"): zera sozinho
  em qualquer aparelho que abrir depois deste deploy, sem comando manual. `users` NÃO
  teve a chave trocada — não fazia sentido apagar usuários reais que o cliente já
  cadastrou, o problema ali era sincronização, não dado de teste sobrando.
- **UI com busy/erro por linha**: `UserManagementPanel` (bloquear/excluir/senha),
  `UserForm` (criar/editar) e `AddressValidationPanel` (confirmar/rejeitar) ganharam
  estado `busyId`/`erros` (ou `salvando`/`feedback` no formulário) — mesmo padrão já
  usado em `RecountsPanel`: desabilita só o botão clicado, mostra erro inline, não trava a
  tela toda nem finge sucesso quando a gravação remota falha.
- Testado via Playwright (sandbox sem rede, Supabase mockado incluindo simulação de dois
  "aparelhos" compartilhando um objeto de banco em memória): confirmei que um usuário
  criado em outro aparelho consegue logar neste sem nunca ter feito login aqui antes
  (fetch pré-login); que excluir um usuário no aparelho A o remove da lista lá E impede
  login com esse usuário no aparelho B; que o bootstrap empurra os 4 usuários locais
  quando a tabela remota está vazia sem quebrar login; que confirmar/rejeitar um endereço
  proposto envia o PATCH certo e atualiza a tela; e que a chave antiga
  (`enderecosPropostos`, sem `_v2`) é ignorada — dado de teste não aparece mais. Rodei de
  novo boa parte da suíte de regressão existente, sem quebrar nada (dois scripts antigos
  não relacionados a esta mudança — `verify_inventory_delete_create`/
  `verify_session_persist` — já tinham asserções frágeis/seletores desatualizados antes
  desta rodada, não mexi neles por estarem fora de escopo).
- **Confirmado contra o Supabase real** — o cliente rodou o SQL e reportou sucesso.
  Achado no caminho: o `drop table usuarios` simples deu erro (`2BP01: cannot drop table
  usuarios because other objects depend on it`) — o projeto real tinha uma coluna
  `enderecos.criado_por` e uma tabela `endereco_propostas` (singular, nomes que não
  existem em lugar nenhum deste repo) com FK pra `usuarios`, criadas em algum momento
  direto no painel do Supabase, fora de qualquer SQL deste `schema.sql` (schema drift).
  Antes de resolver, pedi ao cliente pra rodar uma consulta de introspecção
  (`information_schema.columns` + `count(*)` das três tabelas) — confirmou 0 linhas nas
  três, então era seguro usar `drop table usuarios cascade` (só remove as CONSTRAINTS de
  FK que dependem de `usuarios`, não apaga `enderecos` nem dado nenhum) e também dropar a
  `endereco_propostas` órfã (evita duas tabelas de nome quase idêntico coexistindo, uma
  delas — a `enderecos_propostos` plural — sendo a única que o app de fato usa).
  `backend/schema.sql` já reflete essa versão corrigida do bloco de migração. Lição pro
  futuro: quando uma migração aqui envolve `drop table` num projeto que o cliente
  gerencia direto pelo painel, sempre pedir uma consulta de introspecção antes de
  recomendar `cascade` às cegas — o schema.sql deste repo não é necessariamente um
  espelho fiel do que existe no projeto real.

## Login vira redesign premium (Fiori/M365/Power BI) — terceira identidade da tela de login

O cliente pediu um redesign completo da tela de login com um mockup de referência exato
(imagem pixel-a-pixel) e uma instrução explícita: "esta imagem passa a ser o Design System
desta tela... em caso de conflito entre o texto do prompt e a imagem, a imagem tem
prioridade" — e "NÃO altere nenhuma funcionalidade existente, apenas o layout". Isso supera
por completo a versão de 2 colunas da rodada anterior (ver "Tela de login vira o mockup de
2 colunas"), que já tinha ilustração+formulário lado a lado mas num formato/proporção/
paleta diferentes do que foi pedido agora.

**Especificação técnica não seguida ao pé da letra, por design**: o prompt pedia React+
TypeScript+TailwindCSS com componentes separados (`LoginPage.tsx`/`BrandPanel.tsx`/etc.) e
Framer Motion. Este projeto não tem build step (Babel Standalone via CDN, sem bundler,
sem TypeScript/Tailwind — ver topo deste arquivo). Implementei o mesmo resultado visual
dentro da arquitetura existente: um `LoginScreen` só, CSS puro escopado, ícones SVG
desenhados à mão no estilo Lucide (mesmo padrão já usado no Dashboard/sidebar) — mesmo
trade-off já aceito antes neste projeto. Framer Motion não entrou; as transições pedidas
(hover 200ms, focus) saem só de CSS `transition`.

### Estrutura nova

- **`.login-page`** (fundo com degradê suave `#F7F8FB→#EEF2F7`, sem imagem) → **`.login-shell`**
  (max-width 1450px, `border-radius:24px`, sombra suave, `overflow:hidden`, flex row 45/55
  a partir de 900px) → **`.login-brand`** (45%, coluna esquerda) + **`.login-form-col`**
  (55%, coluna direita).
- **`.login-brand`**: fundo branco com grade de pontos bem sutil (`radial-gradient` repetido
  via `background-size`), logo Selgron grande no topo (`padding-top:50px`), `WarehouseHeroIcon`
  (hexágono outline laranja claro com caixa isométrica + risca de código de barras dentro —
  substitui o `CycleIcon` da versão anterior, que representava "ciclo de contagem"; o mockup
  novo pede especificamente "cube/warehouse/barcode"), título "Gestão de Estoques" (`clamp
  (30px,3.4vw,56px)`, peso 800), linha decorativa laranja 80×4px, subtítulo, e a
  `WarehouseIllustration` (cena SVG geométrica "flat" — racks, pallets, empilhadeira — em
  navy/cinza/laranja/branco, sem verde, com 3 "cards flutuantes" de HTML sobrepostos via
  `position:absolute`: Indicadores/tempo real, Acuracidade/92%, Leitura rápida/QR). Sem foto
  real (mesma ressalva já documentada antes: "o app não tem esse asset", cena inteira
  desenhada só com formas geométricas). Rodapé com os 3 benefícios (Seguro/Inteligente/
  Eficiente) em linha, ícones em `.bn-icon`.
- **`.login-form-col`**: seletor de idioma (canto superior direito, decorativo — só
  Português existe), título "Bem-vindo de volta!" (mesmo `clamp` do título da marca, um
  pouco menor), campos com 64px de altura/`border-radius:14px`/ícone à esquerda (hover:
  laranja bem suave; focus: borda laranja + `box-shadow` de destaque — valores exatos
  pedidos), linha "Lembrar-me" (checkbox custom) + "Esqueci minha senha" (link laranja),
  botão "Entrar" (64px, laranja, ícone `logIn`), divisor "OU", botão outline "Entrar com
  código de acesso" (borda laranja, texto navy), painel de credenciais de demonstração
  (mantido — é funcionalidade já existente, útil pra QA, não fazia parte do que devia
  mudar), rodapé com cadeado + texto de acesso restrito + copyright.
- **Cor laranja**: mockup citava um hex novo (`#F7941D`) — mantive `--safety` (`#F6A200`,
  já usado em todo o app, documentado como "cor oficial da marca") em vez de introduzir
  mais um tom quase idêntico só pra esta tela. `--navy`/`--gray-*`/`--font-corp` já eram
  compartilhadas com o Dashboard desde o redesign anterior, reaproveitadas direto.

### Elementos do mockup sem funcionalidade real por trás — decorativos, honestamente

Três elementos do mockup não correspondem a nenhum recurso que o app tem hoje. Confirmado
mentalmente com o critério já estabelecido no projeto (sino de notificação do
`DesktopTopbar`: "abre um dropdown fixo dizendo 'Nenhuma notificação por enquanto' — não
finge que existe uma lista real"), apliquei o mesmo padrão em vez de inventar
funcionalidade nova (que o próprio pedido do cliente proibia — "não altere nenhuma
funcionalidade existente") ou fingir que algo funciona:
- **Seletor de idioma** ("🌐 Português (BR)"): botão inerte, `title="Único idioma
  disponível no momento"` — não abre dropdown nenhum, porque não existe i18n no app.
- **"Lembrar-me"**: checkbox decorativo (`useState` local só de UI, sem ligação com
  `attemptLogin`/sessão) — a sessão já persiste automaticamente sempre (ver
  `SESSION_STORAGE_KEY`), então um checkbox "lembrar" seria redundante/enganoso se
  realmente controlasse alguma coisa; `title` no botão explica isso.
- **"Entrar com código de acesso"**: ao clicar, mostra uma nota inline honesta ("Login por
  código de acesso ainda não está disponível") em vez de não fazer nada (silencioso,
  pareceria quebrado) ou fingir abrir um scanner de verdade.

### Compatibilidade com a suíte de testes existente

Praticamente todo script de regressão do scratchpad usa um "login helper" copiado repetido
(`.login-field input[type="text"]` + `.login-field input[type="password"]` + `.login-btn`,
e `.login-card`/`.login-screen` pra detectar "está na tela de login") — reescrever ~40
scripts só por causa da renomeação de classe seria desproporcional. Em vez disso, os
elementos novos carregam DOIS nomes de classe: `.login-field2 login-field`,
`.login-btn2 login-btn`, `.login-shell login-card`, `.login-page login-screen` — os nomes
antigos (`login-field`/`login-btn`/`login-card`/`login-screen`) não têm NENHUMA regra CSS
própria mais (só existem como seletores estáveis pros testes), toda a aparência real vem
das classes novas (`-2`/`-shell`/`-page`). Zero efeito visual, só evita quebrar a suíte de
testes inteira por um detalhe de nome de classe.

**Bug real encontrado e corrigido durante a implementação**: o primeiro screenshot saiu
com a página inteira sem estilo nenhum (logo gigante, campos sem layout) — toda a folha de
estilo tinha parado de ser aplicada. Causa: um comentário CSS que eu mesmo escrevi continha
o texto `--navy/--gray-*/--font-corp` — a sequência de caracteres `*/` no meio do texto
(vinda de `gray-*` seguido de `/--font`) fechou o comentário ANTES da hora, e tudo que
vinha depois (incluindo o `*/` de fechamento de verdade, bem mais abaixo) virou CSS
inválido, quebrando o resto da folha de estilo inteira. Corrigido reescrevendo o comentário
pra não formar `*/` sem querer (`--gray-N` em vez de `--gray-*`) — lição: nunca usar `*/`
literal (mesmo por acaso, tipo `algo-*` seguido de `/outra-coisa`) dentro de um comentário
CSS.

Testado via Playwright nos três breakpoints (desktop 1600px, tablet 1024px, mobile 390px)
— confirmei visualmente por screenshot que a coluna de marca desaparece no mobile (só logo
compacto + título ficam, como pedido), que os campos de demonstração empilham
corretamente em telas estreitas (mesmo ajuste já feito antes pro layout antigo, reaplicado
aqui pra `.dc-row2`), e funcionalmente que login válido/inválido, mostrar/ocultar senha,
esqueci-minha-senha (ida e volta) e o aviso do botão de código de acesso funcionam sem
nenhuma mudança de comportamento. Rodei de novo boa parte da suíte de regressão existente
(sessão, logout, sync de usuários) sem quebrar nada, graças às classes de compatibilidade.

## Segunda rodada do login: fidelidade pixel-perfect + bug real de layout que afetava as 3 larguras

Depois do redesign da seção anterior, o cliente pediu uma segunda passada bem mais
rígida: "revisão de UI... quanto menor a diferença visual [com a imagem de referência],
melhor a avaliação... não interprete, não simplifique, não modernize, não redesenhe" —
com a mesma imagem de referência de antes (2 colunas, ilustração de armazém, cards
flutuantes "Indicadores"/"Acuracidade", rodapé com logo pequena + separador + tagline
FORA do card branco). Pontos concretos pedidos que a rodada anterior não tinha acertado:
container mais estreito (max-width 1300px em vez do valor anterior) e com `border-radius`
maior; **ilustração não deve ser desenhada em SVG à mão** ("não utilize desenhos... não
utilize clipart... utilize temporariamente uma imagem placeholder, depois será
substituída"); toggle de senha só com ícone (sem o texto "Mostrar"/"Ocultar" ao lado);
"ou" em minúsculo; credenciais de demonstração escondidas atrás de um link, não sempre
visíveis; e — ponto que mudou de posição entre as duas rodadas — **"Mobile: Ocultar
apenas a ilustração. Nunca ocultar o branding"**, ao contrário da 1ª rodada que dizia pra
esconder o painel de marca inteiro no celular.

- **`BrandIllustration`** (substituiu `WarehouseIllustration`, a cena SVG desenhada à mão
  com prateleiras/paletes/empilhadeira) — agora é só um `<img src="images/login-
  illustration.png" onError={...}/>`, exatamente como pedido ("reserve apenas a área da
  imagem, ela será substituída depois"). Como este projeto não tem pipeline de assets
  (`public/`, sem build step — ver topo deste arquivo), o caminho é um placeholder: se o
  arquivo não existir, `onError` esconde a tag (`visibility:hidden`) e o espaço reservado
  (`.login-illustration-scene`, fundo cinza claro) aparece vazio em vez de um ícone de
  imagem quebrada. **Fica pendente o cliente fornecer o arquivo real** — quando ele mandar
  uma imagem de verdade, o próximo passo é só salvá-la em `images/login-illustration.png`
  (ou trocar o `src`), nenhuma mudança de código adicional necessária.
- **Cards flutuantes**: o card "Leitura rápida" (3º card da rodada anterior) foi removido
  — a imagem de referência só mostra 2. Os 2 que restaram (`login-float-1`/`-2`) ganharam
  `max-width:47%` (ancorados em bordas opostas via `left:0`/`right:0`) + `text-overflow:
  ellipsis` no lugar de `white-space:nowrap` sem limite — antes, o texto de largura fixa
  podia estourar a metade da cena disponível e as duas fazerem overlap conforme a coluna
  de marca encolhe num tablet; agora é estruturalmente impossível as duas se tocarem,
  não importa a largura. `.login-float-3` (CSS órfão depois de remover o 3º card do JSX)
  foi apagado.
- **Credenciais de demonstração** viraram um link colapsável (`.login-demo-toggle`,
  `showDemoCreds` state, default fechado) em vez de aparecerem sempre abertas — mantém a
  funcionalidade (útil pra QA, já existia antes de qualquer pedido de redesign, então não
  podia simplesmente sumir) enquanto bate com a imagem de referência (que não mostra esse
  bloco por padrão).
- **`.login-brand-logo-wrap img`**: `height:34px;width:auto` fixo virou `height:auto;
  max-height:34px;width:auto;max-width:100%` — bug real pego por screenshot: no tablet
  (largura ~44% da coluna de marca, ~1024px de viewport), a largura natural da logo numa
  altura fixa de 34px ficava maior que a coluna disponível, e como `.login-brand` tem
  `overflow:hidden`, a logo aparecia cortada no meio da palavra ("SELGR" com "ON"
  cortado). `max-width:100%` deixa o navegador escalar proporcionalmente pela dimensão
  mais apertada (altura OU largura), sem cortar.
- **Bug real mais sério, achado comparando screenshot com a imagem de referência**: o
  rodapé externo (`.login-outer-footer`, logo pequena + "|" + "Tecnologia que impulsiona
  nossa indústria.") tinha sido adicionado como IRMÃO de `.login-shell` dentro de
  `.login-page` na rodada anterior — mas `.login-page` nunca tinha `flex-direction:
  column` declarado (só `display:flex;align-items:center;justify-content:center`, que
  por padrão é `flex-direction:row`). Resultado: o rodapé renderizava **ao LADO do card**
  (não abaixo, como a imagem sempre mostrou), flutuando verticalmente centralizado num
  espaço vazio à direita — visível nos 3 breakpoints, mas dramático no celular, onde os
  dois itens (card + rodapé) competindo por 350px de largura numa linha só forçava
  `flex-shrink` a espremer AMBOS a ~117px, quebrando o layout inteiro (textos
  sobrepostos, coluna de marca ilegível). Corrigido com uma linha:
  `.login-page{flex-direction:column}`. Esse bug não tinha sido pego na rodada anterior
  porque os screenshots de verificação daquela rodada foram tirados ANTES do rodapé
  externo existir no JSX (o rodapé foi adicionado depois, sem re-screenshot completo) —
  lição: sempre re-tirar screenshot nos 3 breakpoints depois de QUALQUER mudança
  estrutural no JSX da tela de login, não só depois de mudança de CSS.
- **Mobile — comportamento trocado**: a regra `@media(max-width:899px){.login-brand{
  display:none}}` (que escondia a coluna de marca inteira, da 1ª rodada) foi substituída
  por esconder só `.login-illustration-scene` — o resto da coluna de marca (logo, ícone
  hexagonal, título "Gestão de Estoques", linha decorativa, subtítulo, os 3 benefícios)
  continua visível, empilhado acima do formulário, só com paddings/tamanhos reduzidos
  pra caber melhor numa tela estreita. Isso também tornou `.login-mobile-brand` (o
  bloco compacto duplicado de logo+título que só existia pra aparecer quando o painel de
  marca inteiro sumia) redundante — removido do CSS e do JSX, já que agora `.login-brand`
  em si já cumpre esse papel no celular.
- Testado via Playwright nos 3 breakpoints (1600/1024/390px) com verificações
  automatizadas (não só visuais): coluna de marca visível nos 3; ilustração escondida só
  no mobile; os 2 cards flutuantes nunca se sobrepõem (bounding box, checado
  matematicamente); a logo nunca excede a largura do container (sem corte); e por
  screenshot, que o rodapé externo aparece corretamente centralizado ABAIXO do card nos 3
  tamanhos. Rodei de novo `verify_login_flows.js` (login válido/inválido, mostrar/ocultar
  senha, esqueci-minha-senha, nota do código de acesso — tudo passou sem nenhuma mudança
  de comportamento) e a suíte de regressão de sessão/usuários (`verify_smoke`,
  `verify_session_logout`, `verify_users_sync`) sem quebrar nada.
- **Fora de escopo desta rodada**: a componentização pedida no prompt
  (`LoginPage`/`BrandPanel`/`LoginPanel`/`LoginForm`/`LoginFooter` como componentes
  React separados, arquitetura TypeScript/Tailwind) não foi seguida à risca — mesmo
  trade-off já aceito nas rodadas anteriores (este projeto não tem build step nem
  TypeScript/Tailwind, ver topo deste arquivo). Só `BrandIllustration` virou um
  componente de função próprio (o pedido era mais enfático sobre esse elemento
  especificamente — "crie apenas `<BrandIllustration />`"); o resto continua dentro de
  um único `LoginScreen`, mesmo padrão de organização já usado no resto do app.

## Terceira rodada do login: reduzir o tamanho geral + trocar ícone "cara de desenho de criança"

Depois da rodada de fidelidade pixel-perfect, o cliente testou no próprio navegador e
reportou dois problemas concretos, com print: "ficou muito grande na tela" (o card
ultrapassava a altura da janela, cortando o botão "Entrar com código de acesso" antes do
fim) e "não ficou igual, ficou parecendo desenho de criança" — a segunda queixa, por
eliminação (o print mostrava a área de ilustração vazia, já que o placeholder `<img>`
ainda não tem asset real), só podia se referir ao ícone hexagonal com o cubo isométrico
desenhado à mão (`WarehouseHeroIcon`) — traços grossos, cores lisas, proporções meio
"brinquedo", destoando do resto do app que usa um sistema de ícones lineares mais sóbrio.

- **`WarehouseHeroIcon` removido, substituído por `<DIcon name="box" .../>`** — o mesmo
  sistema de ícones Lucide-style (`DICON_PATHS`/`DIcon`) já usado no resto do app
  (sidebar, header, Dashboard). Em vez de um hexágono multicolorido com cubo 3D desenhado
  à mão, agora é um badge simples (fundo laranja bem claro `#FFF4E4`, ícone de caixa em
  stroke fino cor `--safety`) — visualmente consistente com o resto da identidade
  corporativa da tela, não mais um elemento isolado com estilo próprio.
- **Redução geral de tamanho** — o card tinha ficado alto de mais (altura mínima de
  760px só do shell) pra caber em janelas de navegador mais baixas (ex: laptop com barra
  de favoritos ocupando espaço, ~600-650px de altura útil). Reduzido em cascata, sem
  cortar nenhum elemento do layout de referência, só os respiros/proporções:
  `.login-shell{min-height:760px→560px}`, ícone hero (100px→64px), título da marca
  (`clamp(30-56px)→clamp(24-38px)`), subtítulo (16px→14.5px), ilustração
  (max-width 520px→360px, ganhou `max-height:190px`), benefícios (padding 26/40→16/28),
  campos e botões (altura 64px→52px, radius 14px→12px), paddings da coluna de formulário
  (44px→32px verticalmente, 80px→64px horizontalmente) e praticamente todas as margens
  entre blocos do formulário (welcome-sub, row-between, divisor "ou", demo-toggle) —
  cada uma cortada em ~25-30%. Resultado: altura do shell caiu de ~950px+ pra 675px numa
  tela 1280px de largura, cabendo com folga em janelas de 768px de altura e quase inteiro
  em janelas de 620px (só a faixa de rodapé externo fica cortada nesse caso extremo).
- **Preservado sem mudança**: a estrutura/composição em si (2 colunas, ilustração +
  cards flutuantes, benefícios, rodapé externo) — só a ESCALA de cada elemento mudou, não
  o layout. Continua batendo com a imagem de referência, só que num tamanho mais
  compacto, mais parecido com a proporção real de uma tela de login (que na imagem
  original também não deveria dominar a janela inteira).
- Testado via Playwright em 5 larguras (1280×620 "laptop curto" — o cenário real do
  print do cliente —, 1366×768, 1600×950, 1024×900, 390×844): confirmei por screenshot
  que o ícone novo aparece limpo (sem o hexágono antigo), que a altura do shell caiu
  significativamente em todas as larguras, e que só a janela mais curta artificialmente
  (620px, mais baixa que a maioria dos laptops reais) ainda precisa de uma rolagem
  pequena — bem menos do que antes, quando cortava o botão principal do formulário.
  Rodei de novo `verify_login_flows.js` (login válido/inválido, mostrar senha, esqueci
  senha, nota do código de acesso) sem quebrar nada.

## Ilustração real do login chegou — recortada da composição completa que o cliente mandou

O cliente forneceu o arquivo real da ilustração pendente desde a rodada de fidelidade
pixel-perfect (`BrandIllustration`, que até aqui só renderizava um placeholder cinza
vazio). Ele subiu o arquivo direto no GitHub (não tinha como me anexar a imagem colada no
chat como arquivo de verdade — expliquei essa limitação e dei o passo a passo de upload
pela interface web do GitHub, `Add file → Upload files`, direto na branch de trabalho).

- **O arquivo enviado era a composição inteira da tela** (864×1821px, retrato) — logo
  Selgron, ícone hexagonal, título "Gestão de Estoques", subtítulo, a cena do armazém
  (prateleiras + empilhadeira + cards "Indicadores"/"Acuracidade"/QR/código de barras já
  prontos na própria imagem), MAIS uma seção de laptop/celular com print do app, MAIS a
  linha de benefícios (Seguro/Inteligente/Eficiente) — não só o recorte isolado da
  ilustração que o componente `BrandIllustration` esperava. Como o app já desenha logo,
  título, subtítulo e benefícios em HTML separadamente (por acessibilidade/manutenção,
  não como parte de uma imagem), plugar a composição inteira ali duplicaria esse conteúdo
  e cortaria a imagem de um jeito sem sentido dentro da caixa pequena reservada só pra
  ilustração.
- **Recorte feito com Python/PIL** (`img.crop((0, 665, 864, 1200))`, direto no arquivo já
  salvo no repo) — extrai só a cena do armazém com os 4 cards prontos (QR Code,
  Indicadores, Acuracidade, código de barras) e as linhas diagonais laranja decorativas,
  excluindo o cabeçalho (logo/título/subtítulo) e o rodapé (laptop/celular/benefícios) da
  composição original. Resultado: 864×535px (~1.615 de proporção, bem próximo do
  `aspect-ratio:16/10` já configurado em `.login-illustration-scene`), 628KB (era 1.6MB
  a composição inteira).
- **Os 2 cards flutuantes em HTML (`.login-float-1`/`.login-float-2`, "Indicadores"/
  "Acuracidade") foram removidos** — a imagem real já traz esses cards prontos, com muito
  mais qualidade visual (sombra, gráfico de verdade, donut colorido) do que a versão HTML
  simplificada que existia só como placeholder visual enquanto não havia imagem real.
  Mantê-los por cima da foto duplicaria o conteúdo. CSS órfão removido junto
  (`.login-float-card` e afins).
- `.login-illustration-scene` ganhou um pequeno aumento (`max-width:360px→400px,
  max-height:190px→210px`) já que agora é conteúdo real valioso de mostrar, não uma caixa
  cinza vazia — mantido moderado pra não reverter a redução de tamanho geral da rodada
  anterior.
- Testado via Playwright nos 3 breakpoints (1600/1024/390px): imagem carrega sem erro
  (`naturalWidth>0`), visualmente bate com a composição de referência do cliente (mesma
  cena, cards e linhas laranja), e no mobile a ilustração continua escondida (mesma regra
  já documentada: "ocultar só a ilustração, nunca o branding"). Rodei de novo
  `verify_login_flows.js` sem quebrar nada.
- **Se o cliente mandar uma imagem atualizada no futuro**: o padrão agora é sempre
  conferir se o arquivo é só o recorte da ilustração ou a composição completa da tela —
  se for a composição completa (mais fácil pro cliente gerar/exportar de uma vez), recorta
  de novo com o mesmo raciocínio (excluir cabeçalho e rodapé, que o app já desenha em
  HTML) antes de salvar em `images/login-illustration.png`.

## Convenções de design (não quebrar ao continuar)

- Tema claro, alto contraste (fundo cinza-claro `#EEF0F3`, painéis brancos, texto quase
  preto) — foi trocado de um tema escuro anterior porque ficava difícil de ler em tablet
  sob luz forte de almoxarifado. Não reverter para tema escuro.
- Laranja Selgron (`--safety: #F6A200`) como cor de destaque/ação principal — cor oficial
  da marca do cliente (Pantone 137 / CMYK 0,42,100,0), não um amarelo genérico. O cliente
  é a **Selgron**; "Inventário 360" é o nome do produto/app que roda dentro da marca dela
  (renomeado de "Stock360" — ver seção "Rebrand" abaixo; o repositório/pasta no disco
  continua se chamando `Stock360`, só o nome exibido no app mudou). Cinza institucional
  (`--ink-dim: #575756`, Pantone 432) também vem da identidade da Selgron.
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
