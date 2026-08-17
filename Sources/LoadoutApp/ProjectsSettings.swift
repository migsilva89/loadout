import AppKit
import SwiftUI
import LoadoutCore

/// Where Loadout looks for repositories.
///
/// This is the whole of what a person has to keep up to date, and it is deliberately the short
/// list: two or three folders, chosen once. What is inside them is worked out on every launch, so a
/// repository cloned this morning is in the list this afternoon with nobody maintaining anything.
///
/// It replaced a single generated file, `~/Projects/INDEX.md`, that one person kept by hand.
/// Reading it was worse than useless to everybody else: they opened the app to no projects and no
/// explanation, because their global skills filled the list and nothing said the other half was
/// behind a control they had never pressed. Hence the footnote naming that control out loud — and
/// hence one source here, not two, so this screen never has to describe somebody's habit.
struct ProjectsSettings: View {
    @Bindable var model: AppModel

    /// Repositories per folder, counted off the main thread. Walking three levels of directories
    /// inside `body` meant every redraw of this pane re-walked every folder.
    @State private var counts: [URL: Int] = [:]

    var body: some View {
        SettingsGroup(
            title: "Where your projects live",
            // The depth is interpolated, not spelled out: the sentence said two while the search
            // went three deep, and the row below it printed the real number two lines away.
            note: "Loadout looks inside these for repositories — anything with a .git or a .claude "
                + "inside, up to \(ProjectRoots.searchDepth) levels down.",
            footnote: "A project's own skills and commands appear once you pick it from the scope "
                + "button above the list."
        ) {
            ForEach(model.projectRoots.folders, id: \.self) { folder in
                SettingsRow(
                    label: ProjectRoots.abbreviate(folder, home: model.paths.home),
                    sub: countIn(folder),
                    mono: true
                ) {
                    SettingsLinkButton(
                        title: "Remove",
                        help: "Stop looking in \(ProjectRoots.abbreviate(folder, home: model.paths.home))"
                    ) {
                        model.setProjectRoots(model.projectRoots.folders.filter { $0 != folder })
                    }
                }
            }

            // The count sits on this row on purpose, next to the thing that produces it. It was
            // briefly here while a second, hidden source was also feeding the list, which made it
            // read as a lie: "nothing chosen" over "89 projects found".
            SettingsRow(
                label: model.projectRoots.folders.isEmpty ? "Choose your first folder" : "Add another folder",
                sub: model.projectRoots.folders.isEmpty
                    ? "Until you do, only what is loaded globally is listed"
                    : found,
                dividing: false
            ) {
                Button("Choose…") { add() }
                    .buttonStyle(V2ToolbarButtonStyle(
                        prominent: model.projectRoots.folders.isEmpty, enabled: true
                    ))
                    .help("Choose a folder Loadout should look in for repositories")
                    .pointingHand()
            }
        }

        SettingsGroup(
            title: "Scanning",
            footnote: "Read at every launch, and again whenever you change these folders. Nothing "
                + "is written inside your repositories — Loadout only looks."
        ) {
            SettingsRow(label: "Search depth") {
                SettingsValue(text: "\(ProjectRoots.searchDepth) levels")
            }
            SettingsRow(
                label: "What counts as a project",
                sub: "A folder holding a .git or a .claude",
                dividing: false
            ) {
                EmptyView()
            }
        }
        .onAppear { countRepositories() }
        .onChange(of: model.projectRoots.folders) { _, _ in countRepositories() }
    }

    private var found: String {
        let count = model.projects.count
        return "\(count) \(count == 1 ? "project" : "projects") found"
    }

    /// How many projects came out of this folder in particular, so a folder that turned out to
    /// hold nothing says so instead of sitting there looking fine.
    /// Reads the count worked out off the main thread rather than walking the disk here: this is
    /// called from `body`, and counting means three levels of directory listing per folder.
    private func countIn(_ folder: URL) -> String {
        guard let count = counts[folder] else { return "counting…" }
        guard count > 0 else { return "no repositories found in here" }
        return "\(count) \(count == 1 ? "project" : "projects")"
    }

    private func countRepositories() {
        let home = model.paths.home
        let folders = model.projectRoots.folders
        Task.detached(priority: .userInitiated) {
            var found: [URL: Int] = [:]
            for folder in folders {
                found[folder] = ProjectRoots(folders: [folder]).discover(home: home).count
            }
            await MainActor.run { counts = found }
        }
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Use folder"
        panel.message = "Choose a folder Loadout should look in for repositories."
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
}
