import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LoadoutCore

/// Create a skill (AC4.3).
struct NewSkillSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""

    /// The Commands tab makes commands here, with the same name rules and the same refusal to
    /// overwrite. Only the words and the file written change.
    private var makesCommand: Bool { model.selection == .commands }
    private var makesAgent: Bool { model.selection == .agents }
    private var noun: String { makesAgent ? "subagent" : (makesCommand ? "command" : "skill") }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New \(noun)")
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 5) {
                TextField("\(noun)-name".replacingOccurrences(of: "subagent", with: "agent"), text: $name)
                    .textFieldStyle(.roundedBorder)
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(isNameValid || name.isEmpty ? Color.secondary : Color.red)
            }

            VStack(alignment: .leading, spacing: 5) {
                TextField(
                    makesAgent
                        ? "What is this subagent for?"
                        : (makesCommand ? "What does this command do?" : "When should this skill be triggered?"),
                    text: $description, axis: .vertical
                )
                    .lineLimit(3...5)
                    .textFieldStyle(.roundedBorder)
                Text(
                    makesAgent
                        ? "The description is how Claude decides when to hand work to this subagent."
                        : (makesCommand
                            ? "You'll type /\(name.isEmpty ? "name" : name) to run it. The description is what the list shows."
                            : "The description helps Claude choose the skill. Say when to use it, not what it is.")
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .help("Close without creating a skill")
                    .pointingHand()
                // The hard part of a new skill is the description and the body, not the folder. So
                // there are two ways out of here: make the skeleton yourself, or make it and hand it
                // to an assistant with what you just typed as the brief.
                if !makesCommand, !makesAgent { askButton }
                Button("Create") {
                    if makesCommand || makesAgent {
                        model.createCommand(
                            name: name, description: description, kind: makesAgent ? .agent : .command
                        )
                    } else {
                        model.createSkill(name: name, description: description)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isNameValid)
                .help(makesCommand
                    ? "Create the command file and open it for editing"
                    : "Create the skill folder and open it for editing")
                .pointingHand()
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    /// "Create and ask", as a plain button when there is one assistant to ask and a menu when there
    /// is a choice. Absent when there is none installed: a button that can only apologise is worse
    /// than no button.
    @ViewBuilder
    private var askButton: some View {
        let clis = model.askableCLIs
        if let only = clis.count == 1 ? clis.first : nil {
            Button("Create and ask") { createAndAsk(only) }
                .disabled(!isNameValid)
                .help("Create the skill, then have \(only.label) write its description and body for you to accept")
                .pointingHand()
        } else if !clis.isEmpty {
            Menu("Create and ask") {
                ForEach(clis) { cli in
                    Button(cli.label) { createAndAsk(cli) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(!isNameValid)
            .help("Create the skill, then have an assistant write its description and body for you to accept")
            .pointingHand()
        }
    }

    private func createAndAsk(_ cli: AssistantCLI) {
        model.createSkillAndAsk(name: name, description: description, cli: cli)
        dismiss()
    }

    private var isNameValid: Bool { isValidSkillName(name) }

    /// A skill is a folder and a command is a file, so the hint says which one is about to be
    /// written — and then shows the path itself, which answers the question outright.
    private var hint: String {
        if name.isEmpty {
            return "Use lowercase letters, numbers, and hyphens. This becomes the "
                + (makesCommand || makesAgent ? "file name." : "folder name.")
        }
        guard isNameValid else { return "Use only lowercase letters, numbers, and hyphens." }
        if makesAgent {
            return model.context.map { "\($0.name)/.claude/agents/\(name).md" }
                ?? "~/.claude/agents/\(name).md"
        }
        if makesCommand {
            return model.context.map { "\($0.name)/.claude/commands/\(name).md" }
                ?? "~/.claude/commands/\(name).md"
        }
        return "~/.claude/skills/\(name)/SKILL.md"
    }
}

/// Ask an assistant CLI about the selected skill (AC7). Nothing is written without a decision
/// here — the sheet only ever shows text back, whichever assistant produced it.
struct CopilotSheet: View {
    @Bindable var model: AppModel
    let cli: AssistantCLI
    @Environment(\.dismiss) private var dismiss
    @State private var prompt = "Improve this skill's description so it triggers at the right times, and explain what you changed."
    @State private var answer = ""
    @State private var running = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ask \(cli.label)")
                .font(.title3.weight(.semibold))
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $prompt)
                .font(.system(size: 12))
                .frame(height: 70)
                .padding(6)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            ScrollView {
                Text(answer.isEmpty ? "The answer appears here. Nothing is written until you decide." : answer)
                    .font(.system(size: 12, design: answer.isEmpty ? .default : .monospaced))
                    .foregroundStyle(answer.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(height: 260)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))

            HStack {
                if running { ProgressView().controlSize(.small) }
                Spacer()
                Button("Close") {
                    model.copilot.cancel()
                    dismiss()
                }
                .help("Close without saving anything")
                .pointingHand()
                if running {
                    Button("Cancel") { model.copilot.cancel() }
                        .help("Stop the running request to \(cli.label)")
                        .pointingHand()
                } else {
                    Button("Ask") { ask() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty)
                        .help("Run \(cli.invocationDescription) with this prompt in the skill's folder (⌘↵)")
                        .pointingHand()
                }
                Button("Copy answer") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(answer, forType: .string)
                }
                .disabled(answer.isEmpty)
                .help("Copy \(cli.label)'s answer to the clipboard")
                .pointingHand()
            }
        }
        .padding(20)
        .frame(width: 620)
    }

    private var subtitle: String {
        guard let item = model.selected else { return "" }
        return "Runs \(cli.invocationDescription) in the \(item.name) folder."
    }

    private func ask() {
        guard let item = model.selected,
              let directory = item.directory ?? item.path?.deletingLastPathComponent()
        else { return }
        running = true
        failure = nil
        answer = ""
        let copilot = model.copilot
        let question = prompt
        let target = cli

        Task.detached(priority: .userInitiated) {
            do {
                let result = try copilot.run(cli: target, prompt: question, in: directory)
                await MainActor.run {
                    answer = result.output
                    failure = result.timedOut ? "The request timed out and was stopped." : nil
                    running = false
                }
            } catch {
                await MainActor.run {
                    failure = (error as? LoadoutError)?.errorDescription ?? error.localizedDescription
                    running = false
                }
            }
        }
    }
}

/// Add or edit a custom assistant CLI (Settings › Assistants › Ask CLIs). Built-ins never open
/// this sheet — they're read-only there.
struct AssistantCLIFormSheet: View {
    @Bindable var model: AppModel
    /// `nil` means "Add…"; otherwise this is the entry being edited.
    let editing: CustomAssistantCLI?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var path: String
    @State private var template: String
    @State private var failure: String?

    init(model: AppModel, editing: CustomAssistantCLI?) {
        self.model = model
        self.editing = editing
        _name = State(initialValue: editing?.label ?? "")
        _path = State(initialValue: editing?.executablePath ?? "")
        _template = State(initialValue: editing?.argumentTemplate ?? "{prompt}")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(editing == nil ? "Add an assistant CLI" : "Edit assistant CLI")
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 5) {
                Text("Name").font(.caption).foregroundStyle(.secondary)
                TextField("Gemini", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Command").font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("/usr/local/bin/gemini", text: $path)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…") { choosePath() }
                        .pointingHand()
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Arguments").font(.caption).foregroundStyle(.secondary)
                TextField("-p {prompt}", text: $template)
                    .textFieldStyle(.roundedBorder)
                Text("Use {prompt} where the question goes, e.g. \"-p {prompt}\" or \"exec {prompt}\".")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .pointingHand()
                Button(editing == nil ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .pointingHand()
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func choosePath() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [.unixExecutable]
        panel.title = "Choose the assistant's executable"
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
        }
    }

    private func save() {
        do {
            if let editing {
                try model.updateCustomAssistantCLI(editing, name: name, path: path, template: template)
            } else {
                try model.addCustomAssistantCLI(name: name, path: path, template: template)
            }
            dismiss()
        } catch {
            failure = (error as? LoadoutError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// Where a skill goes when it comes back on (AC3.5).
///
/// Switching off is one gesture with one meaning; switching on is a choice, because the app cannot
/// know for someone which assistants should load a skill again. The ticks start from what Loadout
/// recorded when it was switched off, so confirming without touching anything is a plain undo.
struct RestoreSkillSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Enable \(model.restoring?.item.name ?? "")")
                .font(.title3.weight(.semibold))

            Text(
                model.restoring?.remembered == true
                    ? "These are the assistants that were loading it when you switched it off."
                    : "Loadout couldn't tell where this skill used to load, so it proposes where it is parked."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.visibleAssistants) { assistant in
                    Toggle(assistant.label, isOn: binding(for: assistant))
                        .toggleStyle(.checkbox)
                        .pointingHand()
                }
            }

            Text(chosenCount > 1
                ? "The folder goes to ~/.agents/skills, and each one gets a link to it — one copy, one edit."
                : "The folder goes straight into that assistant, with no link left anywhere else.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .help("Leave the skill switched off")
                    .pointingHand()
                Button("Enable") {
                    model.confirmRestore()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosenCount == 0)
                .help("Put the skill back into the assistants ticked above")
                .pointingHand()
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var chosenCount: Int { model.restoring?.chosen.count ?? 0 }

    private func binding(for assistant: Assistant) -> Binding<Bool> {
        Binding(
            get: { model.restoring?.chosen.contains(assistant.id) ?? false },
            set: { on in
                guard var restoring = model.restoring else { return }
                if on { restoring.chosen.insert(assistant.id) } else { restoring.chosen.remove(assistant.id) }
                model.restoring = restoring
            }
        )
    }
}

/// The one-time note that disabling a project skill shows up in the repository (AC3.20).
///
/// Loadout runs no git commands and knows nothing about version control. It moves a folder — but
/// that folder lives inside a repository, so the change lands next to whatever work is in progress
/// and could be committed without anyone meaning to. Worth saying once; not worth saying twice.
struct ProjectSkillWarningSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var dontAskAgain = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("This skill lives in a repository")
                .font(.title3.weight(.semibold))
            Text("Disabling \(model.pendingProjectDisable?.name ?? "it") moves its folder to .claude/skills-off inside the project. The change will show up alongside your work, and pushing it would disable the skill for everyone on that repository.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Don't tell me again", isOn: $dontAskAgain)
                .toggleStyle(.checkbox)
                .pointingHand()
            HStack {
                Spacer()
                Button("Cancel") {
                    model.pendingProjectDisable = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .help("Leave the skill enabled")
                .pointingHand()
                Button("Disable") {
                    model.confirmProjectDisable(rememberChoice: dontAskAgain)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .help("Move the skill aside inside the repository")
                .pointingHand()
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
