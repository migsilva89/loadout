import SwiftUI
import AppKit
import LoadoutCore

/// ⌘, opens this. Five tabs, one per thing a person occasionally needs to change or look up and
/// would otherwise have no obvious place to find.
struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            AppearanceTab()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            UsageTab(model: model)
                .tabItem { Label("Usage", systemImage: "chart.bar") }
            AssistantsTab(model: model)
                .tabItem { Label("Assistants", systemImage: "person.2") }
            BackupsTab(model: model)
                .tabItem { Label("Backups", systemImage: "clock.arrow.circlepath") }
            HelpTab(model: model)
                .tabItem { Label("Help", systemImage: "questionmark.circle") }
        }
        .frame(width: 520, height: 400)
    }
}

// MARK: - Reporting a bug

/// One place that knows how to report a bug, because there are two doors to it: the Help tab and
/// the Help menu, which is where macOS has taught everybody to look first.
///
/// What goes with the report is the version, the system, the assistants found and how big the
/// inventory is — the four things a maintainer asks for anyway. Never a file name, never a
/// description, never the contents of anything: the report is about the app, not about the person's
/// work.
@MainActor
enum BugReport {
    static let repository = "https://github.com/migsilva89/loadout"

    static func details(_ model: AppModel) -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let system = ProcessInfo.processInfo.operatingSystemVersion
        // `.plugin` is not a kind of item — plugins are counted on their own — so listing it here
        // printed "plugins: 0" beside the real number.
        let counts = ItemKind.allCases
            .filter { $0 != .plugin }
            .map { kind in "\(kind.briefingNoun)s: \(model.items.filter { $0.kind == kind }.count)" }
            .joined(separator: ", ")
        return """
        Loadout \(version)
        macOS \(system.majorVersion).\(system.minorVersion).\(system.patchVersion)
        Assistants: \(model.assistants.map(\.id).joined(separator: ", "))
        Inventory: \(counts), plugins: \(model.plugins.count)
        """
    }

    static func open(_ model: AppModel) {
        var components = URLComponents(string: "\(repository)/issues/new")!
        components.queryItems = [
            URLQueryItem(name: "template", value: "bug_report.yml"),
            URLQueryItem(name: "labels", value: "bug"),
            URLQueryItem(name: "version", value: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "dev"),
            URLQueryItem(name: "os", value: ProcessInfo.processInfo.operatingSystemVersionString),
        ]
        guard let url = components.url else { return }
        NSWorkspace.shared.open(url)
    }

    static func openGuide() {
        NSWorkspace.shared.open(URL(string: "\(repository)#readme")!)
    }
}

// MARK: - Appearance

/// The five themes as five circles, each showing its own accent. No names under them and no
/// menu: the choice is a colour, so the control is the colour — and picking one repaints the
/// window behind this sheet on the spot, which is the only preview worth having.
private struct AppearanceTab: View {
    private let themes = ThemeStore.shared
    // The same three keys the reading pane and the ⌘+/− menu use: this is where a person looks for
    // text size, and a preferences window that only holds five circles looks like a placeholder.
    @AppStorage("readerFontSize") private var readerFontSize = 15.0
    @AppStorage("readerFont") private var readerFont = "system"
    @AppStorage("readerBackground") private var readerBackground = "darker"

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    ForEach(ThemeName.allCases) { theme in
                        swatch(theme)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            } header: {
                Text("Theme")
            } footer: {
                // Named in words as well, because a ring around a circle says *which* one is on
                // but not what it is called — and the tooltips are the only other place the
                // names appear.
                Text("\(themes.name.hint). The window changes as you pick, and the choice is remembered for next launch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Text size") {
                    HStack(spacing: 8) {
                        Slider(value: $readerFontSize, in: 12...22, step: 1)
                            .frame(width: 180)
                        Text("\(Int(readerFontSize)) pt")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                Picker("Typeface", selection: $readerFont) {
                    Text("System").tag("system")
                    Text("Serif").tag("serif")
                    Text("Monospaced").tag("mono")
                }
                Picker("Reading background", selection: $readerBackground) {
                    Text("Card").tag("card")
                    Text("Darker").tag("darker")
                    Text("Ink").tag("ink")
                }
            } header: {
                Text("Reading")
            } footer: {
                Text("How a document reads in the pane on the right. ⌘+ and ⌘− change the size from anywhere; ⌘0 puts it back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func swatch(_ theme: ThemeName) -> some View {
        let selected = themes.name == theme
        return Button {
            themes.name = theme
        } label: {
            Circle()
                .fill(theme.palette.accent)
                .frame(width: 26, height: 26)
                // A hairline of its own so Graphite's grey still reads as a disc on the sheet's
                // own grey, and the selected ring sits outside the disc rather than on it.
                .overlay(Circle().strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5))
                .padding(3)
                .overlay {
                    Circle().strokeBorder(
                        selected ? Color.white.opacity(0.9) : Color.clear, lineWidth: 1.5
                    )
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(theme.hint)
        .accessibilityLabel(theme.label)
        .pointingHand()
    }
}

// MARK: - Usage

private struct UsageTab: View {
    @Bindable var model: AppModel
    @AppStorage("usageWindowDays") private var windowRaw: String = "90"

    private static let options: [(label: String, value: String)] = [
        ("Last 30 days", "30"),
        ("Last 90 days", "90"),
        ("Last year", "365"),
        ("Everything", "all"),
    ]

    private var windowDays: Int? {
        switch windowRaw {
        case "30": return 30
        case "90": return 90
        case "365": return 365
        default: return nil
        }
    }

    var body: some View {
        Form {
            Picker("Count sessions from", selection: $windowRaw) {
                ForEach(Self.options, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .onChange(of: windowRaw) { _, _ in model.reindexUsage(windowDays: windowDays) }
            .help("How far back to read each assistant's sessions for usage counts; stored in this Mac's preferences")

            LabeledContent("Indexed sessions", value: "\(model.indexedFileCount)")
            LabeledContent("Indexed events", value: "\(model.indexedEventCount)")

            Section {
                ForEach(model.usageSources) { source in
                    UsageSourceRow(source: source)
                }
            } header: {
                Text("Where the counts come from. Which of these count is the same checkbox as in Assistants — this list only reports what was found.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(nil)
            }

            HStack {
                if model.indexProgress != nil {
                    ProgressView().controlSize(.small)
                    Text("Reindexing…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reindex now") { model.reindexUsage(windowDays: windowDays) }
                    .disabled(model.indexProgress != nil)
                    .help("Reread every assistant's sessions now, using the window chosen above")
                    .pointingHand()
            }
        }
        // Grouped is what System Settings looks like, and it pins content to the top of the
        // pane instead of floating it in the middle of a fixed-size tab.
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// One history source, and the truth about it. A source with no parser says so rather than sitting
/// at zero looking like an assistant nobody uses.
private struct UsageSourceRow: View {
    let source: UsageSourceStatus

    private var detail: String {
        switch source.state {
        case .included, .excluded:
            let sessions = "\(source.sessionCount) \(source.sessionCount == 1 ? "session" : "sessions")"
            return "\(source.state.label) · \(sessions) · \(source.eventCount) events"
        case .noHistory, .unsupported, .error:
            return source.state.label
        }
    }

    private var tint: Color {
        switch source.state {
        case .included: return .secondary
        case .excluded, .noHistory, .unsupported: return .secondary.opacity(0.7)
        case .error: return .orange
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(source.label)
            Spacer()
            Text(detail)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(tint)
        }
        .help(help)
    }

    private var help: String {
        switch source.state {
        case .included: return "Counted in every usage number."
        case .excluded: return "Found and indexed, but not counted — unchecked in Assistants."
        case .noHistory: return "Nothing on disk to read for this assistant."
        case .unsupported:
            return "There is history here, but nothing in it proves a skill was used, so it "
                + "contributes nothing rather than a misleading zero."
        case .error(let message): return message
        }
    }
}

// MARK: - Assistants

private struct AssistantsTab: View {
    @Bindable var model: AppModel

    var body: some View {
        List {
            Section {
                ForEach(model.assistants) { assistant in
                    AssistantSettingsRow(model: model, assistant: assistant)
                }
            } header: {
                Text("A checked assistant shows up in the list rows and the detail panel, and its sessions count towards \"uses\". Unchecking one does both: it disappears from the list and stops counting. Nothing is deleted — check it again and the same numbers come back. Sharing and syncing keep working either way.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(nil)
            }

            Section {
                ForEach(model.assistantCLIs) { cli in
                    AskCLIRow(model: model, cli: cli)
                }
            } header: {
                HStack {
                    Text("Ask CLIs")
                    Spacer()
                    Button("Add…") { model.isAddingAssistantCLI = true }
                        .buttonStyle(.link)
                        .font(.caption)
                        .pointingHand()
                }
            } footer: {
                Text("What \"Ask\" in a skill's detail runs. The four built-ins show up on their own once installed; add anything else by hand.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// One assistant CLI in Settings › Assistants › Ask CLIs: its resolved path, whether it's a
/// built-in or something the owner added, and a way to try it without leaving the sheet.
private struct AskCLIRow: View {
    @Bindable var model: AppModel
    let cli: AssistantCLI
    @State private var testing = false
    @State private var testResult: String?

    private var displayPath: String {
        cli.executable.path.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"
        )
    }

    private var customEntry: CustomAssistantCLI? {
        model.customAssistantCLIs.first { $0.id == cli.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(cli.label)
                        Text(cli.isCustom ? "Custom" : "Built-in")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                    Text(displayPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if testing { ProgressView().controlSize(.small) }
                Button("Test") { test() }
                    .disabled(testing)
                    .help("Actually runs \(cli.label) with a trivial prompt (\"reply with OK\") to check it works")
                    .pointingHand()
                if let customEntry {
                    Button("Edit") { model.editingCustomAssistantCLI = customEntry }
                        .pointingHand()
                    Button("Remove") { model.removeCustomAssistantCLI(customEntry) }
                        .pointingHand()
                }
            }
            if let testResult {
                Text(testResult)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    private func test() {
        testing = true
        testResult = nil
        let copilot = model.copilot
        let target = cli
        let directory = FileManager.default.temporaryDirectory

        Task.detached(priority: .userInitiated) {
            do {
                let result = try copilot.run(cli: target, prompt: "reply with OK", in: directory, timeout: 30)
                await MainActor.run {
                    let firstLine = result.output.split(separator: "\n").first.map(String.init) ?? "(no output)"
                    testResult = result.timedOut
                        ? "Timed out."
                        : "Exit code \(result.exitCode) — \(firstLine)"
                    testing = false
                }
            } catch {
                await MainActor.run {
                    testResult = (error as? LoadoutError)?.errorDescription ?? error.localizedDescription
                    testing = false
                }
            }
        }
    }
}

private struct AssistantSettingsRow: View {
    @Bindable var model: AppModel
    let assistant: Assistant

    private var skillCount: Int {
        model.items.filter { $0.kind == .skill && $0.assistants.contains(assistant.id) }.count
    }

    private var skillsPath: String {
        assistant.skillsRoot.path.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"
        )
    }

    var body: some View {
        HStack(spacing: 10) {
            AssistantMark(assistant: assistant, present: true, size: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(assistant.label)
                Text(skillsPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(skillCount) \(skillCount == 1 ? "skill" : "skills")")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Toggle("Show and count", isOn: Binding(
                get: { !model.hiddenAssistantIDs.contains(assistant.id) },
                set: { model.setAssistantHidden(assistant, hidden: !$0) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .help(
                "Show \(assistant.label) in the list rows and detail panel, and count its sessions "
                    + "in usage. Unchecking hides it and stops counting it; nothing is deleted, and "
                    + "checking it again brings the same numbers back. Sharing and syncing keep "
                    + "working either way."
            )
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Backups

private struct BackupsTab: View {
    @Bindable var model: AppModel
    @State private var isCounting = false
    @State private var snapshotCount = 0
    @State private var totalBytes: Int64 = 0
    @State private var isDeleting = false
    @State private var confirmingDelete = false
    @State private var resultMessage: String?

    var body: some View {
        Form {
            LabeledContent("Folder", value: model.paths.backups.path)

            if isCounting {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Counting…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                LabeledContent("Snapshots", value: "\(snapshotCount)")
                LabeledContent(
                    "Size on disk",
                    value: ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
                )
            }

            HStack {
                Button("Show in Finder") { model.revealBackups() }
                    .help("Reveal \(model.paths.backups.path) in Finder")
                    .pointingHand()
                Spacer()
                Button("Delete snapshots older than 30 days") { confirmingDelete = true }
                    .disabled(isDeleting || isCounting)
                    .help("Permanently remove backup snapshots older than 30 days, after confirming")
                    .pointingHand()
            }

            if let resultMessage {
                Text(resultMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await countSnapshots() }
        .alert("Delete snapshots older than 30 days?", isPresented: $confirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { Task { await deleteOld() } }
        } message: {
            Text("These are the app's own safety copies made before edits. This can't be undone from here.")
        }
    }

    private func countSnapshots() async {
        isCounting = true
        let backups = Backups(paths: model.paths)
        // Walking every snapshot's file sizes is not cheap, so it runs off the main thread —
        // that's the whole reason this is a `Task` instead of a plain computed property.
        let (count, bytes) = await Task.detached(priority: .utility) {
            let snapshots = backups.listSnapshots()
            return (snapshots.count, backups.totalSize())
        }.value
        snapshotCount = count
        totalBytes = bytes
        isCounting = false
    }

    private func deleteOld() async {
        isDeleting = true
        let backups = Backups(paths: model.paths)
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        let removed = (try? await Task.detached(priority: .utility) {
            try backups.deleteSnapshots(olderThan: cutoff)
        }.value) ?? 0
        resultMessage = "Removed \(removed) \(removed == 1 ? "snapshot" : "snapshots")."
        isDeleting = false
        await countSnapshots()
    }
}

// MARK: - Help

/// What the app does to your files, where it keeps its own, and how to report it when it gets
/// something wrong.
///
/// An app that moves folders around inside `~/.claude` owes the person using it a plain account of
/// what "off" actually does — kept here rather than in a README nobody opens, because the question
/// arrives while the app is in front of you. The bug report is prefilled with what a maintainer
/// always has to ask for anyway, and is shown before it is sent: nothing leaves without being read.
struct HelpTab: View {
    @Bindable var model: AppModel
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                section("What switching something off does") {
                    line("A skill", "moves to a `skills-off` folder beside the assistant that owns it — never into another assistant's. Switching it on asks which assistants should load it again.")
                    line("A command or subagent", "moves to `commands-off` or `agents-off` next to it.")
                    line("From a plugin", "moves aside inside the plugin's installed version, and Loadout puts it back there when the plugin updates.")
                    line("An MCP server", "its entry is lifted out of ~/.claude.json and kept, to be put back exactly as it was.")
                    line("Nothing is deleted", "and every write takes a backup first. Deleting is a separate gesture, and it goes to the Trash.")
                }

                section("Where Loadout keeps its own files") {
                    pathRow(model.paths.support)
                    Text("Backups, the usage index, and the notes of what is switched off. Deliberately not inside ~/.claude, which belongs to Claude Code.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                section("When something is wrong") {
                    Text(diagnostics)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    HStack {
                        Button("Report a bug") { BugReport.open(model) }
                            .help("Opens a new issue on GitHub with the version and system already filled in")
                            .pointingHand()
                        Button(copied ? "Copied" : "Copy these details") { copyDiagnostics() }
                            .help("Copy the lines above, to paste wherever you are reporting it")
                            .pointingHand()
                        Spacer()
                        Button("Open the guide") { BugReport.openGuide() }
                        .help("The README, which covers what the app does and how it is built")
                        .pointingHand()
                    }
                }
            }
            .padding(18)
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            content()
        }
    }

    private func line(_ subject: String, _ rest: String) -> some View {
        // `.init` so the whole sentence is read as markdown: interpolating a `LocalizedStringKey`
        // into a plain string prints the key's own description, brackets and all.
        Text(.init("**\(subject)** — \(rest)"))
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func pathRow(_ url: URL) -> some View {
        HStack(spacing: 8) {
            Text(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                .buttonStyle(.link)
                .help("Open that folder in the Finder")
                .pointingHand()
        }
    }

    private var diagnostics: String { BugReport.details(model) }

    private func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnostics, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
    }

}
