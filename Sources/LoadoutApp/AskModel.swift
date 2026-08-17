import Foundation
import Observation
import LoadoutCore

/// The conversation beside the editor: what has been said, what the assistant changed, and which
/// of those changes are still waiting for a decision.
///
/// One conversation per skill, kept as the CLI's own session id rather than a transcript of our
/// own, so closing the app and coming back tomorrow resumes the same exchange. The assistant works
/// in a disposable copy of the folder; nothing reaches Miguel's file until he accepts a block and
/// saves, through the ordinary write path with its mandatory backup.
@MainActor
@Observable
final class AskModel {
    /// One line of the conversation as the panel shows it.
    struct Entry: Identifiable {
        enum Kind {
            case you
            case assistant
            /// Thinking out loud — shown dimmed, never mistaken for the answer.
            case reasoning
            /// Something the assistant ran or read.
            case activity(tool: String)
            /// A line the CLI printed that wasn't part of its conversation: a warning, a banner,
            /// a request to sign in. Shown, because a stuck assistant has to be able to say so.
            case notice
            case failure
        }

        let id = UUID()
        var kind: Kind
        var text: String
    }

    /// A file the assistant changed in the copy, with each change offered on its own.
    struct Proposal: Identifiable {
        /// Path relative to the skill folder — `SKILL.md`, `scripts/run.sh`.
        let id: String
        let original: String
        let modified: String
        let isNew: Bool
        var blocks: [DiffBlock]
        /// What has been decided, remembered against each change's own signature rather than its
        /// number in this round. That is what makes a second edit to a line he had already accepted
        /// come back for a new decision, instead of the panel showing "Accepted" over text he has
        /// never seen and the draft quietly holding the older version.
        var decisions: [String: Bool] = [:]

        var accepted: Set<Int> {
            Set(blocks.filter { decisions[$0.signature] == true }.map(\.id))
        }
        var rejected: Set<Int> {
            Set(blocks.filter { decisions[$0.signature] == false }.map(\.id))
        }
        var pending: [DiffBlock] { blocks.filter { decisions[$0.signature] == nil } }

        /// The file as it would be with the accepted blocks in it and nothing else.
        var resolvedText: String { DiffBlocks.apply(blocks, accepting: accepted, to: original) }
    }

    // MARK: - State

    /// Which skill this conversation belongs to. Switching skills switches conversation.
    private(set) var itemID: String?
    private(set) var entries: [Entry] = []
    private(set) var proposals: [Proposal] = []
    /// Which changed file the panel is showing the blocks of.
    var focusedProposalID: String?
    private(set) var isRunning = false
    /// The CLI this conversation is with. Changing it starts a new conversation, since a session id
    /// means nothing to a different assistant.
    private(set) var cli: AssistantCLI?
    var draftMessage = ""

    /// Which model this assistant is being asked for, or `nil` to let the CLI use its own default.
    ///
    /// Remembered per assistant rather than once for the panel: "opus" means something to `claude`
    /// and nothing to `codex`, so one shared setting would send each of them the other's vocabulary.
    /// Read back whenever the assistant changes, which is also when the answer changes.
    var chosenModel: String? {
        didSet {
            guard let cli, chosenModel != oldValue else { return }
            let key = AssistantModels.defaultsKey(assistantID: cli.id)
            let trimmed = chosenModel?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty {
                UserDefaults.standard.set(trimmed, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    /// The model remembered for an assistant, if one was ever chosen.
    private static func rememberedModel(for cli: AssistantCLI) -> String? {
        UserDefaults.standard.string(forKey: AssistantModels.defaultsKey(assistantID: cli.id))
    }

    private let runner = ChatRunner()
    private let workspaces: AskWorkspaces
    private let transcripts: URL
    private var workspace: AskWorkspace?

    /// Every conversation Loadout remembers, across skills — ids only, since the assistant keeps the
    /// exchanges themselves. Opening a skill picks up its most recent one; History offers the rest.
    private(set) var conversations: [AskConversation] {
        didSet { AskConversationStore.save(conversations) }
    }

    /// The conversation the panel is on. `nil` means the next message starts a new one.
    private(set) var sessionID: String?

    /// The past conversations about the skill on screen, newest first, the current one included.
    var history: [AskConversation] {
        guard let itemID, let cli, let origin else { return [] }
        return AskConversationStore.matching(
            itemID: itemID, cliID: cli.id, origin: origin, in: conversations
        )
    }

    /// Called when accepting a block should change the document on screen. Set by `AppModel`,
    /// which owns the draft — there is one source of truth for the text, and it is not here.
    var applyToDraft: ((String) -> Void)?
    var report: ((String) -> Void)?
    /// Told whenever the set of proposed changes is rebuilt, with whether any of them are still
    /// undecided — `AppModel` uses it to put the pane into editing, where a change can be shown.
    var onProposals: ((Bool) -> Void)?

    init(paths: Paths) {
        self.workspaces = AskWorkspaces(paths: paths)
        self.transcripts = paths.transcripts
        self.conversations = AskConversationStore.load()
    }

    /// Files the conversation away under the id the assistant just announced, so History can offer
    /// it later and the next message can carry on from it.
    private func remember(sessionID id: String) {
        self.sessionID = id
        guard let itemID, let cli, let origin else { return }
        let existing = conversations.first { $0.id == id }
        conversations = AskConversationStore.upsert(
            AskConversation(
                id: id,
                itemID: itemID,
                cliID: cli.id,
                originPath: origin.standardizedFileURL.path,
                // Kept from the first time it was seen, so a conversation carried on next week
                // still shows the day it started.
                startedAt: existing?.startedAt ?? Date(),
                title: existing?.title ?? firstAsked
            ),
            into: conversations
        )
    }

    /// What was asked first, which is how a conversation is recognised in a list.
    private var firstAsked: String {
        let text = entries.first { if case .you = $0.kind { return true } else { return false } }?.text
        return (text ?? "Untitled").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True while any change anywhere is undecided — what stops a working copy being deleted.
    var hasPendingBlocks: Bool { proposals.contains { !$0.pending.isEmpty } }

    var pendingCount: Int { proposals.reduce(0) { $0 + $1.pending.count } }

    /// Whether this assistant can hold a conversation at all. A custom CLI from Settings can't:
    /// Loadout doesn't know its flags, so it keeps the one-shot Ask.
    static func canChat(_ cli: AssistantCLI) -> Bool { cli.chat != nil }

    // MARK: - Opening

    /// Points the panel at a skill. Reopening a skill with a saved conversation reads its history
    /// back from the CLI's own record rather than from anything Loadout kept.
    func open(itemID: String, cli: AssistantCLI, origin: URL) {
        guard self.itemID != itemID || self.cli?.id != cli.id else { return }
        runner.cancel()
        self.itemID = itemID
        self.cli = cli
        self.origin = origin
        // Set straight rather than through the property's own setter, which would write back the
        // value it has just read.
        _chosenModel = Self.rememberedModel(for: cli)
        entries = []
        proposals = []
        focusedProposalID = nil
        isRunning = false
        sessionID = nil
        // The most recent conversation about this skill with this assistant, picked up where it was
        // left. The others are a click away under History.
        if let latest = AskConversationStore.matching(
            itemID: itemID, cliID: cli.id, origin: origin, in: conversations
        ).first {
            resume(latest)
        }
    }

    /// Opens one of the past conversations: its messages come back and the next message continues it.
    ///
    /// The working copy is remade from the folder as it is now, so an old conversation resumed today
    /// proposes changes against today's file rather than against the file as it was then.
    func resume(_ conversation: AskConversation) {
        guard !hasPendingBlocks else {
            report?("There are changes waiting for you to accept or reject. Decide those first.")
            return
        }
        runner.cancel()
        sessionID = conversation.id
        entries = ChatTranscript.messages(sessionID: conversation.id, transcripts: transcripts).map {
            Entry(kind: $0.speaker == .you ? .you : .assistant, text: $0.text)
        }
        if entries.isEmpty {
            // The CLI has pruned it. Say so rather than showing an empty panel that looks broken.
            entries = [Entry(
                kind: .notice,
                text: "\(conversation.cliID) no longer has this conversation's messages. Carrying on from it still works."
            )]
        }
        proposals = []
        focusedProposalID = nil
        if let itemID { try? workspaces.remove(itemID: itemID, hasPendingBlocks: false) }
        workspace = nil
    }

    /// The folder this conversation is about, as it was when the panel opened.
    private(set) var origin: URL?

    /// Forgets the conversation and its working copy, and starts cold. Refuses while a change is
    /// undecided, rather than silently throwing that change away.
    func startNewConversation() {
        // The assistant is not needed here any more: the conversation being left behind is kept
        // under History rather than deleted, so there is nothing to look up by assistant.
        guard let itemID else { return }
        guard !hasPendingBlocks else {
            report?("There are changes waiting for you to accept or reject. Decide those first.")
            return
        }
        runner.cancel()
        // The old one is kept, not thrown away — it is what History offers. Only the panel forgets it.
        sessionID = nil
        try? workspaces.remove(itemID: itemID, hasPendingBlocks: false)
        workspace = nil
        entries = []
        proposals = []
        focusedProposalID = nil
    }

    /// Hands the panel a working copy that was made for it, for `--self-check` to exercise the part
    /// Loadout owns — finding the changes, deciding them, writing them — without running a CLI.
    func adoptWorkspaceForChecking(_ workspace: AskWorkspace) {
        self.workspace = workspace
    }

    /// Called at launch: the copies belong to the conversations, so the ones whose conversation is
    /// gone are swept. Nothing else in the app remembers these folders exist.
    func removeOrphanWorkspaces() {
        workspaces.removeOrphans(keeping: Set(conversations.map(\.itemID)))
    }

    // MARK: - Talking

    /// What the assistant is told about where it is, set by `AppModel` from the selected item. An
    /// assistant that isn't told is one that has to guess, and it guessed.
    var briefing: String?

    /// Sends the typed message, streaming the reply in as it arrives.
    func send(origin: URL) {
        self.origin = origin
        let message = draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !isRunning, let itemID, let cli, let chat = cli.chat else { return }

        let workspace: AskWorkspace
        do {
            workspace = try workspaces.open(itemID: itemID, origin: origin)
        } catch {
            entries.append(Entry(kind: .failure, text: describe(error)))
            return
        }
        self.workspace = workspace

        entries.append(Entry(kind: .you, text: message))
        draftMessage = ""
        isRunning = true
        let session = sessionID
        let briefing = self.briefing
        let runner = self.runner
        let model = chosenModel

        // The child process is read on a background queue and its events hop back here one at a
        // time, because everything they touch — the entries, the pending blocks — is the window's.
        Task.detached(priority: .userInitiated) {
            runner.send(
                cli: cli, chat: chat, prompt: message, resuming: session, briefing: briefing,
                model: model, in: workspace.root
            ) { event in
                Task { @MainActor in self.receive(event) }
            }
        }
    }

    func stop() {
        runner.cancel()
    }

    private func receive(_ event: ChatEvent) {
        switch event {
        case .session(let id):
            remember(sessionID: id)
        case .text(let text):
            // Prose arrives in pieces; growing the last entry rather than adding one per piece is
            // what makes it read as an answer being written instead of a list of fragments.
            append(text, to: .assistant)
        case .reasoning(let text):
            append(text, to: .reasoning)
        case .activity(let tool, let detail):
            entries.append(Entry(kind: .activity(tool: tool), text: detail))
        case .edited(let path, _, _):
            let name = (path as NSString).lastPathComponent
            entries.append(Entry(kind: .activity(tool: "Edit"), text: name.isEmpty ? path : name))
        case .unparsed(let line):
            entries.append(Entry(kind: .notice, text: line))
        case .finished(let error):
            isRunning = false
            if let error { entries.append(Entry(kind: .failure, text: error)) }
            refreshProposals()
        }
    }

    private func append(_ text: String, to kind: Entry.Kind) {
        if let last = entries.indices.last, matches(entries[last].kind, kind) {
            entries[last].text += text
        } else {
            entries.append(Entry(kind: kind, text: text))
        }
    }

    private func matches(_ lhs: Entry.Kind, _ rhs: Entry.Kind) -> Bool {
        switch (lhs, rhs) {
        case (.assistant, .assistant), (.reasoning, .reasoning): return true
        default: return false
        }
    }

    // MARK: - Blocks

    /// Compares the working copy against the real folder and rebuilds the pending blocks. This —
    /// not anything the assistant reported — is what decides what Miguel is offered.
    func refreshProposals() {
        guard let workspace else { return }
        let previous = Dictionary(uniqueKeysWithValues: proposals.map { ($0.id, $0) })
        proposals = workspaces.changes(in: workspace).map { change in
            let blocks = change.blocks
            let old = previous[change.id]
            // A decision carries over only to a change that is still the same change. Anything the
            // assistant has touched again arrives undecided — the alternative is a block sitting
            // there marked Accepted over text nobody has read.
            let signatures = Set(blocks.map(\.signature))
            let carried = (old?.decisions ?? [:]).filter { signatures.contains($0.key) }
            return Proposal(
                id: change.id,
                original: change.original,
                modified: change.modified,
                isNew: change.isNew,
                blocks: blocks,
                decisions: carried
            )
        }
        if focusedProposalID == nil || !proposals.contains(where: { $0.id == focusedProposalID }) {
            // The document on screen first, since that is the one he is usually here for.
            focusedProposalID = proposals.first(where: { $0.id == Self.documentName })?.id ?? proposals.first?.id
        }
        // The draft holds whatever was accepted, so it has to be rewritten from the new blocks: a
        // decision that didn't survive must not leave its text behind in the editor.
        if let document = proposals.first(where: { $0.id == Self.documentName }) {
            push(document)
        }
        onProposals?(hasPendingBlocks)
    }

    func accept(blockID: Int, in proposalID: String) {
        decide(blockID: blockID, in: proposalID, accept: true)
    }

    func reject(blockID: Int, in proposalID: String) {
        decide(blockID: blockID, in: proposalID, accept: false)
    }

    func acceptAll(in proposalID: String) {
        decideAll(in: proposalID, accept: true)
    }

    func rejectAll(in proposalID: String) {
        decideAll(in: proposalID, accept: false)
    }

    private func decideAll(in proposalID: String, accept: Bool) {
        guard let index = proposals.firstIndex(where: { $0.id == proposalID }) else { return }
        for block in proposals[index].pending {
            proposals[index].decisions[block.signature] = accept
        }
        push(proposals[index])
    }

    private func decide(blockID: Int, in proposalID: String, accept: Bool) {
        guard let index = proposals.firstIndex(where: { $0.id == proposalID }),
              let block = proposals[index].blocks.first(where: { $0.id == blockID })
        else { return }
        proposals[index].decisions[block.signature] = accept
        push(proposals[index])
    }

    /// Takes a decision back, so the change is pending again.
    func undecide(blockID: Int, in proposalID: String) {
        guard let index = proposals.firstIndex(where: { $0.id == proposalID }),
              let block = proposals[index].blocks.first(where: { $0.id == blockID })
        else { return }
        proposals[index].decisions[block.signature] = nil
        push(proposals[index])
    }

    /// A decision on the document being edited changes the draft, so the editor's gutter lights up
    /// and Save becomes available — his gesture, as before. Other files in the folder are written
    /// by `AppModel` when he saves them, and are not the draft.
    private func push(_ proposal: Proposal) {
        guard proposal.id == Self.documentName else { return }
        applyToDraft?(proposal.resolvedText)
    }

    /// Files other than the one on screen that have accepted changes waiting to be written.
    var acceptedSideFiles: [Proposal] {
        proposals.filter { $0.id != Self.documentName && !$0.accepted.isEmpty }
    }

    private func describe(_ error: Error) -> String {
        (error as? LoadoutError)?.errorDescription ?? error.localizedDescription
    }

    /// The one file the editor on the left is showing. Everything else the assistant touched is a
    /// file beside it, written on Save rather than edited in the pane.
    static let documentName = "SKILL.md"

}
