import AppKit
import Foundation
import LoadoutCore

/// Drives the running app through the same calls its buttons make, from outside.
///
///     LOADOUT_DRIVE="tab:commands;select:imark-review;share:codex;dump" \
///     LOADOUT_DUMP=/tmp/out.json LOADOUT_HOME=/tmp/fixture Loadout
///
/// Every step here is the body of a control: `toggle` is the switch on the row, `share` is the
/// assistant dot, `make-global` is the button in the callout. Nothing reaches the disk by a path
/// the interface does not use, which is the whole point — a test that calls the file mover proves
/// the file mover, and a person clicks a switch.
///
/// It exists because the window cannot be clicked from a script: synthetic clicks need the
/// accessibility permission, which a headless run has no way to be granted. This is the honest
/// substitute, and it says what it is: one layer under the pixels, above everything else.
///
/// The dump is the app's own account of itself after each step — what the list holds, what is
/// selected, what the disk says — so whoever is driving can check the screen agreed with the file
/// system rather than trusting either alone.
@MainActor
enum DriveScript {
    static func run(_ script: String, model: AppModel, dump: URL?) {
        var states: [[String: Any]] = []
        let steps = script.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }

        for step in steps where !step.isEmpty {
            let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
            let verb = parts[0]
            let argument = parts.count > 1 ? parts[1] : ""
            let outcome = perform(verb: verb, argument: argument, model: model)
            states.append(snapshot(step: step, outcome: outcome, model: model))
        }

        guard let dump else { return }
        let data = try? JSONSerialization.data(
            withJSONObject: states, options: [.prettyPrinted, .withoutEscapingSlashes]
        )
        try? data?.write(to: dump)
    }

    /// Each verb is one control. Unknown ones are reported rather than ignored: a typo in a script
    /// that silently does nothing is a test that silently passes.
    private static func perform(verb: String, argument: String, model: AppModel) -> String {
        switch verb {
        case "tab":
            guard let selection = Selection(rawValue: argument) else { return "no such tab" }
            model.selection = selection
            return "ok"
        case "scope":
            switch argument {
            case "global": model.changeContext(to: nil)
            case "everything": model.showEverything()
            default:
                guard let project = model.projects.first(where: { $0.relativePath == argument })
                    ?? model.projects.first(where: { $0.name == argument })
                else {
                    return "no such project"
                }
                model.changeContext(to: project)
            }
            return "ok"
        case "sort":
            guard let order = ItemSort(rawValue: argument) else { return "no such order" }
            model.order = order
            return "ok"
        case "toggle-plugin":
            // The plugin's own switch, which is a different control from an item's.
            guard let plugin = model.plugins.first(where: { $0.name == argument })
                ?? model.selectedPlugin
            else { return "no such plugin" }
            model.togglePlugin(plugin)
            return "ok"
        case "search":
            model.query = argument
            return "ok"
        case "filter":
            guard let filter = ItemFilter(rawValue: argument) else { return "no such filter" }
            model.filter = filter
            return "ok"
        case "select":
            // By id when one is given, because two projects may hold a row of the same name and a
            // script that picks the first match is a script that proves nothing about the second.
            guard let item = model.visibleItems.first(where: { $0.id == argument })
                ?? model.visibleItems.first(where: { $0.name == argument })
            else {
                return "not in the list"
            }
            model.select(item.id)
            return "ok"
        case "plugin":
            guard let plugin = model.plugins.first(where: { $0.name == argument }) else {
                return "no such plugin"
            }
            model.selectedPluginID = plugin.id
            return "ok"
        case "toggle":
            guard let item = target(argument, model: model) else { return "nothing selected" }
            model.toggle(item)
            return "ok"
        case "confirm-enable":
            guard model.restoring != nil else { return "no sheet was open" }
            model.confirmRestore()
            return "ok"
        case "cancel-enable":
            model.restoring = nil
            return "ok"
        case "choose":
            // The tick boxes in the sheet that asks where a skill comes back to.
            guard var restoring = model.restoring else { return "no sheet was open" }
            restoring.chosen = Set(argument.split(separator: ",").map(String.init))
            model.restoring = restoring
            return "ok"
        case "confirm-warning":
            guard model.pendingProjectDisable != nil else { return "no warning was up" }
            model.confirmProjectDisable(rememberChoice: argument == "remember")
            return "ok"
        case "share", "unshare":
            guard let item = model.selected else { return "nothing selected" }
            guard let assistant = model.assistants.first(where: { $0.id == argument }) else {
                return "no such assistant"
            }
            model.setAssistant(assistant, on: item, present: verb == "share")
            return "ok"
        case "make-global":
            guard let item = target(argument, model: model) else { return "nothing selected" }
            model.makeGlobal(item)
            return "ok"
        case "new":
            let name = argument.isEmpty ? "novo" : argument
            switch model.selection {
            case .commands: model.createCommand(name: name, description: "Made by the script.")
            case .agents: model.createCommand(name: name, description: "Made by the script.", kind: .agent)
            default: model.createSkill(name: name, description: "Made by the script.")
            }
            return "ok"
        case "delete":
            guard model.selected != nil else { return "nothing selected" }
            model.deleteSelected()
            return "ok"
        case "save":
            model.save()
            return "ok"
        case "edit":
            // A document has lines, and a script is one line: `\n` in the argument is a newline,
            // which is what a person typing into the editor would have produced.
            model.draft = argument
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\t", with: "\t")
            model.isDirty = true
            return "ok"
        case "reload":
            model.reload()
            return "ok"
        case "dump":
            return "ok"
        default:
            return "no such step"
        }
    }

    /// A step can name what it acts on, or act on what is selected — the way a context menu acts on
    /// the row it was opened over, and a button on what is in front of you.
    private static func target(_ name: String, model: AppModel) -> Item? {
        guard !name.isEmpty else { return model.selected }
        return model.items.first { $0.name == name }
    }

    private static func snapshot(step: String, outcome: String, model: AppModel) -> [String: Any] {
        var state: [String: Any] = [
            "step": step,
            "outcome": outcome,
            "tab": model.selection.rawValue,
            "scope": model.showsEverything ? "everything" : (model.context?.name ?? "global"),
            "visible": model.visibleItems.count,
            "order": model.order.rawValue,
            "listed": model.visibleItems.prefix(12).map(\.name),
            "plugins": model.plugins.count,
        ]
        if let error = model.errorMessage { state["error"] = error }
        if let status = model.statusMessage { state["status"] = status }
        if let restoring = model.restoring {
            state["sheet"] = ["item": restoring.item.name,
                              "chosen": restoring.chosen.sorted(),
                              "remembered": restoring.remembered]
        }
        if let pending = model.pendingProjectDisable { state["warning"] = pending.name }
        if let item = model.selected {
            state["selected"] = [
                "name": item.name,
                "kind": item.kind.rawValue,
                "origin": item.origin.label,
                "enabled": item.enabled,
                "assistants": item.assistants.sorted(),
                "path": item.path?.path ?? "",
                // Straight from the file system, so a row that claims something the disk does not
                // is caught by comparing two numbers rather than by trusting the screen.
                "onDisk": FileManager.default.fileExists(atPath: (item.directory ?? item.path)?.path ?? ""),
                "warning": item.warning ?? "",
                "uses": item.usage.count,
                "id": item.id,
                "pluginOff": model.pluginIsOff(for: item),
            ]
        }
        if model.selection == .plugins, let plugin = model.selectedPlugin {
            state["pluginDetail"] = [
                "name": plugin.name,
                "enabled": plugin.enabled,
                "items": model.itemsOfPlugin(plugin).map { ["name": $0.name, "enabled": $0.enabled] },
            ]
        }
        return state
    }
}
