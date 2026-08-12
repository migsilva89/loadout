import Foundation
import LoadoutCore

/// `Loadout --self-check` drives the window's own model — the layer between the buttons and
/// the disk — against a throwaway home directory, then prints what happened.
///
/// The unit tests cover `LoadoutCore`; this covers the wiring the tests cannot reach, without
/// ever pointing at the real `~/.claude`.
@MainActor
enum SelfCheck {
    static func run() -> Never {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("loadout-self-check-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = Paths(home: root)
        try! FileManager.default.createDirectory(at: paths.skills, withIntermediateDirectories: true)
        let model = AppModel(paths: paths)
        var failures: [String] = []
        var total = 0

        func check(_ label: String, _ condition: @autoclosure () -> Bool) {
            total += 1
            let ok = condition()
            print("\(ok ? "✓" : "✗") \(label)")
            if !ok { failures.append(label) }
        }

        // Create
        model.createSkill(name: "auto-teste", description: "Created by the self-check.")
        check("creates a skill", model.items.contains { $0.name == "auto-teste" })
        check("selects it", model.selected?.name == "auto-teste")
        check("loads the file in the editor", model.draft.contains("name: auto-teste"))

        // Edit and save
        model.draft = "---\nname: auto-teste\ndescription: New résumé.\n---\n\nNew body."
        model.isDirty = true
        model.save()
        check("saves the edit", model.selected?.description == "New résumé.")
        check("clears the unsaved state", !model.isDirty)

        // Refuse invalid frontmatter
        model.draft = "---\ndescription: no name\n---\n"
        model.isDirty = true
        model.save()
        check("rejects invalid frontmatter", model.errorMessage != nil)
        check("doesn't damage the file", model.selected?.description == "New résumé.")
        model.errorMessage = nil
        model.loadDraft()

        // Disable and enable
        let created = model.items.first { $0.name == "auto-teste" }!
        model.toggle(created)
        check(
            "disabling moves it to skills-off",
            FileManager.default.fileExists(
                atPath: paths.skillsOff.appendingPathComponent("auto-teste/SKILL.md").path
            )
        )
        model.selection = .disabled
        check("appears under Disabled", model.count(for: .disabled) == 1)

        let parked = model.items.first { $0.name == "auto-teste" }!
        model.toggle(parked)
        check(
            "enabling brings it back",
            FileManager.default.fileExists(
                atPath: paths.skills.appendingPathComponent("auto-teste/SKILL.md").path
            )
        )

        // Every write left a snapshot behind
        let backups = (FileManager.default.enumerator(at: paths.backups, includingPropertiesForKeys: nil)?
            .compactMap { ($0 as? URL)?.lastPathComponent } ?? [])
        check("leaves backups", backups.contains("SKILL.md"))

        // Search
        model.selection = .personal
        model.query = "RESUME"
        check("searches without accents or case", model.visibleItems.count == 1)
        model.query = "this doesn't exist"
        check("filters out nonmatches", model.visibleItems.isEmpty)
        model.query = ""

        // Delete
        model.select(model.items.first { $0.name == "auto-teste" }?.id)
        model.deleteSelected()
        check("deleting removes it from the list", !model.items.contains { $0.name == "auto-teste" })

        print(failures.isEmpty
              ? "\nAll good: \(total) checks passed."
              : "\n\(failures.count) of \(total) checks failed: \(failures.joined(separator: ", "))")
        exit(failures.isEmpty ? 0 : 1)
    }
}
