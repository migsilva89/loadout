# Loadout — especificação

App Mac nativa para ver e gerir a configuração do Claude Code: skills, comandos, agentes, plugins e MCP servers. Substitui o nome de trabalho *SkillDeck*.

**Porque existe.** A dor é "não sei o que tenho". São 21 skills pessoais, mais de 40 vindas de plugins, comandos, agentes e MCP servers espalhados por quatro sítios no disco. O Loadout é o inventário — e, porque ver sem poder mexer irrita, também o editor.

**O nome.** *Loadout* é o equipamento que levas para uma missão. É exatamente o que a app mostra: o que o Claude leva para uma sessão, e o que ficou em casa.

---

## Decisões fechadas

| Assunto | Decisão |
|---|---|
| Âmbito | Skills pessoais e de projeto, slash commands, subagentes, plugins, MCP servers |
| Form factor | App Mac nativa SwiftUI, janela normal no Dock |
| Escrita | Completa: criar, editar, apagar, mover, ativar/desativar |
| Desativar skill | Mover a pasta para `~/.claude/skills-off/` |
| Desativar plugin | `enabledPlugins` em `~/.claude/settings.local.json` |
| Rede de segurança | Snapshot em `~/.claude/.loadout-backups/<ISO>/` antes de cada escrita |
| Uso | Índice SQLite dos transcripts, 90 dias por omissão, botão para varrer tudo |
| Copiloto | `claude -p` em headless, a pedido, secundário na UI |
| UX | Sidebar de fontes com contagens · lista com badge de origem e uso · detalhe com o ficheiro em bruto |
| Destino | Pessoal, mas escrito para poder sair: sem caminhos hardcoded, com README |

## Fontes de dados no disco

| O quê | Onde |
|---|---|
| Skills pessoais | `~/.claude/skills/<nome>/SKILL.md` |
| Skills desativadas | `~/.claude/skills-off/<nome>/SKILL.md` |
| Skills de projeto | `<repo>/.claude/skills/<nome>/SKILL.md` |
| Skills de plugin | `~/.claude/plugins/cache/<mkt>/<plugin>/<versão>/skills/<nome>/SKILL.md` |
| Comandos | `~/.claude/commands/*.md`, `<repo>/.claude/commands/*.md`, `<plugin>/commands/*.md` |
| Agentes | `~/.claude/agents/*.md`, `<repo>/.claude/agents/*.md`, `<plugin>/agents/*.md` |
| Plugins instalados | `~/.claude/plugins/installed_plugins.json` |
| Plugins ativos | `enabledPlugins` em `~/.claude/settings.json` e `settings.local.json` |
| MCP servers | `mcpServers` em `~/.claude.json` (global e por projeto) |
| Projetos | `~/Projects/INDEX.md` — tabelas markdown, primeira coluna com o caminho relativo |
| Uso | `~/.claude/projects/**/*.jsonl` |

Sinais de uso, por tipo de item:

- **Skill** — `tool_use` com `name: "Skill"` e `input.skill` igual ao nome.
- **Comando** — `<command-name>/nome` no conteúdo das mensagens de utilizador.
- **Agente** — `"subagent_type":"nome"` no input de um `tool_use`.
- **MCP** — `tool_use` cujo nome começa por `mcp__<servidor>__`.

Cada registo tem `timestamp` e `cwd`, o que dá recência e em que projetos disparou.

---

## Critérios de aceitação

Cada AC é verificável. `[T]` significa coberto por teste automático; `[M]` significa verificado por mim na app a correr.

### AC1 — Inventário

- **AC1.1** `[T]` A app encontra as skills pessoais em `~/.claude/skills`, uma por pasta com `SKILL.md`, e lê `name` e `description` do frontmatter YAML.
- **AC1.2** `[T]` Frontmatter inválido ou ausente não faz a app falhar: o item aparece com o nome da pasta e um aviso visível no detalhe.
- **AC1.3** `[T]` Skills em `~/.claude/skills-off` aparecem marcadas como desativadas.
- **AC1.4** `[T]` Skills de plugins são encontradas na versão instalada de cada plugin, e atribuídas ao plugin certo.
- **AC1.5** `[T]` Comandos, agentes e MCP servers são inventariados das três origens (pessoal, projeto, plugin) quando aplicável.
- **AC1.6** `[T]` A lista de projetos vem de `~/Projects/INDEX.md`; se o ficheiro não existir, a app funciona só com Global.
- **AC1.7** `[M]` A sidebar mostra contagens por fonte, e elas somam com o que a lista mostra.

### AC2 — Vista e navegação

- **AC2.1** `[M]` Janela de três colunas: fontes, lista, detalhe. Redimensionável, larguras mantidas entre arranques.
- **AC2.2** `[M]` O selector no topo alterna entre Global e um projeto. Em projeto, a lista mostra o que o Claude veria nessa pasta: globais mais as do repo mais as de plugins ativos.
- **AC2.3** `[M]` Cada linha da lista mostra nome, badge de origem e a descrição com o número de usos ao fim. Desativadas aparecem esbatidas.
- **AC2.4** `[T]` A pesquisa filtra por nome e por descrição, sem distinguir maiúsculas nem acentos, e atualiza a lista a cada tecla.
- **AC2.5** `[M]` O detalhe mostra nome, tipo, origem, caminho, data de alteração, o conteúdo em bruto do ficheiro, e a linha de uso.
- **AC2.6** `[M]` Modo claro e escuro, ambos legíveis, a seguir a preferência do sistema.
- **AC2.7** `[M]` Navegação de teclado: setas para percorrer a lista, `⌘F` para a pesquisa, `⌘N` para nova skill, `⌘⌫` para apagar.

### AC3 — Ativar e desativar

- **AC3.1** `[T]` Desativar uma skill pessoal move a pasta para `~/.claude/skills-off/<nome>`, com todo o conteúdo intacto.
- **AC3.2** `[T]` Reativar move de volta para `~/.claude/skills`.
- **AC3.3** `[T]` Se o destino já existir, a operação falha com erro claro e não destrói nada.
- **AC3.4** `[T]` Desativar um plugin escreve `enabledPlugins["<plugin>@<mkt>"] = false` em `settings.local.json`, preservando o resto do ficheiro tal como estava.
- **AC3.5** `[T]` Skills de plugin não podem ser desativadas individualmente; a app explica que o interruptor é o do plugin.
- **AC3.6** `[M]` O estado no ecrã reflete o disco imediatamente após a operação.

### AC4 — Editar, criar, apagar

- **AC4.1** `[M]` O detalhe tem um editor do `SKILL.md` com tipo monoespaçado, e guarda com `⌘S`.
- **AC4.2** `[T]` Guardar valida o frontmatter: `name` e `description` obrigatórios, `name` em kebab-case. Inválido não grava e explica porquê.
- **AC4.3** `[T]` Criar uma skill nova gera `~/.claude/skills/<nome>/SKILL.md` a partir de template, com o nome validado e sem sobrescrever nada.
- **AC4.4** `[T]` Apagar move a pasta para o Lixo, não faz `rm`.
- **AC4.5** `[M]` "Abrir no editor" abre o ficheiro na aplicação por omissão do sistema.
- **AC4.6** `[T]` Ficheiros de plugin são só de leitura: tentar gravar devolve erro e não toca no disco.

### AC5 — Rede de segurança

- **AC5.1** `[T]` Antes de qualquer escrita, mover ou apagar, é criada uma cópia em `~/.claude/.loadout-backups/<ISO-8601>/<caminho-relativo>`.
- **AC5.2** `[T]` O snapshot preserva a árvore completa da pasta, não só o `SKILL.md`.
- **AC5.3** `[M]` O menu tem "Revelar backups no Finder".
- **AC5.4** `[T]` Se o snapshot falhar, a escrita é abortada — nunca se escreve sem cópia feita.

### AC6 — Índice de uso

- **AC6.1** `[T]` O índice lê `~/.claude/projects/**/*.jsonl` e conta usos de skills, comandos, agentes e MCP servers.
- **AC6.2** `[T]` A indexação é incremental: um ficheiro cujo tamanho e data não mudaram não é relido.
- **AC6.3** `[T]` Por omissão só entram registos dos últimos 90 dias; existe uma ação para indexar o histórico completo.
- **AC6.4** `[M]` A primeira indexação corre em segundo plano com progresso visível, e a app permanece utilizável.
- **AC6.5** `[T]` Cada item sabe: total de usos, data do último uso, e em quantos projetos distintos disparou.
- **AC6.6** `[T]` Um ficheiro de transcript corrompido a meio não interrompe a indexação do resto.
- **AC6.7** `[M]` A lista pode ser ordenada por nome ou por número de usos.

### AC7 — Copiloto

- **AC7.1** `[M]` Um botão "Pedir ao Claude" no detalhe abre uma folha onde escrevo o que quero, e corre `claude -p` na pasta da skill.
- **AC7.2** `[T]` Se o binário `claude` não estiver no PATH, a app diz isso em vez de falhar em silêncio.
- **AC7.3** `[M]` A resposta aparece na folha e nada é escrito no disco sem eu confirmar.
- **AC7.4** `[T]` O processo tem timeout e pode ser cancelado; cancelar mata o processo filho.

### AC8 — Reagir ao disco

- **AC8.1** `[M]` Alterar um `SKILL.md` fora da app atualiza a vista sem eu ter de recarregar.
- **AC8.2** `[M]` Criar ou apagar uma pasta de skill fora da app atualiza as contagens.
- **AC8.3** `[T]` A releitura é coalescida: muitas alterações seguidas não disparam muitos varrimentos.

### AC9 — Qualidade e entrega

- **AC9.1** `[T]` `swift test` passa, sem testes ignorados.
- **AC9.2** `[T]` Os testes correm contra uma árvore temporária, nunca contra o `~/.claude` real.
- **AC9.3** `[M]` `Scripts/build-app.sh` produz `dist/Loadout.app` que abre com duplo clique.
- **AC9.4** `[M]` A app tem ícone próprio no Dock e no Finder.
- **AC9.5** `[M]` Nenhum caminho de utilizador está hardcoded no código; tudo deriva de `FileManager.homeDirectoryForCurrentUser` ou de configuração.
- **AC9.6** `[M]` README com o que é, como construir, como correr os testes.

---

## Arquitetura

```
Loadout/
├─ Package.swift
├─ Sources/
│  ├─ LoadoutCore/          biblioteca sem UI, testável
│  │  ├─ Model.swift        Item, Kind, Origin, Scope
│  │  ├─ Paths.swift        raiz configurável, zero caminhos fixos
│  │  ├─ Frontmatter.swift  parser YAML mínimo, tolerante
│  │  ├─ Scanner.swift      varre skills, comandos, agentes, plugins, MCP
│  │  ├─ Projects.swift     lê INDEX.md
│  │  ├─ Mutations.swift    ativar, desativar, gravar, criar, apagar
│  │  ├─ Backups.swift      snapshots
│  │  ├─ UsageIndex.swift   SQLite incremental sobre os transcripts
│  │  ├─ Copilot.swift      claude -p
│  │  └─ Watcher.swift      FSEvents com coalescing
│  └─ LoadoutApp/           SwiftUI
└─ Tests/LoadoutCoreTests/
```

`Paths` recebe a raiz por injeção. É isso que permite testar tudo contra uma pasta temporária (AC9.2) e é a razão pela qual não há caminhos hardcoded (AC9.5).

## Fora de âmbito

Hooks, permissões e o resto do `settings.json`. Histórico de sessões. Sincronização entre máquinas. Assinatura e notarização — a app corre localmente, sem Developer ID.
