import SwiftUI
import AppKit
import LoadoutCore

/// ⌘, opens this. One tab per thing a person occasionally needs to change or look up and would
/// otherwise have no obvious place to find.
struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            AppearanceTab()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            ProjectsTab(model: model)
                .tabItem { Label("Projects", systemImage: "folder") }
            UsageTab(model: model)
                .tabItem { Label("Usage", systemImage: "chart.bar") }
            AssistantsTab(model: model)
                .tabItem { Label("Assistants", systemImage: "person.2") }
            StorageTab(model: model)
                .tabItem { Label("Storage", systemImage: "internaldrive") }
            UpdatesTab()
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
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
struct AppearanceTab: View {
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
                            .pointingHand()
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
                .pointingHand()
                Picker("Reading background", selection: $readerBackground) {
                    Text("Card").tag("card")
                    Text("Darker").tag("darker")
                    Text("Ink").tag("ink")
                }
                .pointingHand()
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

// MARK: - Projects

/// Where Loadout looks for repositories.
///
/// This is the whole of what a person has to keep up to date, and it is deliberately the short
/// list: two or three folders, typed once. What is inside them is worked out on every launch, so
/// a repository cloned this morning is in the list this afternoon with nobody maintaining
/// anything. Before this tab existed the app read one generated file, `~/Projects/INDEX.md`, and
/// anyone without it saw no projects at all.
struct ProjectsTab: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                if model.projectRoots.folders.isEmpty {
                    Text("No folders yet, so Loadout has no projects to show — only what is loaded globally.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.projectRoots.folders, id: \.self) { folder in
                        HStack {
                            Text(display(folder))
                                .font(.system(size: 12, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button {
                                remove(folder)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Stop looking in \(display(folder))")
                            .pointingHand()
                        }
                    }
                }

                HStack {
                    Button("Add folder…") { add() }
                        .help("Choose a folder that holds your repositories, or a repository itself")
                        .pointingHand()
                    Spacer()
                    Text(found)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Where your projects live")
            } footer: {
                Text(
                    "Loadout looks inside these for repositories — a folder with a .git or a "
                    + ".claude in it — up to \(ProjectRoots.searchDepth) levels down, and a folder "
                    + "that is one itself counts. Each project's own skills and "
                    + "commands then show up when you pick it from the scope button at the top of "
                    + "the list."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var found: String {
        let count = model.projects.count
        return "\(count) \(count == 1 ? "project" : "projects") found"
    }

    private func display(_ url: URL) -> String {
        ProjectRoots.abbreviate(url, home: model.paths.home)
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Use folder"
        panel.message = "Choose a folder that holds your repositories — or a repository itself."
        guard panel.runModal() == .OK else { return }
        // Appended rather than replacing, and a folder chosen twice is not added twice.
        var folders = model.projectRoots.folders
        for url in panel.urls where !folders.contains(where: {
            $0.standardizedFileURL == url.standardizedFileURL
        }) {
            folders.append(url)
        }
        model.setProjectRoots(folders)
    }

    private func remove(_ folder: URL) {
        model.setProjectRoots(model.projectRoots.folders.filter { $0 != folder })
    }
}

// MARK: - Usage

struct UsageTab: View {
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
            .pointingHand()

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
                    .pointingHand(enabled: model.indexProgress == nil)
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

// MARK: - Updates

/// The visible half of Sparkle: which version is running, whether the daily check is on, when it
/// last got an answer, and a button that asks now.
///
/// Everything here reads and writes Sparkle's own state rather than keeping a copy. Loadout 0.3.2
/// had a pane that stored its own switch and its own "last checked" date, which is how a Settings
/// screen ends up disagreeing with the app it belongs to. Press "Check now" and Sparkle puts up
/// its standard window — the one that shows the release notes and does the installing — so the
/// answer arrives in the place that can act on it.
struct UpdatesTab: View {
    /// Mirrors of Sparkle's preference, because SwiftUI needs something it can observe. `set` on
    /// the binding writes through to the updater; nothing else ever writes this.
    @State private var checksAutomatically = Updates.automaticallyChecksForUpdates
    @State private var lastCheck: Date? = Updates.lastCheck

    var body: some View {
        Form {
            LabeledContent("Version", value: Updates.current ?? "Unreleased build")

            Toggle("Check for updates automatically", isOn: Binding(
                get: { checksAutomatically },
                set: { newValue in
                    checksAutomatically = newValue
                    Updates.automaticallyChecksForUpdates = newValue
                }
            ))
            .help(
                "Asks the release feed for a new version about once a day, and offers to install "
                    + "it. No files and no identifiers are sent — and off means Loadout makes no "
                    + "network call at all."
            )

            LabeledContent("Last checked", value: lastCheckLine)

            HStack {
                Spacer()
                Button("Check now") { check() }
                    .help("Ask right now, whether or not the automatic check is on")
                    .pointingHand()
            }

            Text(
                "An update is downloaded and installed by Loadout itself. It is only accepted if "
                    + "it is signed with the key this copy was built with, so a tampered download "
                    + "is refused rather than installed."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Sparkle has no date until the first check completes, and "Never" is a truer answer for a
    /// fresh install than a date invented to fill the row.
    private var lastCheckLine: String {
        guard let lastCheck else { return "Never" }
        return lastCheck.formatted(date: .abbreviated, time: .shortened)
    }

    /// Sparkle owns the window that follows, so there is nothing to show in the pane afterwards —
    /// only the date to catch up with, once the check has had a moment to land.
    private func check() {
        Updates.checkNow()
        Task {
            try? await Task.sleep(for: .seconds(2))
            lastCheck = Updates.lastCheck
        }
    }
}

// MARK: - Assistants

/// The pane behind Settings › Assistants.
///
/// Written as `SettingsGroup` cards like every other section: this was a `List` with an infinite
/// height, and a list that asks for all the height there is renders nothing at all inside the
/// pane's scroll view — the section counted 12 assistants in the sidebar and then showed an empty
/// page.
struct AssistantsTab: View {
    @Bindable var model: AppModel

    var body: some View {
        SettingsGroup(
            title: "Assistants",
            note: "A checked assistant shows up in the list rows and the detail panel, and its "
                + "sessions count towards \"uses\". Unchecking one does both: it disappears from "
                + "the list and stops counting.",
            footnote: "Nothing is deleted — check it again and the same numbers come back. Sharing "
                + "and syncing keep working either way."
        ) {
            ForEach(Array(model.assistants.enumerated()), id: \.element.id) { index, assistant in
                AssistantSettingsRow(
                    model: model,
                    assistant: assistant,
                    dividing: index < model.assistants.count - 1
                )
            }
        }

        SettingsGroup(
            title: "Ask CLIs",
            note: "What \"Ask\" in a skill's detail runs. The four built-ins show up on their own "
                + "once installed; add anything else by hand."
        ) {
            ForEach(model.assistantCLIs) { cli in
                AskCLIRow(model: model, cli: cli)
            }
            SettingsRow(
                label: "Add a CLI of your own",
                sub: "Point Loadout at any command that takes a prompt",
                dividing: false
            ) {
                Button("Add…") { model.isAddingAssistantCLI = true }
                    .buttonStyle(V2ToolbarButtonStyle(prominent: false, enabled: true))
                    .pointingHand()
            }
        }
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
                    .pointingHand(enabled: !testing)
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
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Hairline(color: Color.white.opacity(0.06)).padding(.leading, 14)
        }
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
    /// The last row in a card draws no separator — a line under it would point at nothing.
    var dividing = true

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
            .pointingHand()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            if dividing { Hairline(color: Color.white.opacity(0.06)).padding(.leading, 14) }
        }
    }
}

// MARK: - Backups

struct StorageTab: View {
    @Bindable var model: AppModel
    @State private var isCounting = false
    @State private var report = Housekeeping.Report()
    @State private var isDeleting = false
    @State private var confirmingDelete = false
    @State private var resultMessage: String?

    var body: some View {
        Form {
            Section {
                if isCounting {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Counting…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    LabeledContent("Snapshots", value: "\(report.snapshots)")
                    LabeledContent(
                        "Size on disk",
                        value: ByteCountFormatter.string(fromByteCount: report.bytes, countStyle: .file)
                    )
                    if report.strandedRecords > 0 {
                        LabeledContent("Records for things that are gone", value: "\(report.strandedRecords)")
                    }
                }

                HStack {
                    Button("Show in Finder") { model.revealBackups() }
                        .help("Reveal \(model.paths.backups.path) in Finder")
                        .pointingHand()
                    Spacer()
                    Button("Clean up now") { confirmingDelete = true }
                        .disabled(isDeleting || isCounting || report.isEmpty)
                        .help(
                            report.isEmpty
                                ? "Nothing to clear right now"
                                : "Sweep snapshots older than 30 days and records for things that no longer exist"
                        )
                        .pointingHand(enabled: !(isDeleting || isCounting || report.isEmpty))
                }

                if let resultMessage {
                    Text(resultMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("What Loadout keeps")
            } footer: {
                Text(
                    "Before every edit Loadout copies the file, which is why a mistake is "
                    + "survivable. Copies older than 30 days are swept automatically at launch, "
                    + "to the Trash — so nothing is gone until you empty it."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if !report.unreadableRecords.isEmpty {
                Section {
                    ForEach(report.unreadableRecords, id: \.self) { url in
                        Text(url.lastPathComponent)
                            .font(.system(size: 12, design: .monospaced))
                    }
                    Button("Show in Finder") { model.revealBackups() }
                        .pointingHand()
                } header: {
                    Text("Couldn’t be read")
                } footer: {
                    // Never swept: an unreadable file is a question, and deleting it answers it
                    // the wrong way. Something switched off may be recorded in here.
                    Text(
                        "These are Loadout’s own records and something switched off may be "
                        + "written in them. They are left alone rather than cleared, so nothing "
                        + "is lost while the cause is unknown."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await recount() }
        .alert("Clean up now?", isPresented: $confirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Clean up", role: .destructive) { Task { await sweep() } }
        } message: {
            Text(
                "Backup copies older than 30 days go to the Trash, and records for things that no "
                + "longer exist are forgotten. Nothing you wrote is touched."
            )
        }
    }

    private func recount() async {
        isCounting = true
        let housekeeping = Housekeeping(paths: model.paths)
        // Sizing every snapshot is not cheap, so it runs off the main thread — the whole reason
        // this is a task rather than a computed property.
        report = await Task.detached(priority: .utility) { housekeeping.report() }.value
        isCounting = false
    }

    private func sweep() async {
        isDeleting = true
        let housekeeping = Housekeeping(paths: model.paths)
        let done = await Task.detached(priority: .utility) {
            (try? housekeeping.sweep()) ?? Housekeeping.Report()
        }.value
        resultMessage = describe(done)
        isDeleting = false
        await recount()
    }

    private func describe(_ done: Housekeeping.Report) -> String {
        var parts: [String] = []
        if done.expiredSnapshots > 0 {
            parts.append("\(done.expiredSnapshots) \(done.expiredSnapshots == 1 ? "snapshot" : "snapshots")")
        }
        if done.strandedRecords > 0 {
            parts.append("\(done.strandedRecords) \(done.strandedRecords == 1 ? "record" : "records")")
        }
        return parts.isEmpty ? "Nothing to clear." : "Cleared " + parts.joined(separator: " and ") + "."
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
