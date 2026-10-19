import SwiftUI
import LoadoutCore

/// The MCP tab's second face: one row per server, one column per assistant, a square per cell.
///
/// The list answers "what do I have and whose is it"; this answers the other question — "who has
/// this, and who is missing it" — with the fix next to the answer: an empty square is the button
/// that puts the server there, in that assistant's own format, from whichever assistant's
/// definition is already on the machine.
struct MCPMatrixView: View {
    @Bindable var model: AppModel

    /// Fixed squares down the column, the name takes what is left: seven assistants still leave
    /// the name readable in the narrowest sidebar the divider allows.
    private static let columnWidth: CGFloat = 40
    private static let rowHeight: CGFloat = 44

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Hairline()
            matrix
            Hairline()
            footnote
        }
        .background(V2.sidebar)
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 8) {
            segmented
            Spacer(minLength: 6)
            addButton
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }

    /// List and Sharing as the two halves they are. The same lifted-tile shape the kind tabs
    /// use, so a mode switch always looks like this one.
    private var segmented: some View {
        HStack(spacing: 1) {
            segment("List", selected: false) { model.showsMCPSharing = false }
            segment("Sharing", selected: true) { }
        }
        .padding(2)
        .background(V2.well, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .strokeBorder(Color.black.opacity(0.5), lineWidth: 0.5))
    }

    private func segment(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? V2.text : V2.textDim)
                .padding(.horizontal, 10)
                .frame(height: 20)
                .background(selected ? V2.buttonHover : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .pointingHand()
    }

    private var addButton: some View {
        Button { model.isAddingMCPServer = true } label: {
            HStack(spacing: 5) {
                Image(systemName: "plus").font(.system(size: 10.5, weight: .medium))
                Text("Add MCP").font(.system(size: 12))
            }
            .foregroundStyle(Color.white.opacity(0.88))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(V2.button, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(V2.hairline, lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help("One definition, written into every assistant you pick")
        .pointingHand()
    }

    // MARK: - The matrix

    private var matrix: some View {
        ScrollView([.vertical]) {
            LazyVStack(spacing: 0) {
                headerRow
                Hairline()
                if model.mcpMatrixRows.isEmpty {
                    emptyState
                } else {
                    ForEach(model.mcpMatrixRows) { row in
                        matrixRow(row)
                        Hairline()
                    }
                }
            }
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            Text("Name")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(V2.textDim)
                .padding(.leading, 14)
            Spacer(minLength: 8)
            ForEach(model.mcpColumns) { assistant in
                VStack(spacing: 2) {
                    AssistantMark(assistant: assistant, present: true, size: 18)
                    Text("\(countOn(for: assistant.id))")
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                        .foregroundStyle(V2.textDim)
                        .monospacedDigit()
                }
                .frame(width: Self.columnWidth)
                .help("\(assistant.label) — servers switched on")
            }
            .padding(.trailing, 8)
        }
        .frame(height: 40)
    }

    private func countOn(for assistant: String) -> Int {
        model.mcpMatrixRows.filter { $0.cells[assistant]?.state == .on }.count
    }

    private func matrixRow(_ row: MCPMatrixRow) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(V2.text)
                    .lineLimit(1)
                Text(row.description)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(V2.textDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.leading, 14)
            Spacer(minLength: 8)
            ForEach(model.mcpColumns.map(\.id), id: \.self) { assistant in
                cell(row, assistant)
                    .frame(width: Self.columnWidth, height: Self.rowHeight)
            }
            .padding(.trailing, 8)
        }
        .frame(height: Self.rowHeight)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func cell(_ row: MCPMatrixRow, _ assistant: String) -> some View {
        if let cell = row.cells[assistant] {
            MatrixCheckbox(state: cell.state, refusal: cell.refusal) {
                if cell.refusal != nil && cell.state == .absent {
                    model.errorMessage = cell.refusal
                    return
                }
                model.setMCPMatrixCell(row, assistant: assistant, on: cell.state != .on)
            }
            .help(cellHint(cell, row: row))
        }
    }

    private func cellHint(_ cell: MCPMatrixRow.Cell, row: MCPMatrixRow) -> String {
        let label = model.mcpColumns.first { $0.id == cell.assistant }?.label ?? cell.assistant
        if let refusal = cell.refusal, cell.state == .absent { return refusal }
        switch cell.state {
        case .on: return "\(label) has \(row.name) on — press to switch it off"
        case .off: return "\(label) has \(row.name) switched off — press to put it back on"
        case .absent: return "\(label) doesn't have \(row.name) — press to put it there"
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No servers yet",
            systemImage: "square.grid.3x3",
            description: Text("Every assistant's MCP config is read here. Add a server to put it on all of them at once.")
        )
        .frame(maxHeight: 200)
    }

    // MARK: - Footnote

    private var footnote: some View {
        Text("A checked square means on in that assistant's own config. Loadout translates the definition for each one and copies every file before writing it; edits made directly in an app show up here on their own.")
            .font(.system(size: 10.5))
            .foregroundStyle(V2.textDim)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
    }
}

/// The square every cell is made of. Checked is the accent; present-but-off is a dash rather
/// than an empty box, so "configured but off" never reads as "not there"; and something Loadout
/// refuses to write shows the square with a slash through it rather than a control that only
/// apologises when pressed.
private struct MatrixCheckbox: View {
    let state: MCPMatrixRow.Cell.State
    let refusal: String?
    let action: () -> Void

    @State private var hovering = false

    private var size: CGFloat { 15 }

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 4.5)
                    .strokeBorder(borderColor, lineWidth: 1.2)
                    .background(
                        RoundedRectangle(cornerRadius: 4.5)
                            .fill(state == .on ? V2.accent : Color.clear)
                    )
                switch state {
                case .on:
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.white)
                case .off:
                    Rectangle()
                        .fill(V2.textDim)
                        .frame(width: 7, height: 1.5)
                case .absent:
                    if refusal != nil {
                        Image(systemName: "slash")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(V2.textFaint)
                    }
                }
            }
            .frame(width: size, height: size)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHand()
        .opacity(hovering && state == .absent && refusal == nil ? 0.75 : 1)
        .onContinuousHover { phase in
            if case .active = phase { hovering = true } else { hovering = false }
        }
    }

    private var borderColor: Color {
        switch state {
        case .on: return V2.accent
        case .off: return V2.muted
        case .absent: return hovering ? V2.textDim : V2.hairline
        }
    }
}

// MARK: - Add MCP

/// One server, named once, written into every assistant chosen — translated into each one's own
/// format. An assistant that already has a server of this name keeps its own definition and is
/// reported afterwards, never overwritten.
struct MCPAddSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var isRemote = false
    @State private var command = ""
    @State private var url = ""
    @State private var chosen: Set<String> = []
    @FocusState private var focus: Field?

    private enum Field { case name, command, url }

    /// Codex is deliberately not here: its servers live in TOML behind its own protocol, and
    /// adding one is `codex mcp add`. The matrix shows its column — switching what exists works
    /// — but a form that could only apologise has no place in a form.
    private var assistants: [Assistant] {
        model.mcpColumns.filter { $0.id != "codex" }
    }

    private var valid: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !chosen.isEmpty else { return false }
        if isRemote {
            return !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 15) {
                heading
                nameField
                kindPicker
                if isRemote { urlField } else { commandFields }
                assistantList
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
        .onAppear {
            // Every assistant starts ticked — "everywhere" is the common case this sheet exists
            // for — and unticking is one press for whoever should not have it.
            chosen = Set(assistants.map(\.id))
            focus = .name
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Add MCP server")
                .font(.system(size: 16, weight: .semibold))
                .tracking(-0.2)
            Text("Written into each assistant you tick, in its own format")
                .font(.system(size: 12.5))
                .foregroundStyle(Color.white.opacity(0.45))
        }
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Name").font(.system(size: 11.5, weight: .medium)).foregroundStyle(V2.textMid)
            TextField("codegraph", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(V2.well, in: RoundedRectangle(cornerRadius: 6))
                .focused($focus, equals: .name)
                .onSubmit { focus = isRemote ? .url : .command }
        }
    }

    private var kindPicker: some View {
        HStack(spacing: 6) {
            kindButton("Local command", remote: false)
            kindButton("Remote URL", remote: true)
        }
    }

    private func kindButton(_ label: String, remote: Bool) -> some View {
        Button { isRemote = remote } label: {
            Text(label)
                .font(.system(size: 11.5, weight: isRemote == remote ? .semibold : .regular))
                .foregroundStyle(isRemote == remote ? V2.text : V2.textDim)
                .padding(.horizontal, 10)
                .frame(height: 22)
                .background(isRemote == remote ? V2.button : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .pointingHand()
    }

    private var commandFields: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Command").font(.system(size: 11.5, weight: .medium)).foregroundStyle(V2.textMid)
                TextField("npx -y mac-control-mcp", text: $command)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(V2.well, in: RoundedRectangle(cornerRadius: 6))
                    .focused($focus, equals: .command)
                    .onSubmit { create() }
            }
        }
    }

    private var urlField: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("URL").font(.system(size: 11.5, weight: .medium)).foregroundStyle(V2.textMid)
            TextField("https://mcp.example.com/sse", text: $url)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(V2.well, in: RoundedRectangle(cornerRadius: 6))
                .focused($focus, equals: .url)
                .onSubmit { create() }
        }
    }

    /// The whole command in one line — `npx -y thing --flag` — split on spaces here rather than
    /// asking for arguments one text field at a time. A quoted argument keeps its spaces.
    private var argumentList: [String] {
        var pieces: [String] = []
        var current = ""
        var quote: Character?
        for character in command {
            if let active = quote {
                if character == active { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == " " {
                if !current.isEmpty { pieces.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    private var assistantList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Assistants").font(.system(size: 11.5, weight: .medium)).foregroundStyle(V2.textMid)
            FlowAssistants(assistants: assistants, chosen: $chosen)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Cancel") { dismiss() }
                .buttonStyle(SheetButtonStyle(kind: .quiet, enabled: true))
                .keyboardShortcut(.cancelAction)
                .pointingHand()
            Spacer(minLength: 12)
            Button { create() } label: {
                Text("Add to \(chosen.count) \(chosen.count == 1 ? "assistant" : "assistants")")
                    .font(.system(size: 12.5, weight: .semibold))
            }
            .buttonStyle(SheetButtonStyle(kind: .primary, enabled: valid))
            .disabled(!valid)
            .keyboardShortcut(.defaultAction)
            .pointingHand(enabled: valid)
        }
        .padding(.leading, 24)
        .padding(.trailing, 18)
        .padding(.vertical, 13)
        .background(Color.black.opacity(0.20))
        .overlay(alignment: .top) { Hairline(color: V2.hairline) }
    }

    private func create() {
        guard valid else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = argumentList
        model.addMCPServer(
            name: trimmedName,
            command: pieces.first ?? "",
            args: Array(pieces.dropFirst()),
            url: isRemote ? url : nil,
            to: chosen.sorted()
        )
        dismiss()
    }
}

/// The assistant checkboxes as a wrapping row: marks with names, ticked squares, one tap each.
/// Too few for a list, too many for a picker — seven assistants in a 520pt sheet wrap to two rows.
private struct FlowAssistants: View {
    let assistants: [Assistant]
    @Binding var chosen: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 14) {
                    ForEach(row) { assistant in one(assistant) }
                }
            }
        }
    }

    /// Three to a row: seven marks with names need the width, and three keeps the two rows even.
    private var rows: [[Assistant]] {
        stride(from: 0, to: assistants.count, by: 3).map {
            Array(assistants[$0..<min($0 + 3, assistants.count)])
        }
    }

    private func one(_ assistant: Assistant) -> some View {
        Button {
            if chosen.contains(assistant.id) { chosen.remove(assistant.id) }
            else { chosen.insert(assistant.id) }
        } label: {
            HStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(chosen.contains(assistant.id) ? V2.accent : V2.hairline,
                                      lineWidth: 1.2)
                        .background(RoundedRectangle(cornerRadius: 4)
                            .fill(chosen.contains(assistant.id) ? V2.accent : Color.clear))
                    if chosen.contains(assistant.id) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color.white)
                    }
                }
                .frame(width: 14, height: 14)
                AssistantMark(assistant: assistant, present: true, size: 15)
                Text(assistant.label)
                    .font(.system(size: 12))
                    .foregroundStyle(V2.text)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .pointingHand()
        .frame(maxWidth: 160, alignment: .leading)
    }
}
