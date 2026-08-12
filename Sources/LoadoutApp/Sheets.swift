import SwiftUI
import LoadoutCore

/// Create a skill (AC4.3).
struct NewSkillSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Nova skill")
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 5) {
                TextField("nome-da-skill", text: $name)
                    .textFieldStyle(.roundedBorder)
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(isNameValid || name.isEmpty ? Color.secondary : Color.red)
            }

            VStack(alignment: .leading, spacing: 5) {
                TextField("Quando é que esta skill deve disparar", text: $description, axis: .vertical)
                    .lineLimit(3...5)
                    .textFieldStyle(.roundedBorder)
                Text("A description é o que faz o Claude escolher a skill. Diz quando usar, não o que é.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Criar") {
                    model.createSkill(name: name, description: description)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isNameValid)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var isNameValid: Bool { isValidSkillName(name) }

    private var hint: String {
        if name.isEmpty { return "Minúsculas, números e hífenes. Vai ser o nome da pasta." }
        return isNameValid ? "~/.claude/skills/\(name)/SKILL.md" : "Só minúsculas, números e hífenes."
    }
}

/// Ask Claude about the selected skill (AC7). Nothing is written without a decision here.
struct CopilotSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var prompt = "Melhora a description desta skill para disparar nas alturas certas, e explica o que mudaste."
    @State private var answer = ""
    @State private var running = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pedir ao Claude")
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
                Text(answer.isEmpty ? "A resposta aparece aqui. Nada é escrito sem seres tu a decidir." : answer)
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
                Button("Fechar") {
                    model.copilot.cancel()
                    dismiss()
                }
                if running {
                    Button("Cancelar") { model.copilot.cancel() }
                } else {
                    Button("Perguntar") { ask() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Button("Copiar resposta") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(answer, forType: .string)
                }
                .disabled(answer.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 620)
    }

    private var subtitle: String {
        guard let item = model.selected else { return "" }
        return "Corre claude -p na pasta de \(item.name)."
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

        Task.detached(priority: .userInitiated) {
            do {
                let result = try copilot.run(prompt: question, in: directory)
                await MainActor.run {
                    answer = result.output
                    failure = result.timedOut ? "O pedido excedeu o tempo e foi terminado." : nil
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
