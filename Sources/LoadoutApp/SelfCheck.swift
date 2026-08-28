import Foundation
import LoadoutCore

/// `Loadout --self-check` drives the window's own model — the layer between the buttons and
/// the disk — against a throwaway home directory, then prints what happened.
///
/// The unit tests cover `LoadoutCore`; this covers the wiring the tests cannot reach, without
/// ever pointing at the real `~/.claude`.
@MainActor
enum SelfCheck {
    static func run() -> Never {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("loadout-self-check-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = Paths(home: root)
        try! FileManager.default.createDirectory(at: paths.skills, withIntermediateDirectories: true)
        let model = AppModel(paths: paths)
        var failures: [String] = []
        var total = 0

        func check(_ label: String, _ condition: @autoclosure () -> Bool) {
            total += 1
            let ok = condition()
            print("\(ok ? "✓" : "✗") \(label)")
            if !ok { failures.append(label) }
        }

        // Reading a document must not cost more the second time. The pane is rebuilt on every
        // state change — the scroll-spy alone produces a stream of them — and re-parsing a real
        // skill each time was two milliseconds a pass, a quarter of a frame, spent on text that
        // had not changed.
        let sample = String(repeating: "# Heading\n\nA paragraph with a few words in it.\n\n", count: 60)
        _ = MarkdownView.blocks(in: sample)
        let started = Date()
        for _ in 0..<50 { _ = MarkdownView.blocks(in: sample) }
        let each = Date().timeIntervalSince(started) / 50 * 1000
        check(String(format: "re-reading a document is free (%.2f ms)", each), each < 0.5)

        // The palettes, before anything touches the disk: five themes' worth of contrast and
        // the reading grounds' ordering, measured rather than trusted.
        for result in ThemeCheck.results() {
            check(result.label, result.passed)
        }

        // Create
        model.createSkill(name: "self-check-skill", description: "Created by the self-check.")
        check("creates a skill", model.items.contains { $0.name == "self-check-skill" })
        check("selects it", model.selected?.name == "self-check-skill")
        check("loads the file in the editor", model.draft.contains("name: self-check-skill"))

        // Edit and save
        model.draft = "---\nname: self-check-skill\ndescription: New résumé.\n---\n\nNew body."
        model.isDirty = true
        model.save()
        check("saves the edit", model.selected?.description == "New résumé.")
        check("clears the unsaved state", !model.isDirty)

        // Refuse invalid frontmatter
        model.draft = "---\ndescription: no name\n---\n"
        model.isDirty = true
        model.save()
        check("rejects invalid frontmatter", model.errorMessage != nil)
        check("doesn't damage the file", model.selected?.description == "New résumé.")
        // The refusal must not destroy the work it refused to save — a failed ⌘S used to
        // reload the disk copy over the draft.
        check("a failed save keeps the draft", model.draft.contains("no name"))
        check("a failed save keeps the dirty flag", model.isDirty)
        model.errorMessage = nil
        model.loadDraft()

        // A mutation elsewhere must not wipe an edit in progress either.
        model.draft = "---\nname: self-check-skill\ndescription: Half edited.\n---\n\nBody."
        model.isDirty = true
        model.reload()
        check("a reload keeps the dirty draft on the same item", model.draft.contains("Half edited"))
        model.loadDraft()

        // Disable and enable
        let created = model.items.first { $0.name == "self-check-skill" }!
        let selectionBeforeToggle = model.selectedID
        model.toggle(created)
        check("toggling keeps the selection", model.selectedID == selectionBeforeToggle)
        check(
            "disabling moves it to skills-off",
            FileManager.default.fileExists(
                atPath: paths.skillsOff.appendingPathComponent("self-check-skill/SKILL.md").path
            )
        )
        model.selection = .skills
        model.filter = .disabled
        check("appears under Disabled", model.visibleItems.count == 1)

        // Switching on is a question now: which assistants load it again is the one thing the
        // app cannot decide for someone, so the switch opens a sheet instead of guessing.
        let parked = model.items.first { $0.name == "self-check-skill" }!
        model.toggle(parked)
        check("enabling asks where it goes", model.restoring?.item.name == "self-check-skill")
        check("the sheet proposes what was recorded", model.restoring?.chosen == ["claude"])
        check("and says the proposal is remembered", model.restoring?.remembered == true)
        model.confirmRestore()
        check(
            "confirming brings it back",
            FileManager.default.fileExists(
                atPath: paths.skills.appendingPathComponent("self-check-skill/SKILL.md").path
            )
        )

        // Commands: made here rather than by hand in the Finder, switched off without deleting,
        // and no amber banner about a `name` field they are not supposed to have.
        model.selection = .commands
        model.createCommand(name: "self-check-command", description: "Created by the self-check.")
        let madeCommand = model.items.first { $0.kind == .command && $0.name == "self-check-command" }
        check("creates a command", madeCommand != nil)
        check("with no false warning on it", madeCommand?.warning == nil)
        check("and no name field in the file", !(model.draft.contains("name:")))
        model.toggle(madeCommand!)
        check(
            "disabling a command moves it next door",
            FileManager.default.fileExists(
                atPath: paths.claude.appendingPathComponent("commands-off/self-check-command.md").path
            )
        )
        let parkedCommand = model.items.first { $0.kind == .command && $0.name == "self-check-command" }!
        check("it stays in the list, switched off", !parkedCommand.enabled)
        model.toggle(parkedCommand)
        check(
            "enabling it asks nothing and puts it back",
            model.restoring == nil && FileManager.default.fileExists(
                atPath: paths.commands.appendingPathComponent("self-check-command.md").path
            )
        )
        model.selection = .skills

        // A skill a plugin ships: switched one at a time, so a plugin with 38 of them is not all
        // or nothing, and the choice outlives the plugin's next version.
        let install = paths.pluginCache.appendingPathComponent("official/vercel/0.45.1")
        for name in ["vercel-cli", "vercel-functions"] {
            let folder = install.appendingPathComponent("skills/\(name)")
            try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try! "---\nname: \(name)\ndescription: From the plugin.\n---\n\nBody.".write(
                to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
            )
        }
        try! JSONSerialization.data(withJSONObject: [
            "version": 2,
            "plugins": ["vercel@official": [[
                "scope": "user", "installPath": install.path, "version": "0.45.1",
            ]]],
        ]).write(to: paths.installedPlugins)
        model.reload()

        let pluginSkill = model.items.first { $0.name == "vercel-functions" }!
        check("a plugin skill knows which plugin it came from", pluginSkill.pluginID == "vercel@official")
        model.toggle(pluginSkill)
        check(
            "one plugin skill can be switched off on its own",
            FileManager.default.fileExists(
                atPath: install.appendingPathComponent("skills-off/vercel-functions/SKILL.md").path
            )
        )
        check(
            "the rest of the plugin is untouched",
            FileManager.default.fileExists(
                atPath: install.appendingPathComponent("skills/vercel-cli/SKILL.md").path
            )
        )
        check(
            "the choice is recorded against the plugin",
            model.mutations.records.pluginSkills(of: "vercel@official") == ["vercel-functions"]
        )
        check("the plugin's detail pane has something to show", {
            model.selectedPluginID = "vercel@official"
            return model.selectedPlugin.map { model.itemsOfPlugin($0).count } == 2
        }())
        model.toggle(model.items.first { $0.name == "vercel-functions" }!)
        check(
            "switching it back on forgets it, so updates leave it alone",
            model.mutations.records.pluginSkills(of: "vercel@official").isEmpty
        )
        // The page also has to say what the plugin *is*: where its folder is and what it brought.
        // Without those, "how do I get rid of this?" had no answer on the screen that was about it.
        check("the page can say what the plugin ships", {
            guard let plugin = model.selectedPlugin else { return false }
            return model.pluginContents(plugin).contains("skill")
                && model.readablePath(of: plugin).contains("plugins/cache/official/vercel")
        }())
        // Removing a whole plugin, on a second one installed for the purpose — the checks after this
        // one need a plugin to still be there, and a test that eats the fixture other tests read is
        // a test that breaks its neighbours.
        let doomed = paths.pluginCache.appendingPathComponent("official/doomed/1.2.0")
        let doomedSkill = doomed.appendingPathComponent("skills/doomed-skill")
        try! FileManager.default.createDirectory(at: doomedSkill, withIntermediateDirectories: true)
        try! "---\nname: doomed-skill\ndescription: Installed to be removed.\n---\n\nBody.".write(
            to: doomedSkill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
        )
        try! JSONSerialization.data(withJSONObject: [
            "version": 2,
            "plugins": [
                "vercel@official": [["scope": "user", "installPath": install.path, "version": "0.45.1"]],
                "doomed@official": [["scope": "user", "installPath": doomed.path, "version": "1.2.0"]],
            ],
        ]).write(to: paths.installedPlugins)
        model.reload()

        if let plugin = model.plugins.first(where: { $0.name == "doomed" }) {
            model.removePlugin(plugin)
            check("removing a plugin asks first", model.pendingPluginRemoval?.id == "doomed@official")
            check(
                "and nothing left while the note was up",
                FileManager.default.fileExists(atPath: doomed.path)
            )
            model.confirmRemovePlugin()
            check("confirming takes the folder away", !FileManager.default.fileExists(atPath: doomed.path))
            check("the entry leaves the register", !model.plugins.contains { $0.name == "doomed" })
            check("and the other plugin stays", model.plugins.contains { $0.name == "vercel" })
            check("with the dialog saying so", model.pluginRemovalDone && model.pluginRemovalError == nil)
            model.dismissPluginRemoval()
            check("closing it clears the dialog", model.pendingPluginRemoval == nil)
        }

        // Handing a command to the other assistant, through the same call the dot on the row makes.
        // Codex keeps its own in ~/.codex/prompts, so this is a link into one file rather than a
        // second copy to keep in step — and what does not travel is said in the status line.
        try! FileManager.default.createDirectory(
            at: paths.home.appendingPathComponent(".codex/prompts"), withIntermediateDirectories: true
        )
        model.reload()
        model.selection = .commands
        model.createCommand(name: "para-os-dois", description: "Vai para os dois.")
        let shared = model.items.first { $0.kind == .command && $0.name == "para-os-dois" }!
        check("the command starts in Claude only", shared.assistants == ["claude"])
        if let codex = model.assistants.first(where: { $0.id == "codex" }) {
            model.setAssistant(codex, on: shared, present: true)
            let linked = model.items.first { $0.kind == .command && $0.name == "para-os-dois" }
            check("giving it to Codex puts it in ~/.codex/prompts", FileManager.default.fileExists(
                atPath: paths.home.appendingPathComponent(".codex/prompts/para-os-dois.md").path
            ))
            check("as a link to the one file, not a second copy",
                  (try? FileManager.default.destinationOfSymbolicLink(
                      atPath: paths.home.appendingPathComponent(".codex/prompts/para-os-dois.md").path
                  )) != nil)
            check("and both dots light up", linked?.assistants == ["claude", "codex"])
            check("with the caveat said out loud",
                  model.statusMessage?.contains("frontmatter doesn't carry over") == true)

            model.setAssistant(codex, on: linked!, present: false)
            check("taking it back removes only the link", !FileManager.default.fileExists(
                atPath: paths.home.appendingPathComponent(".codex/prompts/para-os-dois.md").path
            ) && FileManager.default.fileExists(
                atPath: paths.commands.appendingPathComponent("para-os-dois.md").path
            ))
        }
        model.selection = .skills

        // Subagents and MCP servers: the last two kinds that could only be deleted, never switched
        // off. An agent is a file like a command; a server is a few lines inside ~/.claude.json.
        model.selection = .agents
        model.createCommand(name: "reviewer", description: "Reviews what everyone else writes.", kind: .agent)
        let agent = model.items.first { $0.kind == .agent && $0.name == "reviewer" }
        check("creates a subagent", agent != nil)
        model.toggle(agent!)
        check(
            "disabling a subagent moves it next door",
            FileManager.default.fileExists(
                atPath: paths.agentsOff.appendingPathComponent("reviewer.md").path
            )
        )
        let parkedAgent = model.items.first { $0.kind == .agent && $0.name == "reviewer" }!
        check("it stays listed, switched off", !parkedAgent.enabled)
        model.toggle(parkedAgent)
        check(
            "enabling puts it back",
            FileManager.default.fileExists(atPath: paths.agents.appendingPathComponent("reviewer.md").path)
        )

        try! JSONSerialization.data(withJSONObject: [
            "numStartups": 7,
            "mcpServers": ["notebooklm": ["command": "npx notebooklm-mcp"]],
        ]).write(to: paths.claudeJSON)
        model.reload()
        model.selection = .mcp
        let server = model.items.first { $0.kind == .mcp && $0.name == "notebooklm" }
        check("finds the MCP server", server != nil)
        model.toggle(server!)
        let afterOff = (try? JSONSerialization.jsonObject(with: Data(contentsOf: paths.claudeJSON)))
            as? [String: Any] ?? [:]
        check("disabling lifts its entry out of ~/.claude.json",
              (afterOff["mcpServers"] as? [String: Any])?["notebooklm"] == nil)
        check("and leaves the rest of that file alone", afterOff["numStartups"] as? Int == 7)
        let parkedServer = model.items.first { $0.kind == .mcp && $0.name == "notebooklm" }
        check("it stays listed, switched off", parkedServer?.enabled == false)
        model.toggle(parkedServer!)
        let afterOn = (try? JSONSerialization.jsonObject(with: Data(contentsOf: paths.claudeJSON)))
            as? [String: Any] ?? [:]
        check("enabling puts the entry back",
              (afterOn["mcpServers"] as? [String: Any])?["notebooklm"] != nil)
        model.selection = .skills

        // A skill that lives inside a repository. Loadout runs no git commands and knows nothing
        // about version control — but the folder it moves sits in someone's working tree, so the
        // first disable says so, once.
        let repo = paths.projectsRoot.appendingPathComponent("APPS/loadout")
        let repoSkill = repo.appendingPathComponent(".claude/skills/from-repo")
        try! FileManager.default.createDirectory(at: repoSkill, withIntermediateDirectories: true)
        try! "---\nname: from-repo\ndescription: From the repository.\n---\n\nBody.".write(
            to: repoSkill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
        )
        try! FileManager.default.createDirectory(
            at: paths.projectsRoot, withIntermediateDirectories: true
        )
        // The repository is a repository because it holds a `.claude`, which is what the search
        // looks for — the same rule a real machine is judged by, rather than a listing file.
        let projectModel = AppModel(paths: paths, roots: ProjectRoots(folders: [paths.projectsRoot]))
        projectModel.hasSeenProjectSkillWarning = false
        projectModel.changeContext(to: projectModel.projects.first)
        let fromRepo = projectModel.items.first { $0.name == "from-repo" }!
        projectModel.toggle(fromRepo)
        check("a project skill warns before moving anything", projectModel.pendingProjectDisable != nil)
        check(
            "and nothing moved while the warning was up",
            FileManager.default.fileExists(atPath: repoSkill.appendingPathComponent("SKILL.md").path)
        )
        projectModel.confirmProjectDisable(rememberChoice: true)
        check(
            "confirming parks it inside the repository",
            FileManager.default.fileExists(
                atPath: repo.appendingPathComponent(".claude/skills-off/from-repo/SKILL.md").path
            )
        )
        // Out of the repository and into your own, as a copy: the project keeps what it had. The
        // first one asks before copying, because from then on there are two files, not one.
        let repoCopy = projectModel.items.first { $0.name == "from-repo" }!
        projectModel.makeGlobal(repoCopy)
        check("making something global asks first", projectModel.pendingMakeGlobal?.name == "from-repo")
        check(
            "and nothing was copied while the note was up",
            !FileManager.default.fileExists(
                atPath: paths.skills.appendingPathComponent("from-repo/SKILL.md").path
            )
        )
        projectModel.confirmMakeGlobal()
        check(
            "making a project skill global copies it to your own",
            FileManager.default.fileExists(
                atPath: paths.skills.appendingPathComponent("from-repo/SKILL.md").path
            )
        )
        check("the callout knows the copy is there", projectModel.hasGlobalCopy(of: repoCopy))
        check(
            "and the dialog says where it landed",
            projectModel.makeGlobalDestination?.hasSuffix("/.claude/skills/from-repo") == true
        )
        projectModel.dismissMakeGlobal()
        check("closing it clears the dialog", projectModel.pendingMakeGlobal == nil)
        check(
            "and the project keeps its own",
            FileManager.default.fileExists(
                atPath: repo.appendingPathComponent(".claude/skills-off/from-repo/SKILL.md").path
            )
        )

        projectModel.toggle(projectModel.items.first { $0.name == "from-repo" }!)
        check(
            "and the second time it does not ask again",
            projectModel.pendingProjectDisable == nil
                && FileManager.default.fileExists(
                    atPath: repo.appendingPathComponent(".claude/skills/from-repo/SKILL.md").path
                )
        )

        // Arriving at a tab must never mean arriving at an empty pane: every one of them lands on
        // its first row, the Plugins tab included — it keeps a selection of its own.
        for tab in [Selection.skills, .commands, .agents, .mcp] {
            model.selection = tab
            check("\(tab.rawValue) opens with something selected",
                  model.visibleItems.isEmpty || model.selectedID != nil)
        }
        model.selection = .plugins
        check("plugins opens with a plugin selected", model.selectedPlugin != nil)
        check("and its detail has something to show",
              model.selectedPlugin.map { !model.itemsOfPlugin($0).isEmpty } == true)
        model.selection = .skills

        // The third position of the scope button: everything at once, each row still knowing where
        // it lives — which is what the tag on it reads from.
        projectModel.showEverything()
        let everything = projectModel.items.filter { $0.kind == .skill }
        check("everything holds the personal ones", everything.contains { $0.origin == .personal })
        check("and the project's", everything.contains { $0.origin == .project("loadout") })
        check("with their origins intact, which is what the tags read",
              Set(everything.map(\.origin.label)).count > 1)
        projectModel.changeContext(to: nil)
        check("and Global goes back to being only yours",
              !projectModel.items.contains { if case .project = $0.origin { return true } else { return false } })

        // Every write left a snapshot behind
        let backups = (FileManager.default.enumerator(at: paths.backups, includingPropertiesForKeys: nil)?
            .compactMap { ($0 as? URL)?.lastPathComponent } ?? [])
        check("leaves backups", backups.contains("SKILL.md"))

        // Search
        model.selection = .skills
        model.filter = .all
        model.query = "RESUME"
        check("searches without accents or case", model.visibleItems.count == 1)
        model.query = "this doesn't exist"
        check("filters out nonmatches", model.visibleItems.isEmpty)
        model.query = ""

        // Switching kind resets the filters: an assistant filter set on Skills used to
        // silently empty Commands, with the control that caused it not even rendered there.
        model.assistantFilter = .one("claude")
        model.selection = .commands
        check("tab change resets the assistant filter", model.assistantFilter == .any)
        check("tab change resets the funnel", model.filter == .all)
        model.selection = .skills

        // Chip counts follow every narrowing the list itself follows — the "All 56 over an
        // empty list" bug was the counts ignoring the assistant menu.
        model.assistantFilter = .one("no-such-assistant")
        check("empty assistant empties the list", model.visibleItems.isEmpty)
        check("chip counts follow the assistant filter", model.count(for: .all) == 0)
        model.assistantFilter = .any
        model.query = "this doesn't exist"
        check("chip counts follow the search too", model.count(for: .all) == 0)
        model.query = ""
        check("chip counts recover with the filters cleared", model.count(for: .all) == model.visibleItems.count)

        // The conversation's changes reaching the document. No CLI is run here — what is being
        // checked is the part Loadout owns: a change accepted in a copy of the folder becomes an
        // unsaved edit, and only Save writes it, with the snapshot every write takes.
        model.select(model.items.first { $0.name == "self-check-skill" }?.id)
        let skill = model.selected!
        let folder = skill.path!.deletingLastPathComponent()
        let workspaces = AskWorkspaces(paths: paths)
        let workspace = try! workspaces.open(itemID: skill.id, origin: folder)
        // Stand in for the assistant: change the document, and add a script beside it.
        let onDisk = try! String(contentsOf: skill.path!, encoding: .utf8)
        try! onDisk.replacingOccurrences(of: "New résumé.", with: "Rewritten by the assistant.")
            .write(to: workspace.root.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try! "#!/bin/sh\necho hello\n".write(
            to: workspace.root.appendingPathComponent("run.sh"), atomically: true, encoding: .utf8
        )

        check("the real folder is untouched by the copy",
              (try? String(contentsOf: skill.path!, encoding: .utf8)) == onDisk)

        model.showsAskPanel = true
        model.ask.open(itemID: skill.id, cli: AssistantCLI(
            id: "claude", label: "Claude Code",
            executable: URL(fileURLWithPath: "/usr/bin/true"),
            argumentTemplate: "-p {prompt}", isCustom: false
        ), origin: folder)
        model.ask.adoptWorkspaceForChecking(workspace)
        model.ask.refreshProposals()
        check("finds both changed files", model.ask.proposals.map(\.id).sorted() == ["SKILL.md", "run.sh"])
        check("nothing is decided yet", model.ask.pendingCount > 0)
        check("an undecided change keeps the working copy",
              (try? workspaces.remove(itemID: skill.id, hasPendingBlocks: model.ask.hasPendingBlocks)) == nil)

        // The document's changes are shown in the document itself, which means the pane has to be
        // in editing rather than reading, and the shown text has to hold both sides of the change.
        check("a proposed change puts the pane into editing", !model.showsPreview)
        check("the document shows both sides of the change",
              model.reviewLayout?.text.contains("New résumé.") == true &&
              model.reviewLayout?.text.contains("Rewritten by the assistant.") == true)
        check("each change has a place for its buttons", model.reviewLayout?.pendingRanges.count == 1)

        let document = model.ask.proposals.first { $0.id == "SKILL.md" }!
        model.ask.acceptAll(in: document.id)
        check("deciding everything gives the editor back", model.reviewLayout == nil)
        check("accepting changes the document being edited", model.draft.contains("Rewritten by the assistant."))
        check("accepting leaves it unsaved, for you to decide", model.isDirty)
        check("accepting has not touched the file yet",
              (try? String(contentsOf: skill.path!, encoding: .utf8)) == onDisk)

        model.ask.acceptAll(in: "run.sh")
        model.save()
        check("saving writes the document",
              (try? String(contentsOf: skill.path!, encoding: .utf8))?
                  .contains("Rewritten by the assistant.") == true)
        check("saving also writes the accepted file beside it",
              (try? String(contentsOf: folder.appendingPathComponent("run.sh"), encoding: .utf8)) ==
                  "#!/bin/sh\necho hello\n")

        // A rejected change must never reach the file, even once its neighbour is accepted.
        try! onDisk.replacingOccurrences(of: "New body.", with: "Unwanted rewrite.")
            .write(to: workspace.root.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        model.ask.refreshProposals()
        let again = model.ask.proposals.first { $0.id == "SKILL.md" }!
        model.ask.rejectAll(in: again.id)
        model.save()
        check("a rejected change is never written",
              (try? String(contentsOf: skill.path!, encoding: .utf8))?
                  .contains("Unwanted rewrite.") == false)

        try? workspaces.remove(itemID: skill.id, hasPendingBlocks: false)
        model.showsAskPanel = false

        // Delete
        model.select(model.items.first { $0.name == "self-check-skill" }?.id)
        model.deleteSelected()
        check("deleting removes it from the list", !model.items.contains { $0.name == "self-check-skill" })

        print(failures.isEmpty
              ? "\nAll good: \(total) checks passed."
              : "\n\(failures.count) of \(total) checks failed: \(failures.joined(separator: ", "))")
        exit(failures.isEmpty ? 0 : 1)
    }
}
