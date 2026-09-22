# Gestão de Estoques — Contexto do Projeto para Claude Code

PWA de **inventário cíclico industrial** (controle de estoque em almoxarifado). Três perfis: Operador, Líder de Estoque, Administrador. Pensado para tablets Android no chão de fábrica.

## Stack & Arquitetura

- **Front-end**: Single `index.html` com **React 18 + Babel Standalone** via CDN (sem build step por enquanto)
- **Estilo**: CSS puro com variáveis `:root` (sem Tailwind). Tipografia: Oswald, IBM Plex Sans, JetBrains Mono, Inter
- **Bibliotecas**: `html5-qrcode` (câmera QR/código de barras), `xlsx` (geração Excel)
- **Dados atuais**: 300 produtos em cache estático, `localStorage` para persistência local (não sincroniza entre aparelhos)
- **Backend**: Supabase planejado — schema SQL completo em `backend/schema.sql`, ainda não aplicado

## Estrutura Atual

```
index.html              → Tudo em um arquivo (React + Babel + CSS + dados)
painel-indicadores.html → Dashboard separado
preview-etiqueta.html   → Preview de etiqueta
manifest.json           → PWA config
service-worker.js       → Cache offline
backend/                → Schema Supabase (não aplicado ainda)
supabase/functions/     → Edge Functions (autenticação, sincronização — desenhadas, não ativas)
```

**Próximo passo grande**: Migrar para **Vite + React** modularizado (quebrar `index.html` em componentes, separar dados mock).

## Funcionalidades Implementadas

| Módulo | Status | Detalhes |
|---|---|---|
| **Login & Usuários** | ✅ Completo | Três perfis, bloqueio de usuário, histórico de senha |
| **Inventários** | ✅ Completo | 5 tipos: Aleatória, Manual, Rota, Curva ABC, Lista Importada (Excel) |
| **Contagem** | ✅ Completo | Câmera (QR/código de barras), contagem cega, endereço obrigatório |
| **Segunda Contagem** | ✅ Completo | Regras automáticas de recontagem e análise de divergência |
| **Importação Excel** | ✅ Completo | Upload de planilha padrão, parse client-side, validação |
| **Relatórios** | ✅ Completo | Excel (4 abas) + envio por e-mail (abre mailto:, sem anexo automático) |
| **Dashboard** | ✅ Completo | KPIs, últimas atividades, gráfico donut (desktop ≥1024px) |
| **Sincronização Supabase** | ⏳ Desenhado | Schema pronto, funções prontas, não aplicado |

## Regras Críticas (Negócio & UI)

### Endereço
- **Obrigatório** em qualquer contagem
- **Formato fixo Selgron**: `NNN-L-N` (ex: `035-A-1`) — máscara de entrada + regex

### Segunda Contagem (Módulo 7)
```
Divergência ≤ 5%       → Aprova automaticamente ✅
Divergência 5–15%      → Aguarda segunda contagem 🔄
Divergência > 15%      → Vai para análise do líder 📋
Segunda contagem == primeira? → Vai para líder de qualquer jeito 📋
```

### Permissões por Tela
| Ação | Operador | Líder | Admin |
|---|---|---|---|
| Contar itens | ✅ | ✅ | ✅ |
| Criar inventário | ❌ | ✅ | ✅ |
| Análise de divergência | ❌ | ✅ | ✅ |
| Foto + motivo divergência | ❌ | ✅ | ✅ |
| Gerenciar usuários | ❌ | ❌ | ✅ |
| Validar endereços propostos | ❌ | ✅ | ✅ |

### Persistência de Dados
- **Persiste em `localStorage`** (por aparelho): usuários, inventários, contagens, endereços propostos, histórico
- **NÃO persiste** (propositalmente): sessão de login, `view`/`flowState` (navegação)
  - Recarregar sempre volta pra login (segurança — tablet compartilhado)
  - Reabre no home, nunca no meio de um fluxo

## Design System

### CSS Classes & Variáveis
- Paleta: `--bg`, `--panel`, `--ink`, `--safety`, `--accent`, etc. — definidas em `:root`
- Layout mobile-first em tablets (topbar + bottom nav)
- Desktop sidebar + header em `@media (min-width:1024px)` — não há JS branchings por tamanho de tela
- Paleta **corporativa** (navy/branco/laranja) isolada em `.login-*` e `desktop-*` classes

### Ícones
- **Mobile/Operador**: Emoji (`Ic`)
- **Desktop/Dashboard**: SVG lineares mão-desenhados estilo Lucide (`DIcon`)

## Como Rodar

1. Abra `index.html` em qualquer navegador (Chrome ideal no Android)
2. Teste os três perfis de usuário disponíveis no sistema durante o desenvolvimento
3. Android: Chrome → menu → "Adicionar à tela inicial" → instala como PWA
4. iOS: "Adicionar à tela de início" via share → instala como PWA web (Safari não trata igual Android)

**HTTPS ou `localhost` obrigatório** para câmera (QR/código de barras) funcionar.

## O que Não Fazer (Restrições)

❌ **NÃO altere** regras de segunda contagem sem consultá-lo — são regras de negócio rígidas
❌ **NÃO remova** o `localStorage` sem plano de migração para Supabase
❌ **NÃO mude** o formato de endereço (`NNN-L-N`) sem aviso — hardcoded em regex/máscara
❌ **NÃO intente** aplicar Tailwind — design system usa CSS custom (não há `tailwind.config`)
❌ **NÃO retire** compatibilidade PWA (manifest, service-worker, ícones) — é requisito crítico

## Supabase (Próximo Passo)

Quando der, conectar backend real:

1. Criar projeto Supabase
2. Aplicar schema em `backend/schema.sql` (tabelas: `usuarios`, `produtos`, `estoque_saldo`, `enderecosPropostos`, etc.)
3. Congelar saldo ao criar inventário (função `congelar_saldo_inventario`)
4. Trocar `useState` do front-end por chamadas ao Supabase client
5. Configurar Edge Functions para sincronizar saldo com Protheus (scripts prontos em `supabase/functions/`)

Ver `backend/README.md` para passo a passo completo.

## Links Úteis

- **Produtos reais** (85.357 itens): já em Supabase, consultável via Edge Function `consultar-produto-selgron`
- **Catálogo em import manual**: `Manual → Busca por Código` já consulta Supabase se não achar nos 300 do cache
- **SB2 real** (saldo do Protheus): disponível via `backend/functions/sync-saldo-protheus` quando conectado
- **Relatório de SA** (Solicitação de Ajuste ao Almoxarifado): Excel formatado (cores, negrito, bordas) — usa `XLSXStyled` (fork do SheetJS)

## Decisão de Arquitetura Importante

**Sem build step por enquanto** = React/Babel/CDN em vez de npm install. Facilita iteração rápida via chat, mas limita modularização. Quando migrar para Vite:
- Mover React/CDN → `package.json` + Vite bundler
- Quebrar `index.html` em componentes (`src/components/`)
- Mover dados mock para `src/data/`
- Trocar CDN por npm packages (mesmo `html5-qrcode`, `xlsx`)

Planeje isso **juntos** — não é uma refatoração que se faça silenciosamente.

## Regra de Alterações

- Antes de alterar regras de negócio existentes, explique o impacto e aguarde confirmação.
- Antes de grandes refatorações, apresente o plano e aguarde confirmação.
- Para alterações visuais simples, pode implementar diretamente quando o pedido for claro.
- Não reescreva arquivos inteiros quando uma alteração localizada for suficiente.

---

**Mantenha este arquivo conciso.** Se adicionar nova seção, remova a menos importante — máximo 200 linhas.
