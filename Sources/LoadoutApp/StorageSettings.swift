import SwiftUI
import LoadoutCore

/// What Loadout has left on disk, and clearing it.
///
/// Before every edit the app copies the file, which is the only reason a mistake is survivable —
/// and for a long time nothing ever removed a copy, so a year of editing left a year of copies and
/// the only way to notice was to go looking at your own disk. Sweeping now happens at every launch;
/// this screen is where you see what is there and clear it on demand.
struct StorageSettings: View {
    @Bindable var model: AppModel

    @State private var isCounting = false
    @State private var report = Housekeeping.Report()
    @State private var isClearing = false
    @State private var confirming = false
    @State private var resultMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            groups
        }
        .task { await recount() }
        .alert("Clean up now?", isPresented: $confirming) {
            Button("Cancel", role: .cancel) {}
            Button("Clean up", role: .destructive) { Task { await sweep() } }
        } message: {
            Text(
                "Backup copies older than 30 days go to the Trash, and records for things that no "
                + "longer exist are forgotten. Nothing you wrote is touched."
            )
        }
    }

    @ViewBuilder
    private var groups: some View {
        SettingsGroup(
            title: "What Loadout keeps",
            note: "A copy of every file it is about to change, plus small records so anything "
                + "switched off can be put back exactly as it was.",
            footnote: "Copies older than 30 days are swept at launch, to the Trash — so nothing is "
                + "really gone until you empty it."
        ) {
            SettingsRow(label: "Snapshots") {
                if isCounting {
                    ProgressView().controlSize(.small)
                } else {
                    SettingsValue(text: "\(report.snapshots)")
                }
            }
            SettingsRow(label: "Size on disk") {
                SettingsValue(
                    text: ByteCountFormatter.string(fromByteCount: report.bytes, countStyle: .file)
                )
            }
            if report.strandedRecords > 0 {
                SettingsRow(
                    label: "Records for things that are gone",
                    sub: "Nothing on this Mac refers to them any more"
                ) {
                    SettingsValue(text: "\(report.strandedRecords)")
                }
            }
            SettingsRow(label: "Folder", mono: true) {
                SettingsLinkButton(title: "Reveal", help: model.paths.backups.path) {
                    model.revealBackups()
                }
            }
            SettingsRow(
                label: "Clean up now",
                sub: report.isEmpty ? "Nothing to clear right now" : resultMessage,
                dividing: false
            ) {
                Button("Clean up") { confirming = true }
                    .buttonStyle(V2ToolbarButtonStyle(
                        prominent: false, enabled: !(isClearing || isCounting || report.isEmpty)
                    ))
                    .disabled(isClearing || isCounting || report.isEmpty)
                    .pointingHand(enabled: !(isClearing || isCounting || report.isEmpty))
            }
        }

        if !report.unreadableRecords.isEmpty {
            SettingsGroup(
                title: "Couldn’t be read",
                note: "These are Loadout’s own records, and something switched off may be written "
                    + "in them.",
                // Never swept, on purpose: a file nobody can read is a question, and deleting it
                // answers it the wrong way.
                footnote: "They are left alone rather than cleared, so nothing is lost while the "
                    + "cause is unknown."
            ) {
                ForEach(Array(report.unreadableRecords.enumerated()), id: \.element) { index, url in
                    SettingsRow(
                        label: url.lastPathComponent,
                        mono: true,
                        dividing: index < report.unreadableRecords.count - 1
                    ) {
                        SettingsLinkButton(title: "Reveal") { model.revealBackups() }
                    }
                }
            }
        }
    }

    private func recount() async {
        isCounting = true
        let housekeeping = Housekeeping(paths: model.paths)
        // Sizing every snapshot walks the whole tree, which is why this is a task and not a
        // computed property: on a big backups folder it is tens of milliseconds of I/O.
        report = await Task.detached(priority: .utility) { housekeeping.report() }.value
        isCounting = false
    }

    private func sweep() async {
        isClearing = true
        let housekeeping = Housekeeping(paths: model.paths)
        let done = await Task.detached(priority: .utility) {
            (try? housekeeping.sweep()) ?? Housekeeping.Report()
        }.value
        resultMessage = describe(done)
        isClearing = false
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
