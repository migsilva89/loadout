import AppKit
import SwiftUI
import LoadoutCore

/// The first thing somebody sees, once.
///
/// It exists because of one real failure. A person installed Loadout, saw a full list of 83 skills,
/// and concluded it could not see their projects — when in truth their project skills were one
/// click away behind the scope button at the top left of the list, a control they had no reason to
/// suspect was a control. Nothing was broken and nothing was empty; the app simply never said
/// there were two places to look.
///
/// So it does two things and stops. It states what was already found, which proves the app works
/// before it asks for anything. And it names that button out loud — drawing it, so it is
/// recognisable in the window afterwards — while asking the one question the app cannot answer for
/// itself: which folders hold your repositories.
///
/// Whatever is decided here is also in Settings › Projects, because a sheet that runs once in a
/// lifetime cannot be the only way to change your mind.
struct WelcomeSheet: View {
    @Bindable var model: AppModel
    let onClose: () -> Void

    /// The folders offered, and which are ticked. Seeded from the places people keep code, so the
    /// answer is a confirmation rather than a blank field.
    @State private var offered: [URL] = []
    @State private var chosen: Set<URL> = []
    /// How many repositories each offered folder holds, worked out once per folder.
    ///
    /// Counting means walking the disk three levels deep. Doing that inside `body` meant every tick
    /// of a checkbox re-walked every folder on the main thread, so a `~/Projects` with 79
    /// repositories in it paid for the walk again on each click.
    @State private var repositoryCounts: [URL: Int] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                identity
                claim
                counts
                scopeNote
            }
            .padding(.horizontal, 30)
            .padding(.top, 26)
            .padding(.bottom, 22)

            Hairline(color: V2.hairline)

            question
                .padding(.horizontal, 30)
                .padding(.top, 20)
                .padding(.bottom, 22)

            footer
        }
        .frame(width: 620)
        .background(V2.window)
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(V2.hairline, lineWidth: 0.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onAppear {
            offered = ProjectRoots.likelyFolders(home: model.paths.home)
            chosen = Set(offered)
            countRepositories(in: offered)
        }
    }

    // MARK: - Identity and claim

    private var identity: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(V2.grad)
                .frame(width: 34, height: 34)
                .overlay {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                }
            Text("LOADOUT")
                .font(.system(size: 12.5, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(Color.white.opacity(0.55))
        }
    }

    private var claim: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Loadout has read what you have.")
                .font(.system(size: 23, weight: .semibold))
                .tracking(-0.5)
            Text("Everything below is already loaded globally — in every project you open.")
                .font(.system(size: 13))
                .foregroundStyle(V2.textMid)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - The counts

    /// Numbers rather than a sentence. This is the most persuasive thing on the screen — proof the
    /// app already works — and as prose it read like an apology.
    private var counts: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 1) {
                ForEach(Array(tallies.enumerated()), id: \.offset) { _, tally in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(tally.count)")
                            .font(.system(size: 26, weight: .semibold).monospacedDigit())
                        Text(tally.label)
                            .font(.system(size: 11.5))
                            .foregroundStyle(V2.textMid)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(V2.well)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(V2.hairline, lineWidth: 0.5)
            }

            if !model.assistants.isEmpty {
                assistantBadges
            }
        }
    }

    private var tallies: [(count: Int, label: String)] {
        [
            (model.items.filter { $0.kind == .skill }.count, "skills"),
            (model.items.filter { $0.kind == .command }.count, "commands"),
            (model.items.filter { $0.kind == .agent }.count, "subagents"),
            (model.items.filter { $0.kind == .mcp }.count, "MCP servers"),
        ]
    }

    /// Badges, not names. Printing all twelve was three lines of proper nouns burying the numbers
    /// they were meant to support; the marks say the same thing at a glance and the names live in
    /// the tooltips, where somebody who wants one can find it.
    private var assistantBadges: some View {
        HStack(spacing: 4) {
            ForEach(model.assistants) { assistant in
                AssistantMark(assistant: assistant, present: true, size: 22)
                    .help(assistant.label)
            }
            Text("across \(model.assistants.count) assistants")
                .font(.system(size: 12))
                .foregroundStyle(V2.textMid)
                .padding(.leading, 4)
        }
    }

    // MARK: - Naming the control

    /// The whole reason the sheet exists, so the button is drawn rather than described. A sentence
    /// about "the scope button" teaches nobody which shape to look for.
    private var scopeNote: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "info.circle")
                .font(.system(size: 12.5))
                .foregroundStyle(V2.link)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text("Each repository can have skills of its own.")
                    .font(.system(size: 12.5))
                // The chip on its own line rather than inside the sentence. Inline, the row was
                // one HStack and the words lost the fight for width — the sentence arrived
                // truncated as "pick the proj…", which is worse than no chip at all.
                Text("Those appear only when you pick the project from this button, at the top left of the list:")
                    .font(.system(size: 12.5))
                    .foregroundStyle(V2.textMid)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    scopeChip
                    Text("Two places to look, always.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(V2.textFaint)
                }
                .padding(.top, 2)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(V2.hairline, lineWidth: 0.5)
        }
    }

    /// Drawn to match the real control, glyph and word — "Global" is what it actually says when
    /// nothing is picked, and a chip here reading anything else would send people looking for a
    /// button that does not exist.
    private var scopeChip: some View {
        HStack(spacing: 4) {
            Image(systemName: "globe")
                .font(.system(size: 9))
            Text("Global")
                .font(.system(size: 11))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(V2.hairline, lineWidth: 0.5)
        }
        .foregroundStyle(Color.white.opacity(0.85))
    }

    // MARK: - The one question

    private var question: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Where do you keep your repositories?")
                    .font(.system(size: 16, weight: .semibold))
                Text("The one thing Loadout cannot work out on its own.")
                    .font(.system(size: 12))
                    .foregroundStyle(V2.textFaint)
            }

            if offered.isEmpty {
                Text("Nothing obvious found — point Loadout at a folder it should look inside, or at a "
                    + "repository itself.")
                    .font(.system(size: 12))
                    .foregroundStyle(V2.textMid)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(offered.enumerated()), id: \.element) { index, folder in
                        folderRow(folder, last: index == offered.count - 1)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(V2.hairline, lineWidth: 0.5)
                }
            }

            Button {
                addFolder()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Choose another folder…")
                        .font(.system(size: 12))
                }
            }
            .buttonStyle(V2ToolbarButtonStyle(prominent: false, enabled: true))
            .pointingHand()
        }
    }

    private func folderRow(_ folder: URL, last: Bool) -> some View {
        let on = chosen.contains(folder)
        return Button {
            if on { chosen.remove(folder) } else { chosen.insert(folder) }
        } label: {
            HStack(spacing: 10) {
                checkbox(on: on)
                Text(ProjectRoots.abbreviate(folder, home: model.paths.home))
                    .font(.system(size: 12.5, design: .monospaced))
                Spacer(minLength: 12)
                Text(repositoryCount(folder))
                    .font(.system(size: 11.5))
                    .foregroundStyle(V2.textFaint)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            // A ticked row carries a faint wash of the accent, so which ones are in is legible
            // from across the room rather than only from the little square.
            .background(on ? V2.accent.opacity(0.12) : V2.well)
            .overlay(alignment: .bottom) {
                if !last { Hairline(color: Color.white.opacity(0.06)) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHand()
    }

    /// Drawn rather than taken from AppKit. This is the first surface anybody sees, and a stock
    /// checkbox in the middle of it announces that the panel was assembled from parts.
    private func checkbox(on: Bool) -> some View {
        RoundedRectangle(cornerRadius: 4.5, style: .continuous)
            .fill(on ? V2.accent : Color.white.opacity(0.06))
            .frame(width: 17, height: 17)
            .overlay {
                RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                    .strokeBorder(on ? Color.clear : Color.white.opacity(0.18), lineWidth: 1)
            }
            .overlay {
                if on {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
    }

    private func repositoryCount(_ folder: URL) -> String {
        guard let count = repositoryCounts[folder] else { return "counting…" }
        return "\(count) \(count == 1 ? "repository" : "repositories")"
    }

    /// Off the main thread, and only for folders not counted yet.
    private func countRepositories(in folders: [URL]) {
        let home = model.paths.home
        let pending = folders.filter { repositoryCounts[$0] == nil }
        guard !pending.isEmpty else { return }
        Task.detached(priority: .userInitiated) {
            var found: [URL: Int] = [:]
            for folder in pending {
                found[folder] = ProjectRoots(folders: [folder]).discover(home: home).count
            }
            await MainActor.run { repositoryCounts.merge(found) { _, new in new } }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Text("You can change this any time in ")
                .foregroundStyle(V2.textFaint)
            + Text("Settings › Projects")
                .foregroundStyle(Color.white.opacity(0.55))

            Spacer(minLength: 12)

            Button("Not now") { finish(saving: false) }
                .buttonStyle(V2ToolbarButtonStyle(prominent: false, enabled: true))
                .pointingHand()

            Button {
                finish(saving: true)
            } label: {
                HStack(spacing: 6) {
                    Text(primaryTitle)
                    Text("↵")
                        .opacity(0.6)
                }
                .font(.system(size: 12))
            }
            .buttonStyle(V2ToolbarButtonStyle(prominent: true, enabled: true))
            .keyboardShortcut(.defaultAction)
            .pointingHand()
        }
        .font(.system(size: 11.5))
        .padding(.leading, 30)
        .padding(.trailing, 20)
        .padding(.vertical, 13)
        .background(Color.black.opacity(0.22))
        .overlay(alignment: .top) { Hairline(color: V2.hairline) }
    }

    /// The count is in the button, so pressing it is not a leap of faith. With nothing ticked it
    /// says what it will really do, which is nothing — and "Not now" is then the honest twin.
    private var primaryTitle: String {
        let count = chosen.count
        guard count > 0 else { return "Continue" }
        return "Scan \(count) \(count == 1 ? "folder" : "folders")"
    }

    /// "Not now" still closes for good. Asking again on the next launch would be nagging, and the
    /// same question lives in Settings › Projects.
    private func finish(saving: Bool) {
        if saving, !chosen.isEmpty {
            model.setProjectRoots(offered.filter { chosen.contains($0) })
        }
        onClose()
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Use folder"
        panel.message = "Choose a folder that holds your repositories — or a repository itself."
        guard panel.runModal() == .OK else { return }
        // Compared standardized, the way Settings › Projects does it. Raw `URL` equality counts
        // `~/Projects` and `~/Projects/` as two different folders, and the panel hands back the
        // trailing slash — so choosing a folder already on the list listed it twice.
        for url in panel.urls where !offered.contains(where: {
            $0.standardizedFileURL == url.standardizedFileURL
        }) {
            offered.append(url)
            chosen.insert(url)
        }
        countRepositories(in: offered)
    }
}
