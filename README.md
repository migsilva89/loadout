<img src="Resources/logo-light.png#gh-light-mode-only" width="280" alt="Loadout"><img src="Resources/logo-dark.png#gh-dark-mode-only" width="280" alt="Loadout">

App Mac para ver e gerir a configuração do Claude Code: skills, comandos, agentes, plugins e MCP servers, com o uso real de cada um.

*Loadout* é o equipamento que se leva para uma missão — que é o que a app mostra: o que o Claude leva para uma sessão, e o que ficou em casa.

## O que faz

- **Inventário completo.** Skills pessoais (incluindo as que estão por symlink), skills de projeto, tudo o que vem de plugins, slash commands, subagentes e MCP servers.
- **Uso real.** Lê os transcripts das sessões e diz quantas vezes cada coisa disparou, quando foi a última, e em quantos projetos. Ordena por aí, para se ver o que nunca é usado.
- **Contexto.** O selector no topo responde a "o que é que o Claude vê se eu abrir nesta pasta?".
- **Gestão.** Criar, editar, apagar e desativar. Desativar uma skill é movê-la para `~/.claude/skills-off/`; desativar um plugin escreve o `enabledPlugins`.
- **Rede de segurança.** Antes de qualquer escrita fica uma cópia em `~/.claude/.loadout-backups/<data>/`. Se a cópia falhar, não se escreve. Apagar vai para o Lixo, nunca é `rm`.
- **Copiloto.** O botão "Pedir ao Claude" corre `claude -p` na pasta da skill. Usa a subscrição que já tens, e nada é escrito sem confirmares.

## Construir

```bash
./Scripts/build-app.sh
open dist/Loadout.app
```

Precisa de Xcode e macOS 14 ou mais recente. Para iterar mais depressa, `./Scripts/build-app.sh --debug`.

O ícone e o logótipo são desenhados por código:

```bash
swift Scripts/make-icon.swift
```

## Testar

```bash
swift test
```

49 testes sobre `LoadoutCore`, todos contra árvores temporárias — nunca tocam no `~/.claude` real.

A camada entre os botões e o disco tem a sua própria verificação, que corre o modelo da janela contra um `~` descartável:

```bash
.build/debug/LoadoutApp --self-check
```

Para ver os dois temas sem mexer nas preferências do sistema:

```bash
LOADOUT_APPEARANCE=light ./dist/Loadout.app/Contents/MacOS/Loadout
```

## Como está feito

```
Sources/
├─ LoadoutCore/     biblioteca sem UI, é aqui que estão as regras e os testes
│  ├─ Paths           todos os caminhos, injetados — é o que permite testar a sério
│  ├─ Frontmatter     leitor de YAML tolerante, incluindo blocos > e |
│  ├─ InventoryScanner varre skills, comandos, agentes, plugins e MCP
│  ├─ Mutations       criar, gravar, mover, apagar — sempre depois de um snapshot
│  ├─ UsageIndex      SQLite incremental sobre os transcripts
│  ├─ Copilot         claude -p, com timeout e cancelamento
│  └─ Watcher         FSEvents com coalescing
└─ LoadoutApp/      SwiftUI
```

`Paths` recebe a raiz por injeção, e é essa única indireção que mantém os testes longe da configuração real e o código sem caminhos fixos.

A especificação, com os critérios de aceitação um a um, está em [docs/SPEC.md](docs/SPEC.md).

## Estado

Corre localmente, assinada ad hoc. Sem Developer ID, sem notarização.
