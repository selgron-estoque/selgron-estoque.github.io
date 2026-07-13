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
| Login, sessão, logout por inatividade | Real (mas senha em texto puro — só protótipo, ver aviso no `README.md`). Sessão em si continua só em memória de propósito — recarregar a página sempre volta pro login |
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

**Decisão de escopo (perguntada ao usuário via `AskUserQuestion`)**: o app já tinha DUAS
telas diferentes — "Início" (`view==='home'`, o que abre depois do login, com KPIs e
atalhos) e "Dashboard" (`view==='dashboard'`, uma tela de analytics à parte só com
gráficos simples). O pedido novo não mencionava "Início" na lista de menu, só
"Dashboard" — o cliente escolheu explicitamente manter as duas telas antigas E criar a
nova como um terceiro destino separado. Resultado:

- **`painel`** (view nova) — o Dashboard novo, descrito abaixo. Rota exclusiva desktop
  (não tem entrada no `BottomNav` nem no `Home` mobile — só alcançável pela `Sidebar`
  em telas ≥1024px, já que o pedido era especificamente pelo "sistema web").
- **`home`** ("Início") — não mudou em nada, continua exatamente como estava.
- **`dashboard`** (a tela de analytics antiga) — não mudou de conteúdo, só de **nome**:
  virou "Indicadores" (label na `Sidebar`, em `VIEW_TITLES['dashboard']`, e nos 3 lugares
  do `Home` que apontavam pra ela — KPI card, quick-access card, home-card mobile) pra
  não colidir com o novo item "Dashboard" no menu. O `goto('dashboard')` continua indo
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
design antigo — só a moldura (sidebar + header) e a tela `painel` em si usam a paleta
nova. Mobile (tablet do chão de fábrica) não foi tocado em nada.

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
