import AppKit
import Foundation
import LoadoutCore

/// Scripted walkthroughs of the app, for the pictures on the README and anywhere else the app has
/// to be shown rather than described.
///
/// The app drives itself through the same calls its buttons make — `select`, `toggle`,
/// `setAssistant` — with a pause between steps long enough to read. Nothing is faked and nothing is
/// re-enacted afterwards: what the recording shows is the program doing the thing.
///
/// Named `Walkthrough` rather than `Scene`: SwiftUI already has a `Scene`, and shadowing it makes
/// `var body: some Scene` in the app's own entry point stop compiling with an error that points
/// nowhere near here.
///
/// There is no pointer in the picture, because moving the real one needs a permission a script
/// cannot be granted. Each step is written to make its own effect obvious instead: the selection
/// moves, a switch flips, a mark lights up.
@MainActor
enum Walkthrough {
    /// One thing to do, how long to sit on the result, and — for a recording — which control on
    /// screen it was about.
    ///
    /// `on` names a control by the same names `Spotlight` publishes. It is read *before* the
    /// action runs, because that is when the thing being acted on is still known: after
    /// `model.toggle(item)` the item may have left the list. The rectangle is read afterwards,
    /// once the window has settled, since that is when the control is where it ends up.
    struct Step {
        let hold: TimeInterval
        let action: (AppModel) -> Void
        let on: ((AppModel) -> String?)?

        init(
            hold: TimeInterval = 1.4,
            on: ((AppModel) -> String?)? = nil,
            _ action: @escaping (AppModel) -> Void
        ) {
            self.hold = hold
            self.action = action
            self.on = on
        }
    }

    /// Every scene by the name `LOADOUT_SCENE` takes. `all` plays them in order, for one long
    /// recording; the rest are the short ones a web page can use on their own.
    static let names = ["browse", "toggle", "plugin", "share", "ask", "mcp", "all", "switches", "tour", "lastswitches"]

    static func steps(named name: String) -> [Step] {
        switch name {
        case "browse": return browse
        case "toggle": return toggle
        case "share": return share
        case "ask": return ask
        case "plugin": return plugin
        case "mcp": return mcp
        case "all": return browse + toggle + plugin + share + ask
        case "switches": return switches
        case "tour": return tour
        case "lastswitches": return lastSwitches
        default: return []
        }
    }

    // MARK: - The scenes

    /// What the app is: a list of everything loaded, and what one of them says.
    private static var browse: [Step] {
        [
            Step(hold: 2.0, on: { _ in Spotlight.tab(Selection.skills.title) }) { model in
                model.selection = .skills
                model.showsPreview = true
            },
            Step(on: { Spotlight.row($0.visibleItems.first?.id ?? "") }) {
                $0.select($0.visibleItems.first?.id)
            },
            Step(on: { Spotlight.row($0.visibleItems.dropFirst().first?.id ?? "") }) {
                $0.select($0.visibleItems.dropFirst().first?.id)
            },
            Step(hold: 2.0, on: { Spotlight.row($0.visibleItems.dropFirst(2).first?.id ?? "") }) {
                $0.select($0.visibleItems.dropFirst(2).first?.id)
            },
            // The other kinds, so it is clear this is not only about skills.
            Step(hold: 1.8, on: { _ in Spotlight.tab(Selection.commands.title) }) { $0.selection = .commands },
            Step(hold: 1.8, on: { _ in Spotlight.tab(Selection.agents.title) }) { $0.selection = .agents },
            Step(hold: 2.0, on: { _ in Spotlight.tab(Selection.skills.title) }) { $0.selection = .skills },
        ]
    }

    /// Turning a skill off and on again — the thing the app exists for, and the one that shows it
    /// is a manager rather than a viewer.
    private static var toggle: [Step] {
        [
            Step(hold: 1.6, on: { Spotlight.row($0.visibleItems.first?.id ?? "") }) { model in
                model.selection = .skills
                model.select(model.visibleItems.first?.id)
            },
            Step(hold: 2.2, on: { Spotlight.toggle($0.selected?.id ?? "") }) { model in
                guard let item = model.selected else { return }
                model.toggle(item)
            },
            Step(hold: 1.6) { model in
                // It moved to Disabled, so follow it there rather than pretending it vanished.
                model.filter = .disabled
            },
            Step(hold: 2.2, on: { Spotlight.toggle($0.visibleItems.first?.id ?? "") }) { model in
                guard let item = model.visibleItems.first else { return }
                // Straight back on, without the sheet: switching on asks which assistants should
                // load it again, and a sheet is a window of its own that the recorder reads back
                // blank — a frozen picture would be a worse lie than a shorter demo.
                model.restoring = RestoringSkill(
                    item: item, chosen: Set(item.assistants.isEmpty ? ["claude"] : item.assistants),
                    remembered: true
                )
                model.confirmRestore()
            },
            Step(hold: 1.6) { $0.filter = .all },
        ]
    }

    /// Trimming a plugin: the thing you could not do at all before — a plugin that ships several
    /// skills no longer forces all of them.
    private static var plugin: [Step] {
        [
            Step(hold: 1.8, on: { _ in Spotlight.tab(Selection.plugins.title) }) { model in
                model.selection = .plugins
                model.selectedPluginID = model.plugins.first?.id
            },
            Step(hold: 2.4, on: { model in
                guard let plugin = model.selectedPlugin,
                      let first = model.itemsOfPlugin(plugin).first(where: { $0.kind == .skill })
                else { return nil }
                return Spotlight.toggle(first.id)
            }) { model in
                guard let plugin = model.selectedPlugin,
                      let first = model.itemsOfPlugin(plugin).first(where: { $0.kind == .skill })
                else { return }
                model.toggle(first)
            },
            Step(hold: 2.2, on: { Spotlight.row($0.items.first { $0.pluginID != nil }?.id ?? "") }) { model in
                // And back in the Skills list, where the same switch and the plugin's tag are.
                model.selection = .skills
                model.select(model.items.first { $0.pluginID != nil }?.id)
            },
        ]
    }

    /// Putting one skill on another assistant, which is a symlink to a single copy rather than a
    /// second copy to keep in step.
    private static var share: [Step] {
        [
            Step(hold: 1.6, on: { Spotlight.row($0.visibleItems.first?.id ?? "") }) { model in
                model.selection = .skills
                model.showsPreview = true
                model.select(model.visibleItems.first?.id)
            },
            Step(hold: 2.4, on: { model in
                guard let item = model.selected,
                      let assistant = model.assistants.first(where: { !item.assistants.contains($0.id) })
                else { return nil }
                return Spotlight.assistant(assistant.id)
            }) { model in
                guard let item = model.selected,
                      let assistant = model.assistants.first(where: { !item.assistants.contains($0.id) })
                else { return }
                model.setAssistant(assistant, on: item, present: true)
            },
            Step(hold: 2.4, on: { model in
                guard let item = model.selected,
                      let assistant = model.assistants.first(where: { item.assistants.contains($0.id) && $0.id != "claude" })
                else { return nil }
                return Spotlight.assistant(assistant.id)
            }) { model in
                guard let item = model.selected,
                      let assistant = model.assistants.first(where: { item.assistants.contains($0.id) && $0.id != "claude" })
                else { return }
                model.setAssistant(assistant, on: item, present: false)
            },
        ]
    }

    /// Every surface the 2026-08-15 switches work added, held long enough to be photographed:
    /// the assistant sheet that asks where a skill comes back to, a plugin's own detail with its
    /// skills, and the Commands tab now that commands have switches of their own.
    private static var switches: [Step] {
        [
            Step(hold: 1.4) { model in
                model.selection = .skills
                model.showsPreview = true
                model.select(model.visibleItems.first?.id)
            },
            // A shared skill off, then on — which is what opens the sheet.
            Step(hold: 1.6) { model in
                guard let shared = model.items.first(where: { $0.assistants.count > 1 }) else { return }
                model.select(shared.id)
                model.toggle(shared)
            },
            Step(hold: 2.6) { model in
                guard let parked = model.items.first(where: { $0.kind == .skill && !$0.enabled })
                else { return }
                model.toggle(parked)
            },
            Step(hold: 1.4) { model in
                model.confirmRestore()
            },
            // A plugin's own detail, with a switch per skill.
            Step(hold: 2.4) { model in
                model.selection = .plugins
                model.selectedPluginID = model.plugins.first?.id
            },
            // And the commands, which now have switches and the other assistants' half.
            Step(hold: 2.4) { model in
                model.selection = .commands
                model.select(model.visibleItems.first?.id)
            },
        ]
    }

    /// One MCP server switched off and left where it was. `lastswitches` also does this, but it
    /// does a subagent first, and a clip that belongs under a heading about MCP servers cannot
    /// open on something else.
    private static var mcp: [Step] {
        [
            Step(hold: 2.0, on: { _ in Spotlight.tab(Selection.mcp.title) }) { model in
                model.selection = .mcp
                model.select(model.visibleItems.first?.id)
            },
            Step(hold: 2.8, on: { Spotlight.toggle($0.visibleItems.first?.id ?? "") }) { model in
                guard let server = model.visibleItems.first else { return }
                model.toggle(server)
            },
            // The second one, so it is clear the switch belongs to each server and not to the app.
            Step(hold: 2.4, on: { Spotlight.row($0.visibleItems.dropFirst().first?.id ?? "") }) { model in
                model.select(model.visibleItems.dropFirst().first?.id)
            },
        ]
    }

    /// Every tab and every state worth a photograph, held long enough to be one. This is what a
    /// check of the whole window looks like when nobody can sit in front of it.
    private static var tour: [Step] {
        [
            Step(hold: 1.8) { model in
                model.selection = .skills
                model.showsPreview = true
                model.select(model.visibleItems.first?.id)
            },
            // A skill with unreadable frontmatter still lists, and says so in the detail.
            Step(hold: 1.8) { model in
                model.select(model.items.first { $0.warning != nil }?.id)
            },
            // The funnel, on the one that is parked off.
            Step(hold: 1.8) { model in
                model.filter = .disabled
                model.select(model.visibleItems.first?.id)
            },
            Step(hold: 1.6) { model in
                model.filter = .all
                model.query = "repo"
            },
            Step(hold: 1.6) { $0.query = "" },
            Step(hold: 1.8) { model in
                model.selection = .commands
                model.select(model.visibleItems.first?.id)
            },
            Step(hold: 1.8) { model in
                model.selection = .agents
                model.select(model.visibleItems.first?.id)
            },
            Step(hold: 1.8) { model in
                model.selection = .mcp
                model.select(model.visibleItems.first?.id)
            },
            Step(hold: 1.8) { model in
                model.selection = .plugins
                model.selectedPluginID = model.plugins.first?.id
            },
            // The project scope: only what belongs to that repository.
            Step(hold: 2.0) { model in
                model.selection = .skills
                model.changeContext(to: model.projects.first)
                model.select(model.visibleItems.first?.id)
            },
            Step(hold: 1.8) { model in
                model.selection = .commands
                model.select(model.visibleItems.first?.id)
            },
            // And the editor, which is the other half of the document pane.
            Step(hold: 2.0) { model in
                model.changeContext(to: nil)
                model.selection = .skills
                model.select(model.visibleItems.first?.id)
                model.showsPreview = false
            },
        ]
    }

    /// Subagents and MCP servers being switched off and left visible — the two kinds that until
    /// now could only be deleted.
    private static var lastSwitches: [Step] {
        [
            // A command handed to the other assistant, which is the dot on the row.
            Step(hold: 1.6) { model in
                model.selection = .commands
                model.select(model.items.first { $0.kind == .command && $0.assistants == ["claude"] }?.id)
            },
            Step(hold: 2.6) { model in
                guard let item = model.selected,
                      let missing = model.assistants.first(where: { !item.assistants.contains($0.id) })
                else { return }
                model.setAssistant(missing, on: item, present: true)
            },
            Step(hold: 1.6) { model in
                model.selection = .agents
                model.select(model.visibleItems.first?.id)
            },
            Step(hold: 2.2) { model in
                guard let agent = model.visibleItems.first else { return }
                model.toggle(agent)
            },
            Step(hold: 2.2) { model in
                model.selection = .mcp
                model.select(model.visibleItems.first?.id)
            },
            Step(hold: 2.6) { model in
                guard let server = model.visibleItems.first else { return }
                model.toggle(server)
            },
        ]
    }

    /// The conversation. The message itself is sent by the existing `LOADOUT_ASK_MESSAGE` path,
    /// because it has to wait for a real assistant rather than a timer.
    private static var ask: [Step] {
        [
            Step(hold: 1.2) { model in
                model.selection = .skills
                // The skill with the least description on it: that is the one worth asking about,
                // and picking it by measuring rather than by name keeps the scene honest on
                // whatever inventory it is run against.
                let worst = model.visibleItems
                    .filter { $0.kind == .skill && $0.isEditable }
                    .min { $0.description.count < $1.description.count }
                model.select(worst?.id ?? model.visibleItems.first?.id)
                model.showsPreview = false
            },
        ]
    }
}

/// Runs a scene's steps one after another, then hands back.
@MainActor
final class WalkthroughRunner {
    private let model: AppModel
    private var steps: [Walkthrough.Step]
    private let onFinish: () -> Void

    init(model: AppModel, steps: [Walkthrough.Step], onFinish: @escaping () -> Void) {
        self.model = model
        self.steps = steps
        self.onFinish = onFinish
    }

    /// - Parameter after: a beat before the first step, so the recording opens on a still window
    ///   rather than on something already moving.
    func start(after delay: TimeInterval = 1.2) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in next() }
    }

    private func next() {
        guard !steps.isEmpty else { return onFinish() }
        let step = steps.removeFirst()
        // Named before, measured after: what the step is about is only knowable beforehand, and
        // where it sits is only knowable once the window has finished moving.
        let key = step.on?(model)
        step.action(model)
        if let key {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.settle) { [self] in
                guard let rect = Spotlight.rect(key) else { return }
                model.markForRecording(key, rect)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + step.hold) { [self] in next() }
    }

    /// Long enough for a tab change to lay the list out again, short enough to be inside the
    /// shortest hold any scene uses.
    private static let settle: TimeInterval = 0.25
}
