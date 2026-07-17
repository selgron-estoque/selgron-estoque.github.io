# Gestão de Estoques — Inventário Cíclico Industrial

> Nome do produto: **Gestão de Estoques** (antes chamado "Stock360" — o repositório/pasta no
> disco continua com o nome antigo `Stock360`, só a marca exibida dentro do app mudou).

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
- Sessão individual por usuário logado, guardada só em memória de propósito — recarregar
  a página sempre exige login de novo (ver "Persistência local" abaixo para o que já
  sobrevive a recarregar).
- Logout manual (botão no topo) e logout automático após 15 minutos de inatividade (sem
  clique, toque ou tecla).
- Bloqueio de usuário pelo administrador impede login imediatamente.
- Controle de permissões por perfil em cada tela (criar inventário só líder/admin, gestão
  de usuários só admin, etc.).

**⚠️ O que isso NÃO é ainda:** o protótipo guarda as senhas em texto puro (agora também no
`localStorage` do navegador, ver abaixo — antes só existiam em memória enquanto a aba
ficava aberta) só para simular o fluxo de login sem backend. Isso é aceitável apenas para
demonstração. Em produção, a autenticação deve usar o **Supabase Auth** (ou equivalente),
com hash de senha (bcrypt/argon2) feito no servidor — a senha nunca deve trafegar em texto
puro nem ficar visível para o administrador. As ações "gerar senha temporária" e "definir
senha manualmente" no protótipo mostram o valor em texto só para fins de demonstração; na
versão real, isso seria enviado por um canal seguro (e-mail/SMS) e nunca ficaria gravado
em log.

## Atualização: Persistência local (localStorage)

Antes desta atualização, tudo vivia só em `useState` — recarregar a página apagava
usuários criados, inventários, contagens, tudo. Agora os dados que o app gera (usuários,
inventários, contagens, endereços propostos, histórico de senha, histórico de envio de
relatório) são salvos no `localStorage` do navegador e recarregados automaticamente na
próxima abertura da página, **neste mesmo aparelho**.

- **O que isso resolve**: perder o trabalho ao recarregar a página sem querer, fechar a
  aba, ou o tablet reiniciar o navegador.
- **O que isso NÃO resolve**: sincronizar dados entre tablets/operadores diferentes. Cada
  aparelho tem sua própria cópia isolada do `localStorage` — se o líder cria um
  inventário no tablet dele, ele não aparece automaticamente no tablet do operador. Pra
  isso, precisa do backend real (Supabase) — ver seção "Backend (Supabase) — desenhado,
  ainda não aplicado" abaixo. Essa persistência local é um passo intermediário, não um
  substituto.
- A sessão de login continua **não** persistindo de propósito (ver nota de segurança
  acima) — só os dados operacionais.

## Atualização: Nova identidade visual da tela de login (rebrand para "Gestão de Estoques")

O app foi renomeado de "Stock360" para **"Gestão de Estoques"** em toda a interface (topbar,
sidebar, título da aba, PWA, arquivos exportados) — o repositório/pasta no disco continua
`Stock360` por conveniência, só o nome de marca dentro do produto mudou.

A tela de login ganhou uma identidade visual própria, separada do resto do app: branco
predominante, azul-marinho (`#0F172A`) e laranja institucional da Selgron, tipografia
Inter, ícones lineares (sem emoji), cantos de 8px, sombra bem suave — visual inspirado em
softwares corporativos/ERP (SAP Fiori, Dynamics 365) em vez do visual "genérico de
template" que existia antes. Essa paleta/tipografia é exclusiva da tela de login — o
restante do app (tablet do operador, dashboards, etc.) continua com o design system
original documentado no `CLAUDE.md`. O layout final é um card de 2 colunas (ilustração à
esquerda com o mark "ciclo + caixa" da Selgron, formulário à direita), replicando à risca
o mockup de referência enviado pelo cliente — a coluna de ilustração só aparece em telas
≥760px, em telas estreitas (celular) fica só o formulário.

## Atualização: Dashboard novo (agora é a própria tela inicial)

Depois do primeiro rascunho (Dashboard como uma tela nova, separada de "Início"), o
cliente pediu pra simplificar: **"Início" foi removido, e "Dashboard" passou a ser a
própria tela que abre depois do login** — no desktop. Mostra 5 indicadores operacionais,
últimas atividades, ações rápidas, e a situação geral dos inventários (gráfico donut +
tabela de status), com o mesmo visual corporativo/ERP da tela de login (navy, branco,
laranja, Inter, ícones lineares) — esse visual também foi aplicado à moldura da
sidebar/header em todas as telas desktop (o conteúdo interno de cada tela continua com o
design original). Tudo calculado a partir dos dados reais que o app já tem
(`counts`/`inventories`), sem número inventado.

No tablet/celular do operador, a tela "Início" continua exatamente como sempre foi (grid
de atalhos simples) — só ganhou o rótulo "Dashboard" no menu lateral do desktop, o
conteúdo mobile em si não mudou. A tela de indicadores/gráficos que já existia continua
existindo à parte, renomeada para "Indicadores" no menu (pra não ter duas coisas chamadas
"Dashboard"). Ver `CLAUDE.md` para os detalhes da decisão.

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
  quantidade de itens, 5 tipos de contagem (o 5º, Lista Importada via Excel, está descrito
  na seção "Atualização: Importação de lista de contagem via Excel" abaixo).
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

## Atualização: Importação de lista de contagem via Excel

5º tipo de inventário em "Módulo 1": **Lista Importada (Excel)**. Em vez do sistema
gerar a lista de itens a contar, o líder sobe uma planilha padrão e o app conta exatamente
os itens que vieram nela, na mesma ordem — sem embaralhar, sem filtrar.

- **Baixar modelo padrão (.xlsx)** — template com as colunas **Produto*** (obrigatório),
  **Descrição, End, Sistema, Fisico** (aba "Contar"), gerado no navegador via SheetJS. Esse
  layout replica a planilha que a fábrica já usa hoje pra contar — não é um formato novo
  inventado pelo app.
- **Upload da planilha preenchida** — parse 100% client-side. Nomes de coluna são
  normalizados (aceita "Produto" ou "Código", "End" ou "Endereço", acentos/maiúsculas
  variados), linhas sem código são ignoradas, códigos duplicados são removidos mantendo a
  1ª ocorrência. Antes de criar o inventário, um resumo mostra quantas linhas são válidas,
  quantas foram ignoradas/duplicadas, quantos códigos não constam no cache local de 300
  produtos do protótipo e, desses, quantos ainda assim trouxeram o saldo do sistema pela
  própria planilha (coluna "Sistema").
- **Contagem** — segue o fluxo padrão (contagem cega, QR/código de barras, foto, motivo de
  divergência, regras de segunda contagem do Módulo 7). A coluna **Sistema** da planilha é
  o que faz a maioria dos itens funcionar mesmo fora do cache local: como o protótipo só
  tem 300 dos 10.512 SKUs reais, a planilha real de teste trouxe 23 itens e só 1 batia com
  o cache — os outros 22 só têm saldo pra comparar porque a própria planilha trouxe. Só fica
  sem comparação automática (aviso visual, contagem vai direto pra análise do líder) o
  código que não está no cache **e** também não veio com saldo na planilha. Em produção,
  com o banco sincronizado, o saldo apareceria normalmente para qualquer código, com ou sem
  a coluna Sistema.

## Atualização: Relatório Excel (download e e-mail)

Novo card "Relatórios" na tela inicial, com duas ações:

**Baixar Excel (.xlsx)** — geração 100% no navegador usando SheetJS, sem precisar de
backend. O arquivo sai com 4 abas:
- **Resumo** — indicadores gerais (itens contados, divergências, acuracidade, valor
  divergente).
- **Contagens** — todas as contagens registradas, com histórico completo de rodadas
  (1ª, 2ª contagem…), endereço cadastrado, **endereço onde o item foi fisicamente
  contado** (pode divergir do cadastrado — ex: operador escaneia um endereço diferente e
  opta por "Contar mesmo assim"), usuário, quantidade, saldo do sistema, diferença, % de
  divergência, valor, status e motivo.
- **Contar** — mesmo formato da planilha de importação (Produto, Descrição, End, Sistema,
  Fisico), já com "Fisico" preenchido com a quantidade contada no app e uma coluna extra
  "Endereço Contado" — pensada pra fechar o ciclo: a mesma planilha que o líder sobe pra
  gerar a lista volta preenchida com o resultado, no formato que o cliente já reconhece.
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

## Atualização: catálogo real de produtos (primeiro pedaço do backend aplicado)

O projeto Supabase descrito abaixo deixou de ser só um modelo sugerido — foi criado de
verdade (`https://geeqfpzamexmeketcecu.supabase.co`) e o schema completo (`backend/schema.sql`)
já está aplicado. Por enquanto só a tabela `produtos` está populada, com **85.357 itens**
importados de uma planilha real do cliente (código, descrição, grupo) — bem mais completo
que os 300 SKUs do cache estático embutido no `index.html`.

Na tela de **Nova Contagem** (contagem manual avulsa), quando o item buscado não está no
cache local de 300 SKUs, o app agora consulta esse catálogo real automaticamente e traz a
descrição (e o endereço, se já estiver cadastrado) — em vez de simplesmente não encontrar
o item. Login, usuários, inventários e contagens continuam no `localStorage` por
enquanto — essa é só a primeira fatia migrada pro banco de verdade. Ver `CLAUDE.md` para
os detalhes técnicos.

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
