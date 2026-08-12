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
        model.createSkill(name: "auto-teste", description: "Criada pela auto-verificação.")
        check("cria uma skill", model.items.contains { $0.name == "auto-teste" })
        check("fica selecionada", model.selected?.name == "auto-teste")
        check("carrega o ficheiro para o editor", model.draft.contains("name: auto-teste"))

        // Edit and save
        model.draft = "---\nname: auto-teste\ndescription: Descrição nova.\n---\n\nCorpo novo."
        model.isDirty = true
        model.save()
        check("grava a edição", model.selected?.description == "Descrição nova.")
        check("deixa de estar por guardar", !model.isDirty)

        // Refuse invalid frontmatter
        model.draft = "---\ndescription: sem nome\n---\n"
        model.isDirty = true
        model.save()
        check("recusa frontmatter inválido", model.errorMessage != nil)
        check("não estraga o ficheiro", model.selected?.description == "Descrição nova.")
        model.errorMessage = nil
        model.loadDraft()

        // Disable and enable
        let created = model.items.first { $0.name == "auto-teste" }!
        model.toggle(created)
        check(
            "desativar move para skills-off",
            FileManager.default.fileExists(
                atPath: paths.skillsOff.appendingPathComponent("auto-teste/SKILL.md").path
            )
        )
        model.selection = .disabled
        check("aparece em Desativadas", model.count(for: .disabled) == 1)

        let parked = model.items.first { $0.name == "auto-teste" }!
        model.toggle(parked)
        check(
            "reativar traz de volta",
            FileManager.default.fileExists(
                atPath: paths.skills.appendingPathComponent("auto-teste/SKILL.md").path
            )
        )

        // Every write left a snapshot behind
        let backups = (FileManager.default.enumerator(at: paths.backups, includingPropertiesForKeys: nil)?
            .compactMap { ($0 as? URL)?.lastPathComponent } ?? [])
        check("deixou cópias de segurança", backups.contains("SKILL.md"))

        // Search
        model.selection = .personal
        model.query = "DESCRICAO"
        check("procura sem acentos nem maiúsculas", model.visibleItems.count == 1)
        model.query = "nada disto existe"
        check("filtra o que não corresponde", model.visibleItems.isEmpty)
        model.query = ""

        // Delete
        model.select(model.items.first { $0.name == "auto-teste" }?.id)
        model.deleteSelected()
        check("apagar tira da lista", !model.items.contains { $0.name == "auto-teste" })

        print(failures.isEmpty
              ? "\nTudo bem: \(total) verificações passaram."
              : "\nFalhou \(failures.count) de \(total): \(failures.joined(separator: ", "))")
        exit(failures.isEmpty ? 0 : 1)
    }
}
