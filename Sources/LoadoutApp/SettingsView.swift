import SwiftUI
import AppKit
import LoadoutCore

/// ⌘, opens this. Four tabs, one per thing a person occasionally needs to change and would
/// otherwise have no obvious place to find.
struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            AppearanceTab()
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
            UsageTab(model: model)
                .tabItem { Label("Usage", systemImage: "chart.bar") }
            AssistantsTab(model: model)
                .tabItem { Label("Assistants", systemImage: "person.2") }
            BackupsTab(model: model)
                .tabItem { Label("Backups", systemImage: "clock.arrow.circlepath") }
        }
        .frame(width: 520, height: 400)
    }
}

// MARK: - Appearance

private struct AppearanceTab: View {
    // Read where `LoadoutApp.init` and `AppAppearance.apply()` write, so a change here is
    // both persisted and reflected immediately without a restart.
    @AppStorage("appearance") private var appearance: String = AppAppearance.system.rawValue

    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) {
                ForEach(AppAppearance.allCases, id: \.rawValue) { option in
                    Text(option.label).tag(option.rawValue)
                }
            }
            .pickerStyle(.radioGroup)
            .onChange(of: appearance) { _, newValue in
                (AppAppearance(rawValue: newValue) ?? .system).apply()
            }
            .help("Sets the window's light or dark appearance immediately, and remembers it for next launch")
            Text("System follows the Mac's own setting. LOADOUT_APPEARANCE, when set, overrides this at launch.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        // Grouped is what System Settings looks like, and it pins content to the top of the
        // pane instead of floating it in the middle of a fixed-size tab.
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
            Picker("Index transcripts from", selection: $windowRaw) {
                ForEach(Self.options, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .onChange(of: windowRaw) { _, _ in model.reindexUsage(windowDays: windowDays) }
            .help("How far back to scan Claude Code transcripts for usage counts; stored in this Mac's preferences")

            LabeledContent("Indexed transcripts", value: "\(model.indexedFileCount)")
            LabeledContent("Indexed events", value: "\(model.indexedEventCount)")

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
                    .help("Rescan transcripts now, using the window chosen above")
                    .pointingHand()
            }
        }
        // Grouped is what System Settings looks like, and it pins content to the top of the
        // pane instead of floating it in the middle of a fixed-size tab.
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
                Text("Assistants unchecked here still work — sharing and syncing keep going. They just don't show up in the list rows or the detail panel.")
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
            Toggle("Show in list", isOn: Binding(
                get: { !model.hiddenAssistantIDs.contains(assistant.id) },
                set: { model.setAssistantHidden(assistant, hidden: !$0) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .help(
                "Show or hide \(assistant.label) in the list rows and detail panel. "
                    + "Sharing and syncing keep working either way."
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
