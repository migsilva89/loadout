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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New skill")
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 5) {
                TextField("skill-name", text: $name)
                    .textFieldStyle(.roundedBorder)
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(isNameValid || name.isEmpty ? Color.secondary : Color.red)
            }

            VStack(alignment: .leading, spacing: 5) {
                TextField("When should this skill be triggered?", text: $description, axis: .vertical)
                    .lineLimit(3...5)
                    .textFieldStyle(.roundedBorder)
                Text("The description helps Claude choose the skill. Say when to use it, not what it is.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .help("Close without creating a skill")
                    .pointingHand()
                Button("Create") {
                    model.createSkill(name: name, description: description)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isNameValid)
                .help("Create the skill folder and open it for editing")
                .pointingHand()
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var isNameValid: Bool { isValidSkillName(name) }

    private var hint: String {
        if name.isEmpty { return "Use lowercase letters, numbers, and hyphens. This becomes the folder name." }
        return isNameValid ? "~/.claude/skills/\(name)/SKILL.md" : "Use only lowercase letters, numbers, and hyphens."
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
