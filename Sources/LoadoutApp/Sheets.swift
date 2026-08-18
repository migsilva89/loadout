import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LoadoutCore

/// Create a skill, a command or a subagent — and, by default, have an assistant write it.
///
/// It used to be the other way round: "Create" carried Enter and made an empty folder, while
/// "Create and ask" sat beside it as the curiosity. That had the shape backwards. Nobody
/// hand-writes a skill any more, and the hard part was never the folder — it is the description
/// that decides whether the thing is ever reached for, and a body worth loading.
///
/// So the assistant carries Enter, and the second field changed meaning with it. It used to ask for
/// the description and advise how to write one; asking somebody to write a good description before
/// an assistant rewrites it is asking twice. It is a brief now: plain sentences about what they
/// want. The old wording comes back only in the one case where nobody downstream will sharpen it —
/// no assistant installed at all.
struct NewSkillSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var brief = ""
    @State private var chosenCLI: AssistantCLI?
    @State private var pickerOpen = false
    @FocusState private var focus: Field?

    private enum Field { case name, brief }

    /// The Commands and Agents tabs make their own kinds here, with the same name rules and the
    /// same refusal to overwrite. Only the words and the file written change.
    private var makesCommand: Bool { model.selection == .commands }
    private var makesAgent: Bool { model.selection == .agents }
    private var noun: String { makesAgent ? "subagent" : (makesCommand ? "command" : "skill") }

    /// The assistants that can be asked. Empty is a real state on a fresh Mac, and the sheet
    /// changes shape for it rather than showing a button that can only apologise.
    private var clis: [AssistantCLI] { model.askableCLIs }
    private var assistant: AssistantCLI? {
        chosenCLI ?? clis.first { $0.id == model.lastAssistantCLIID } ?? clis.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                heading
                field(
                    label: "Name",
                    hint: nameHint,
                    bad: !name.isEmpty && !isNameValid
                ) { nameInput }
                field(label: briefLabel, hint: briefHint, bad: false, optional: assistant != nil) {
                    briefInput
                }
                if assistant == nil { noAssistantNote }
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 20)

            footer
        }
        .frame(width: 520)
        .background(V2.popover)
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.13), lineWidth: 0.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onAppear { focus = .name }
    }

    // MARK: - Heading

    /// The subtitle says what the thing will be before anything is asked of you — the same lesson
    /// the welcome sheet learned. "Personal skill" is a fact somebody would otherwise discover
    /// after the fact, in the Details card.
    private var heading: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("New \(noun)")
                .font(.system(size: 16, weight: .semibold))
                .tracking(-0.2)
            Text(subtitle)
                .font(.system(size: 12.5))
                .foregroundStyle(Color.white.opacity(0.45))
        }
    }

    private var subtitle: String {
        if makesCommand { return "You run it by typing its name — it never triggers on its own" }
        if makesAgent { return "Handed work by name, when the assistant decides to delegate" }
        return "Personal skill · loaded in every project"
    }

    // MARK: - Fields

    private func field<Control: View>(
        label: String, hint: String, bad: Bool, optional: Bool = false,
        @ViewBuilder control: () -> Control
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.60))
                if optional {
                    Text("optional")
                        .font(.system(size: 11))
                        .foregroundStyle(V2.textFaint)
                }
            }
            control()
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if bad {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 10.5))
                }
                Text(hint)
            }
            .font(.system(size: 11.5))
            .foregroundStyle(bad ? V2.issue : Color.white.opacity(0.42))
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var nameInput: some View {
        HStack(spacing: 0) {
            // The slash is drawn into the field rather than typed, so the name reads the way it
            // will be used — and so nobody types it and ends up with a file called "/deploy".
            if makesCommand {
                Text("/")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.38))
            }
            TextField("\(noun)-name".replacingOccurrences(of: "subagent", with: "agent"), text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .focused($focus, equals: .name)
        }
        .padding(.horizontal, 11)
        .frame(height: 30)
        .background(inputFill(bad: !name.isEmpty && !isNameValid, focused: focus == .name))
    }

    private var briefInput: some View {
        TextField(briefPlaceholder, text: $brief, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .lineSpacing(3)
            .focused($focus, equals: .brief)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(minHeight: 88, alignment: .topLeading)
            .background(inputFill(bad: false, focused: focus == .brief))
    }

    /// One fill, one border, one ring — so a focused field and a wrong one are told apart by colour
    /// rather than by two different shapes.
    private func inputFill(bad: Bool, focused: Bool) -> some View {
        let edge: Color = bad ? V2.issue : (focused ? V2.accent : Color.white.opacity(0.12))
        return RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.black.opacity(0.28))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(edge, lineWidth: bad || focused ? 1 : 0.5)
            }
            .overlay {
                if bad || focused {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder((bad ? V2.issue : V2.accent).opacity(0.22), lineWidth: 3)
                        .padding(-2)
                }
            }
    }

    // MARK: - Copy that changes with the state

    private var briefLabel: String {
        // With nobody to sharpen it, the field goes back to being the description it will really be,
        // and the advice for writing one comes back with it.
        guard assistant != nil else { return "Description" }
        if makesCommand { return "What should happen when you run it?" }
        if makesAgent { return "What should this subagent be good at?" }
        return "What do you want this skill to do?"
    }

    /// Never the label again. A placeholder repeating the words directly above it wastes the one
    /// chance to show what a good answer looks like.
    private var briefPlaceholder: String {
        if makesCommand { return "Read the merged PRs since the last tag and post the notes" }
        if makesAgent { return "Reviewing SQL migrations for locking and rollback" }
        return "Turn merged pull requests into release notes, and skip refactors"
    }

    private var briefHint: String {
        guard let assistant else {
            return "Say when to use it, not what it is — this is what the assistant reads when choosing."
        }
        // Named when there is one, because the button names it too and repeating it costs nothing.
        // "The assistant" when there are several, since the choice is not made until the button.
        // Lowercase, because every use of it here is mid-sentence: "and The assistant asks you"
        // is the kind of seam that makes copy look generated.
        let who = clis.count == 1 ? assistant.label : "the assistant"
        if brief.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Leave it blank and \(who) asks you a few questions first, instead of guessing."
        }
        if makesCommand {
            return "\(who) writes the prompt the command runs. Say what it should do, and what "
                + "arguments it takes."
        }
        return "\(who) turns this into a description that triggers at the right moments, and writes "
            + "the body. Plain sentences are enough."
    }

    private var nameHint: String {
        if name.isEmpty {
            return "Lowercase letters, numbers and hyphens. This becomes the "
                + (makesCommand ? "name you type after the slash." : (makesAgent ? "file name." : "folder name."))
        }
        guard isNameValid else {
            // The fixed form, spelled out: telling somebody the rule and letting them apply it is
            // more work than showing them the answer.
            return "No spaces or capitals. Try \(suggestedName)."
        }
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

    private var suggestedName: String {
        let lowered = name.lowercased()
            .map { ($0.isLetter && $0.isASCII) || $0.isNumber ? $0 : "-" }
        return String(lowered)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
    }

    private var noAssistantNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 11.5))
                .foregroundStyle(V2.textMid)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text("No coding assistant found on this Mac, so nothing can write it for you.")
                HStack(spacing: 4) {
                    Button("Assistants") {
                        model.settingsSection = "assistants"
                        model.showsSettings = true
                        dismiss()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(V2.link)
                    .help("Open Settings, where the assistants Loadout looks for are listed")
                    .pointingHand()
                    Text("lists the ones Loadout looks for.")
                }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(V2.textMid)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(V2.hairline, lineWidth: 0.5)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Cancel") { dismiss() }
                .buttonStyle(SheetButtonStyle(kind: .quiet, enabled: true))
                .keyboardShortcut(.cancelAction)
                .help("Close without creating a \(noun)")
                .pointingHand()

            Spacer(minLength: 12)

            if assistant == nil {
                // Nothing to contrast against, so "empty" would only sound like a lesser choice.
                Button { createOnly() } label: { primaryLabel(text: "Create \(noun)", badge: nil) }
                    .buttonStyle(SheetButtonStyle(kind: .primary, enabled: isNameValid))
                    .disabled(!isNameValid)
                    .keyboardShortcut(.defaultAction)
                    .help("Create the \(noun) and open it for editing")
                    .pointingHand(enabled: isNameValid)
            } else {
                Button("Create empty") { createOnly() }
                    .buttonStyle(SheetButtonStyle(kind: .quiet, enabled: isNameValid))
                    .disabled(!isNameValid)
                    .help("Just make the \(noun) and open it, with nothing written")
                    .pointingHand(enabled: isNameValid)
                assistantAction
            }
        }
        .padding(.leading, 24)
        .padding(.trailing, 18)
        .padding(.vertical, 13)
        .background(Color.black.opacity(0.20))
        .overlay(alignment: .top) { Hairline(color: V2.hairline) }
    }

    /// One assistant: a plain button naming it. Several: the same button with a chevron beside it,
    /// because the choice of *which* belongs on the button that uses it — in a picker above the
    /// fields it read as part of the thing being made.
    @ViewBuilder
    private var assistantAction: some View {
        if let assistant {
            HStack(spacing: 0) {
                Button { createAndAsk(assistant) } label: {
                    primaryLabel(text: "Write it with \(assistant.label)", badge: assistant)
                }
                .buttonStyle(SheetButtonStyle(
                    kind: .primary, enabled: isNameValid, rightSquare: clis.count > 1
                ))
                .disabled(!isNameValid)
                .keyboardShortcut(.defaultAction)
                .help("Create the \(noun), then have \(assistant.label) write it for you to accept")
                .pointingHand(enabled: isNameValid)

                if clis.count > 1 {
                    Button { pickerOpen = true } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 9)
                            .frame(height: 30)
                    }
                    .buttonStyle(SheetButtonStyle(kind: .primaryTrailing, enabled: isNameValid))
                    .disabled(!isNameValid)
                    .help("Choose which assistant writes it")
                    .pointingHand(enabled: isNameValid)
                    .popover(isPresented: $pickerOpen, arrowEdge: .bottom) { assistantMenu }
                }
            }
        }
    }

    private func primaryLabel(text: String, badge: AssistantCLI?) -> some View {
        HStack(spacing: 7) {
            if let badge { cliBadge(badge) }
            Text(text)
                .font(.system(size: 13, weight: .medium))
            // Absent when the button does nothing: an Enter hint on an unavailable action is a
            // promise the keyboard will not keep.
            if isNameValid {
                Text("↵")
                    .font(.system(size: 11.5))
                    .opacity(0.6)
            }
        }
    }

    private func cliBadge(_ cli: AssistantCLI) -> some View {
        Text(Self.initials(cli.label))
            .font(.system(size: 8, weight: .semibold, design: .rounded))
            .frame(width: 16, height: 16)
            .background(
                RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                    .fill(Color.white.opacity(0.22))
            )
    }

    /// One letter per word — "Claude Code" is CC, not CL. Taking the first two letters of the
    /// whole name made two different assistants collide as often as it identified one.
    private static func initials(_ label: String) -> String {
        let words = label.split(separator: " ")
        guard words.count > 1 else { return String(label.prefix(2)).uppercased() }
        return words.prefix(2).map { String($0.prefix(1)).uppercased() }.joined()
    }

    private var assistantMenu: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("WRITE IT WITH")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(V2.textFaint)
                .padding(.horizontal, 9)
                .padding(.top, 6)
                .padding(.bottom, 3)

            ForEach(clis) { cli in
                let current = cli.id == assistant?.id
                Button {
                    chosenCLI = cli
                    pickerOpen = false
                } label: {
                    HStack(spacing: 8) {
                        cliBadge(cli)
                            .opacity(current ? 1 : 0.8)
                        Text(cli.label)
                            .font(.system(size: 12.5))
                        Spacer(minLength: 8)
                        if current {
                            Text("↵")
                                .font(.system(size: 11))
                                .opacity(0.7)
                        }
                    }
                    .foregroundStyle(current ? Color.white : V2.text)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(current ? V2.accent : Color.clear)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointingHand()
            }

            Hairline(color: V2.hairline).padding(.vertical, 4)
            Text("Remembers your last choice.")
                .font(.system(size: 11.5))
                .foregroundStyle(V2.textFaint)
                .padding(.horizontal, 9)
                .padding(.bottom, 6)
        }
        .padding(5)
        .frame(width: 250)
    }

    // MARK: - Doing it

    private func createOnly() {
        if makesCommand || makesAgent {
            model.createCommand(name: name, description: brief, kind: makesAgent ? .agent : .command)
        } else {
            model.createSkill(name: name, description: brief)
        }
        dismiss()
    }

    private func createAndAsk(_ cli: AssistantCLI) {
        if makesCommand || makesAgent {
            model.createCommandAndAsk(
                name: name, brief: brief, kind: makesAgent ? .agent : .command, cli: cli
            )
        } else {
            model.createSkillAndAsk(name: name, description: brief, cli: cli)
        }
        dismiss()
    }

    private var isNameValid: Bool { isValidSkillName(name) }
}

/// The buttons on a sheet: one quiet, one filled, and the filled one's trailing half when it has a
/// chevron beside it.
///
/// Written rather than taken from AppKit because every other surface in this app draws its own, and
/// a stock button in the middle of one announces that the panel was assembled from parts. A
/// disabled primary keeps the accent at 28%: still legible as the way forward once the name is
/// fixed, rather than a grey slab that reads as gone.
struct SheetButtonStyle: ButtonStyle {
    enum Kind { case quiet, primary, primaryTrailing }

    let kind: Kind
    let enabled: Bool
    /// True when a chevron sits against this button's right edge, so the corners meet flush.
    var rightSquare = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(label(pressed: configuration.isPressed))
            .padding(.horizontal, kind == .primaryTrailing ? 0 : 13)
            .frame(height: 30)
            .background(shape(pressed: configuration.isPressed))
    }

    private func label(pressed: Bool) -> Color {
        switch kind {
        case .quiet:
            return enabled ? V2.text : Color.white.opacity(0.28)
        case .primary, .primaryTrailing:
            return enabled ? .white : Color.white.opacity(0.30)
        }
    }

    @ViewBuilder
    private func shape(pressed: Bool) -> some View {
        let corners = RoundedRectangle(cornerRadius: 8, style: .continuous)
        switch kind {
        case .quiet:
            corners
                .fill(enabled && pressed ? V2.buttonHover : V2.button)
                .overlay { corners.strokeBorder(V2.hairline, lineWidth: 0.5) }
        case .primary:
            UnevenRoundedRectangle(
                topLeadingRadius: 8, bottomLeadingRadius: 8,
                bottomTrailingRadius: rightSquare ? 0 : 8, topTrailingRadius: rightSquare ? 0 : 8,
                style: .continuous
            )
                .fill(V2.accent.opacity(enabled ? (pressed ? 0.85 : 1) : 0.28))
        case .primaryTrailing:
            UnevenRoundedRectangle(
                topLeadingRadius: 0, bottomLeadingRadius: 0,
                bottomTrailingRadius: 8, topTrailingRadius: 8, style: .continuous
            )
                .fill(V2.accent.opacity(enabled ? (pressed ? 0.85 : 1) : 0.28))
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color.black.opacity(0.35)).frame(width: 0.5)
                }
                .overlay(Color.black.opacity(0.12))
        }
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
                        .pointingHand(
                            enabled: !prompt.trimmingCharacters(in: .whitespaces).isEmpty
                        )
                }
                Button("Copy answer") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(answer, forType: .string)
                }
                .disabled(answer.isEmpty)
                .help("Copy \(cli.label)'s answer to the clipboard")
                .pointingHand(enabled: !answer.isEmpty)
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
                        .help("Find the assistant's program on this Mac, instead of typing where it is")
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
                    .help("Close without keeping what you typed here")
                    .pointingHand()
                Button(editing == nil ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .help(
                        editing == nil
                            ? "Add this to the assistants you can ask about a skill"
                            : "Keep these changes to how this assistant is run"
                    )
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
                        .help("Ticked means \(assistant.label) loads this skill again")
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
                .pointingHand(enabled: chosenCount > 0)
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
/// Taking a copy out of a repository, asked and answered in one place.
///
/// Two states, one dialog: the question — you are about to have two of these, and yours stops
/// following theirs — and then the receipt, with the path the copy actually landed on. The receipt
/// is the point: the copy used to happen behind a click that changed nothing on screen.
struct MakeGlobalWarningSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private var item: Item? { model.pendingMakeGlobal }
    private var done: Bool { model.makeGlobalDestination != nil || model.makeGlobalError != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                if done {
                    Image(systemName: model.makeGlobalError == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(model.makeGlobalError == nil ? Color.green : Color.orange)
                }
                Text(title)
                    .font(.title3.weight(.semibold))
            }
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let destination = model.makeGlobalDestination {
                Text(destination)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            HStack {
                Spacer()
                if done {
                    Button("Done") { close() }
                        .keyboardShortcut(.defaultAction)
                        .help("Close this")
                        .pointingHand()
                } else {
                    Button("Cancel") { close() }
                        .keyboardShortcut(.cancelAction)
                        .help("Leave it where it is, working only inside that repository")
                        .pointingHand()
                    Button("Make Global") { model.confirmMakeGlobal() }
                        .keyboardShortcut(.defaultAction)
                        .help("Copy it into your own folder, where every project sees it")
                        .pointingHand()
                }
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func close() {
        model.dismissMakeGlobal()
        dismiss()
    }

    private var title: String {
        if model.makeGlobalError != nil { return "Couldn't copy it" }
        if model.makeGlobalDestination != nil { return "It's yours now" }
        return "You'll have two of these"
    }

    private var message: String {
        if let error = model.makeGlobalError { return error }
        guard let item else { return "" }
        let noun = item.kind.briefingNoun
        let repository: String
        if case .project(let name) = item.origin { repository = name } else { repository = "the repository" }
        if model.makeGlobalDestination != nil {
            return "\(item.name) is one of your \(noun)s from now on, so every project sees it. \(repository) keeps the one it had, and the two are separate files."
        }
        return """
            \(item.name) is copied into your own \(noun)s, where every project sees it. \(repository) \
            keeps the one it has, so nobody else loses anything — but the two are separate files from \
            now on: their changes stop reaching your copy, and yours never touch theirs.
            """
    }
}

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
                .help("Switch off skills in a repository from now on without this warning")
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
