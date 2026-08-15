import SwiftUI
import LoadoutCore

/// The conversation, in a column beside the document.
///
/// A column rather than a sheet on purpose: the whole point of accepting a change block by block is
/// reading the proposal and the file at the same time, which a sheet over the window makes
/// impossible. Nothing here writes: accepting a block edits the draft, and Save stays Miguel's.
struct AskPanel: View {
    @Bindable var model: AppModel
    @State private var historyOpen = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(V2.hairline)
            conversation
            // The document's own changes are decided in the document, where they can be read at
            // the width of the pane. What stays here are the files beside it, which have no editor
            // of their own — plus a line saying the document has changes waiting.
            if !sideProposals.isEmpty || documentPending > 0 {
                Divider().overlay(V2.hairline)
                proposalsArea
            }
            Divider().overlay(V2.hairline)
            composer
        }
        .background(V2.window)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 11))
                .foregroundStyle(V2.link)
            Text(model.ask.cli?.label ?? "Ask")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(V2.text)
            // A bare spinner at this size is almost invisible against the bar, so it says what it
            // is doing in words beside it.
            if model.ask.isRunning {
                ProgressView().controlSize(.small).scaleEffect(0.65)
                Text("Working…")
                    .font(.system(size: 11))
                    .foregroundStyle(V2.link)
            }
            Spacer(minLength: 6)
            Button("History") { historyOpen.toggle() }
                .buttonStyle(V2ToolbarButtonStyle(prominent: false, enabled: !model.ask.history.isEmpty))
                .disabled(model.ask.history.isEmpty)
                .help("The earlier conversations about this skill")
                .pointingHand()
                .popover(isPresented: $historyOpen, arrowEdge: .bottom) { historyList }
            Button("New") { model.ask.startNewConversation() }
                .buttonStyle(V2ToolbarButtonStyle(prominent: false, enabled: !model.ask.entries.isEmpty))
                .disabled(model.ask.entries.isEmpty)
                .help("Start a fresh conversation. This one is kept, under History.")
                .pointingHand()
            Button("Close") { model.showsAskPanel = false }
                .buttonStyle(V2ToolbarButtonStyle(prominent: false, enabled: true))
                .help("Hide the conversation. It is kept, and reopens where you left it.")
                .pointingHand()
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
    }

    /// The earlier conversations about this skill. Ids, read back from the assistant's own record —
    /// so this list can only ever offer what the assistant can still resume.
    private var historyList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Conversations about this skill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(V2.textMid)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.ask.history) { conversation in
                        Button {
                            model.ask.resume(conversation)
                            historyOpen = false
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(conversation.title)
                                        .font(.system(size: 12))
                                        .foregroundStyle(V2.text)
                                        .lineLimit(1)
                                    if conversation.id == model.ask.sessionID {
                                        Text("open")
                                            .font(.system(size: 9.5))
                                            .foregroundStyle(V2.link)
                                    }
                                }
                                Text(conversation.startedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.system(size: 10))
                                    .foregroundStyle(V2.textFaint)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                        }
                        .buttonStyle(.plain)
                        .background(
                            conversation.id == model.ask.sessionID ? V2.buttonHover : Color.clear
                        )
                        .pointingHand()
                    }
                }
            }
            .frame(maxHeight: 260)
        }
        .frame(width: 320)
        .padding(.bottom, 6)
    }

    // MARK: - Conversation

    private var conversation: some View {
        ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if model.ask.entries.isEmpty {
                        Text(emptyText)
                            .font(.system(size: 12))
                            .foregroundStyle(V2.textDim)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                    }
                    ForEach(model.ask.entries) { entry in
                        AskEntryRow(entry: entry).id(entry.id)
                    }
                    // While it is working and hasn't said anything yet, something has to move —
                    // otherwise a run that takes half a minute looks like a panel that broke.
                    if model.ask.isRunning {
                        AskTypingDots()
                    }
                    // An anchor to keep the newest line in view as the answer is written.
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .padding(12)
            }
            .onChange(of: model.ask.entries.last?.text) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    scroller.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private static let bottomAnchor = "ask-bottom"

    private var emptyText: String {
        let name = model.ask.cli?.label ?? "the assistant"
        return """
            Ask \(name) to change this skill. It works in a copy of the folder, so nothing here \
            reaches your file until you accept a change and save.
            """
    }

    // MARK: - Proposals

    /// Everything the assistant touched except the document on screen. That one is decided in the
    /// editor, at the width of the pane, which is the only place a long change is readable.
    private var sideProposals: [AskModel.Proposal] {
        model.ask.proposals.filter { $0.id != AskModel.documentName }
    }

    private var documentPending: Int {
        model.ask.proposals.first { $0.id == AskModel.documentName }?.pending.count ?? 0
    }

    private var proposalsArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            if documentPending > 0 {
                Label(
                    documentPending == 1
                        ? "1 change waiting in the document, on the left"
                        : "\(documentPending) changes waiting in the document, on the left",
                    systemImage: "arrow.left"
                )
                .font(.system(size: 10.5))
                .foregroundStyle(V2.link)
            }

            if !sideProposals.isEmpty {
                Text(sideProposals.count == 1
                     ? "1 file beside the document"
                     : "\(sideProposals.count) files beside the document")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(V2.text)

                if sideProposals.count > 1 {
                    HStack(spacing: 4) {
                        ForEach(sideProposals) { proposal in
                            Button {
                                model.ask.focusedProposalID = proposal.id
                            } label: {
                                HStack(spacing: 4) {
                                    Text(proposal.id)
                                    if !proposal.pending.isEmpty {
                                        Text("\(proposal.pending.count)")
                                            .font(.system(size: 9.5))
                                            .foregroundStyle(V2.amber)
                                    }
                                }
                                .font(.system(size: 11))
                            }
                            .buttonStyle(
                                V2ToolbarButtonStyle(
                                    prominent: proposal.id == model.ask.focusedProposalID, enabled: true
                                )
                            )
                            .pointingHand()
                        }
                    }
                }

                if let focused = sideProposals.first(where: { $0.id == model.ask.focusedProposalID })
                    ?? sideProposals.first {
                    Label(
                        focused.isNew
                            ? "\(focused.id) is new. It is written when you save."
                            : "\(focused.id) is written when you save, with a backup first.",
                        systemImage: focused.isNew ? "doc.badge.plus" : "doc.text"
                    )
                    .font(.system(size: 10.5))
                    .foregroundStyle(V2.textDim)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(focused.blocks) { block in
                                AskBlockCard(
                                    block: block,
                                    state: state(of: block, in: focused),
                                    accept: { model.ask.accept(blockID: block.id, in: focused.id) },
                                    reject: { model.ask.reject(blockID: block.id, in: focused.id) }
                                )
                            }
                        }
                    }
                    .frame(maxHeight: 260)

                    if !focused.pending.isEmpty {
                        HStack(spacing: 6) {
                            Button("Accept all") { model.ask.acceptAll(in: focused.id) }
                                .buttonStyle(V2ToolbarButtonStyle(prominent: true, enabled: true))
                                .pointingHand()
                            Button("Reject all") { model.ask.rejectAll(in: focused.id) }
                                .buttonStyle(V2ToolbarButtonStyle(prominent: false, enabled: true))
                                .pointingHand()
                        }
                    }
                }
            }
        }
        .padding(12)
    }

    private func state(of block: DiffBlock, in proposal: AskModel.Proposal) -> AskBlockCard.State {
        if proposal.accepted.contains(block.id) { return .accepted }
        if proposal.rejected.contains(block.id) { return .rejected }
        return .pending
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: Binding(
                get: { model.ask.draftMessage },
                set: { model.ask.draftMessage = $0 }
            ))
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .frame(height: 60)
                .padding(6)
                .background(V2.well, in: RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 6) {
                Text(hint)
                    .font(.system(size: 10.5))
                    .foregroundStyle(V2.textFaint)
                    .lineLimit(2)
                Spacer(minLength: 6)
                if model.ask.isRunning {
                    Button("Stop") { model.ask.stop() }
                        .buttonStyle(V2ToolbarButtonStyle(prominent: false, enabled: true))
                        .help("Kill the assistant's process now")
                        .pointingHand()
                } else {
                    // The shortcut is written on the button because ⌘↵ is not guessable, and
                    // Return can't be it — Return belongs to the message box, for a new line.
                    Button {
                        model.sendAskMessage()
                    } label: {
                        HStack(spacing: 6) {
                            Text("Send")
                            Text("⌘↵")
                                .font(.system(size: 11))
                                .opacity(0.6)
                        }
                    }
                        .buttonStyle(
                            V2ToolbarButtonStyle(
                                prominent: true,
                                enabled: !model.ask.draftMessage
                                    .trimmingCharacters(in: .whitespaces).isEmpty
                            )
                        )
                        .disabled(model.ask.draftMessage.trimmingCharacters(in: .whitespaces).isEmpty)
                        .keyboardShortcut(.return, modifiers: .command)
                        .help("Send this message (⌘↵)")
                        .pointingHand()
                }
            }
        }
        .padding(12)
    }

    private var hint: String {
        guard let cli = model.ask.cli else { return "" }
        if cli.chat?.resumeTemplate == nil {
            return "\(cli.label) starts fresh each message — it can't pick a conversation back up."
        }
        return "Runs in a copy of the folder. Your file changes only when you accept and save."
    }
}

/// Three dots that rise in turn while the assistant is working.
///
/// The spinner in the header says *something* is happening; this says it is happening *here*, at the
/// bottom of the conversation, which is where the next words will appear.
private struct AskTypingDots: View {
    @State private var phase = 0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(V2.textDim)
                    .frame(width: 5, height: 5)
                    .offset(y: phase == index ? -2.5 : 0)
                    .opacity(phase == index ? 1 : 0.45)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .task {
            // A timer rather than a repeating animation: this view comes and goes with the run, and
            // an animation left running on a removed view keeps a redraw going forever.
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(260))
                withAnimation(.easeInOut(duration: 0.22)) { phase = (phase + 1) % 3 }
            }
        }
        .accessibilityLabel("Working")
    }
}

/// One line of the conversation. The kinds look different on purpose: what the assistant *said* has
/// to be impossible to confuse with what it was *thinking* or what it *ran*.
private struct AskEntryRow: View {
    let entry: AskModel.Entry

    var body: some View {
        switch entry.kind {
        case .you:
            VStack(alignment: .leading, spacing: 3) {
                Text("You")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(V2.textDim)
                Text(entry.text)
                    .font(.system(size: 12))
                    .foregroundStyle(V2.text)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(V2.well, in: RoundedRectangle(cornerRadius: 8))

        case .assistant:
            Text(entry.text)
                .font(.system(size: 12.5))
                .foregroundStyle(V2.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .reasoning:
            Text(entry.text)
                .font(.system(size: 11).italic())
                .foregroundStyle(V2.textFaint)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .activity(let tool):
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: icon(for: tool))
                    .font(.system(size: 9))
                    .foregroundStyle(V2.textDim)
                    .frame(width: 12)
                Text(entry.text.isEmpty ? tool : entry.text)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(V2.textDim)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .notice:
            Text(entry.text)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(V2.textFaint)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .failure:
            Label(entry.text, systemImage: "exclamationmark.triangle")
                .font(.system(size: 11))
                .foregroundStyle(V2.amber)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func icon(for tool: String) -> String {
        switch tool {
        case "Edit", "Write", "MultiEdit", "edit", "write": return "pencil"
        case "Bash", "Shell": return "terminal"
        case "Read", "read": return "doc.text"
        default: return "wrench.and.screwdriver"
        }
    }
}

/// One change, with the old lines above the new ones and a decision to make about it.
private struct AskBlockCard: View {
    enum State { case pending, accepted, rejected }

    let block: DiffBlock
    let state: State
    let accept: () -> Void
    let reject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Line \(block.start + 1)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(V2.textDim)
                Text(block.summary)
                    .font(.system(size: 10))
                    .foregroundStyle(V2.textFaint)
                Spacer(minLength: 4)
                switch state {
                case .pending:
                    Button("Reject", action: reject)
                        .buttonStyle(V2ToolbarButtonStyle(prominent: false, enabled: true))
                        .pointingHand()
                    Button("Accept", action: accept)
                        .buttonStyle(V2ToolbarButtonStyle(prominent: true, enabled: true))
                        .pointingHand()
                case .accepted:
                    Button("Undo", action: reject)
                        .buttonStyle(V2ToolbarButtonStyle(prominent: false, enabled: true))
                        .pointingHand()
                    Label("Accepted", systemImage: "checkmark")
                        .font(.system(size: 10))
                        .foregroundStyle(V2.ok)
                case .rejected:
                    Button("Accept", action: accept)
                        .buttonStyle(V2ToolbarButtonStyle(prominent: false, enabled: true))
                        .pointingHand()
                    Text("Rejected")
                        .font(.system(size: 10))
                        .foregroundStyle(V2.textFaint)
                }
            }

            ForEach(Array(block.removedText.enumerated()), id: \.offset) { _, line in
                diffLine(line, added: false)
            }
            ForEach(Array(block.addedText.enumerated()), id: \.offset) { _, line in
                diffLine(line, added: true)
            }
        }
        .padding(8)
        .background(background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(state == .pending ? V2.hairline : Color.clear, lineWidth: 0.5)
        )
        .opacity(state == .rejected ? 0.5 : 1)
    }

    private var background: Color {
        switch state {
        case .pending: return V2.well
        case .accepted: return V2.ok.opacity(0.10)
        case .rejected: return V2.well.opacity(0.5)
        }
    }

    private func diffLine(_ line: String, added: Bool) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(added ? "+" : "−")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(added ? V2.ok : V2.issue)
            Text(line.isEmpty ? " " : line)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(added ? V2.text : V2.textMid)
                .strikethrough(!added, color: V2.textFaint)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
