import SwiftUI
import AppKit
import LoadoutCore

struct ContentView: View {
    @Bindable var model: AppModel
    @AppStorage("sidebarVisible") private var sidebarVisible = true
    /// The sidebar's width, draggable at the divider and remembered between launches.
    @AppStorage("sidebarWidth") private var sidebarWidth = 372.0
    /// How far the divider has moved in the drag currently in flight.
    ///
    /// `@GestureState` rather than a hand-kept base width: SwiftUI resets it when the gesture ends
    /// *or is cancelled*. A base kept in plain state survives a cancelled drag — the window losing
    /// focus, the view being rebuilt — and the next grab then jumps straight to the stale value.
    @GestureState private var dragTranslation: CGFloat = 0

    /// Read, not owned: the window's body asks which theme is on, which is what makes a switch
    /// in Settings repaint this window on the spot.
    private let themes = ThemeStore.shared

    private static let sidebarRange: ClosedRange<CGFloat> = 320...560
    private static let columnsSpace = "loadout.columns"

    /// What the sidebar is actually drawn at: the saved width plus whatever the drag in flight has
    /// added, held inside the limits.
    ///
    /// A saved width is a preference, not a promise: on a window too narrow to honour it, it yields
    /// rather than pushing the other column off the edge.
    private func sidebarWidth(in available: CGFloat) -> CGFloat {
        clamped(sidebarWidth + dragTranslation, in: available)
    }

    /// The conversation's share of the window: a third, but never so narrow that a diff line wraps
    /// into noise, and never so wide that the document it is about stops being readable.
    private func askPanelWidth(in available: CGFloat) -> CGFloat {
        min(max(340, available * 0.32), 520)
    }

    private func clamped(_ width: CGFloat, in available: CGFloat) -> CGFloat {
        min(max(Self.sidebarRange.lowerBound, width), ceiling(in: available))
    }

    /// The sidebar may not grow past what the detail pane can spare — the pane's own number, asked
    /// of the pane, rather than a measurement of the pane kept over here.
    private func ceiling(in available: CGFloat) -> CGFloat {
        max(
            Self.sidebarRange.lowerBound,
            min(Self.sidebarRange.upperBound, available - DetailView.minimumWidth)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            TitleBar(model: model, sidebarVisible: $sidebarVisible)
            Hairline(color: Color.black.opacity(0.6))
            // A GeometryReader rather than a measurement of the row itself: it reports the width
            // it was *offered*, which is the window's. Measuring the row gave the width its own
            // overflowing content had already claimed, so the clamp below never fired.
            GeometryReader { proxy in
                let available = proxy.size.width
                HStack(spacing: 0) {
                    if sidebarVisible {
                        SidebarView(model: model)
                            .frame(width: sidebarWidth(in: available))
                            .transition(.move(edge: .leading))
                            // While Settings is up the list is still there — still readable, so
                            // you keep your place — but it is not a list any more. Frosted rather
                            // than hidden, because a pane that vanishes makes people wonder what
                            // else went with it.
                            .frostedPause(model.showsSettings)
                        sidebarResizeHandle(in: available)
                    }
                    // Settings takes the whole of the right, in the place a selected item would
                    // be. It is not a window of its own, so nothing has to be dug out from behind
                    // the app.
                    if model.showsSettings {
                        SettingsPane(model: model)
                            .frame(maxWidth: .infinity)
                            .transition(.opacity)
                    } else if model.selection == .plugins, let plugin = model.selectedPlugin {
                        // The Plugins tab lists plugins, not items, so its detail is the plugin's —
                        // what it ships and which of it is switched on.
                        PluginDetailView(model: model, plugin: plugin)
                            .frame(maxWidth: .infinity)
                    } else {
                        DetailView(model: model)
                            .frame(maxWidth: .infinity)
                    }
                    // Beside the document, never over it: deciding a change block by block means
                    // reading the proposal and the file at the same time.
                    if model.showsAskPanel {
                        Divider().overlay(V2.hairline)
                        AskPanel(model: model)
                            .frame(width: askPanelWidth(in: available))
                            .transition(.move(edge: .trailing))
                    }
                }
                .animation(.easeOut(duration: 0.18), value: sidebarVisible)
                .animation(.easeOut(duration: 0.16), value: model.showsSettings)
                .animation(.easeOut(duration: 0.18), value: model.showsAskPanel)
                // The row is the one thing in here that does not move while the divider is
                // dragged, which is exactly why the drag has to be measured against it.
                .coordinateSpace(.named(Self.columnsSpace))
            }
        }
        // What `spotlight(_:)` measures against, and it belongs on this view: the recorder
        // photographs the window's content, so a rectangle reported in this space is a rectangle
        // in the frame, and a cursor drawn on afterwards lands where the control really was.
        .coordinateSpace(.named(Spotlight.space))
        // The custom bar owns the very top of the window, traffic lights included.
        .ignoresSafeArea(.container, edges: .top)
        .background(V2.window)
        // Five dark themes, none of them the system's — the palettes in Theme.swift are
        // authored against these exact surfaces, so the window opts out of following the
        // system appearance in all of them.
        .preferredColorScheme(.dark)
        .background(WindowPlacement())
        // The desk the window sits on, which is the window's own colour rather than a view's.
        .background(WindowGround())
        // The system's own buttons don't know the bar is 52pt tall; this tells them.
        .background(TrafficLights(barHeight: TitleBar.height))

        .sheet(isPresented: $model.isShowingWelcome) {
            WelcomeSheet(model: model) { model.dismissWelcome() }
        }
        .sheet(isPresented: $model.isCreating) { NewSkillSheet(model: model) }
        .sheet(item: $model.askCLI) { cli in CopilotSheet(model: model, cli: cli) }
        .sheet(isPresented: $model.isAddingAssistantCLI) { AssistantCLIFormSheet(model: model, editing: nil) }
        .sheet(item: $model.editingCustomAssistantCLI) { entry in AssistantCLIFormSheet(model: model, editing: entry) }
        .sheet(item: $model.restoring) { _ in RestoreSkillSheet(model: model) }
        .sheet(item: $model.pendingProjectDisable) { _ in ProjectSkillWarningSheet(model: model) }
        // One alert for both kinds of destruction, not two chained ones. Two `.alert` modifiers on
        // the same view is a thing SwiftUI does not promise: with a third attached here, an empty
        // alert panel presented itself at launch with nobody asking. The question and the
        // consequence still differ — a folder goes to the Trash, a server is lines out of a
        // settings file — so the strings branch and the presentation does not.
        .alert(destructiveTitle, isPresented: $model.isConfirmingDelete) {
            Button("Cancel", role: .cancel) {}
            if model.removesServerOnConfirm {
                Button("Remove", role: .destructive) { model.removeSelectedServer() }
            } else {
                Button("Move to Trash", role: .destructive) { model.deleteSelected() }
            }
        } message: {
            Text(destructiveMessage)
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        // Switching theme is instant because it is a new identity, not a new launch: reading
        // `name` here is what subscribes the window to the choice, and keying the tree on it is
        // what guarantees nothing — a card, a gutter, an `NSTextView` — is left painted in the
        // palette that was in force a moment ago.
        .id(themes.name)
    }

    private var destructiveTitle: String {
        let name = model.selected?.name ?? ""
        return model.removesServerOnConfirm
            ? "Remove \(name) from the assistant's settings?"
            : "Move \(name) to the Trash?"
    }

    private var destructiveMessage: String {
        model.removesServerOnConfirm
            ? """
            This server is a few lines inside the assistant's own settings rather than a file, so \
            there is no Trash to take it back from. Loadout copies that file to its backups first.
            """
            : "The folder moves to the Trash, and a copy stays in the Loadout backups."
    }

    /// The hairline between the columns, with a 12pt invisible grab strip straddling it: drag to
    /// resize the sidebar, clamped so neither column can be crushed.
    ///
    /// Two things make it track the hand. The gesture is measured in the *row's* coordinate space,
    /// not its own — the handle moves as the sidebar resizes, so measuring locally meant the pointer
    /// kept the same local x, the translation stopped growing, and the line stuck and then lurched.
    /// And `minimumDistance: 0`, so it takes hold on press instead of after a point of travel.
    private func sidebarResizeHandle(in available: CGFloat) -> some View {
        Hairline(vertical: true)
            .overlay {
                Color.clear
                    .frame(width: 12)
                    .contentShape(Rectangle())
                    .hoverCursor(.resizeLeftRight)
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.columnsSpace))
                            .updating($dragTranslation) { value, state, _ in
                                state = value.translation.width
                            }
                            // Written once, at the end. Persisting on every frame of the drag put a
                            // UserDefaults write and a view update between the hand and the line.
                            .onEnded { value in
                                sidebarWidth = clamped(
                                    sidebarWidth + value.translation.width, in: available
                                )
                            }
                    )
            }
    }
}

// MARK: - Title bar

/// The design's own 52pt title bar: the system's traffic lights, the sidebar toggle and the kind
/// tabs all packed at the leading edge, and the actions trailing.
///
/// The tabs are *not* centred. They read as navigation — where you are in the inventory — and
/// navigation belongs with the sidebar toggle it works alongside, not floating in the middle of
/// the window away from everything it relates to.
struct TitleBar: View {
    @Bindable var model: AppModel
    @Binding var sidebarVisible: Bool

    /// The bar's height, shared with whatever has to agree with it — the traffic lights, above all.
    static let height: CGFloat = 52

    var body: some View {
        HStack(spacing: 12) {
            leftZone
            KindTabs(model: model)
            Spacer(minLength: 12)
            rightZone
        }
        .padding(.horizontal, 14)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .background(V2.bar)
        .overlay(alignment: .top) { Hairline(color: Color.white.opacity(0.06)) }
        // With the system title bar hidden, this strip is what the hand expects to grab — and to
        // double-click. Simultaneous, because the drag needs movement and this doesn't: a
        // stationary double click reaches the tap without the drag ever claiming it.
        .gesture(WindowDragGesture())
        .simultaneousGesture(TapGesture(count: 2).onEnded { TitleBarDoubleClick.perform() })
    }

    /// Traffic lights, then the sidebar toggle. The lights are nudged to a 20pt inset to balance
    /// the room this bar leaves above them, and they run 58.5pt wide — measured, not assumed — so
    /// they end 78.5pt in. The reserve is 67 past the 14pt padding, which leaves 14.5pt of air on
    /// the toggle's left — matching what is on its right, where the 12pt gap plus the segmented
    /// well's corner radius puts the first ink 14.5pt away. Equal to the eye, which is the only
    /// place it is being judged.
    private var leftZone: some View {
        HStack(spacing: 12) {
            Spacer().frame(width: 67)
            sidebarToggle
        }
    }

    /// One primary action, naming whatever the current tab can make: a skill on Skills, a command
    /// on Commands. A command used to be creatable only by hand in the Finder, which is the one
    /// thing this app exists to spare (AC10.10).
    ///
    /// On a narrow window the button gives up its label and keeps the plus glyph, which with its
    /// tooltip is enough — a control clipped to half a word is not.
    private var rightZone: some View {
        ViewThatFits(in: .horizontal) {
            newSkillButton()
            newSkillButton(compact: true)
        }
    }

    /// What the primary action makes on the tab that is showing. Plugins are installed, not
    /// created here, so that tab keeps the skill wording rather than offering a lie.
    private var newButtonTitle: String {
        switch model.selection {
        case .commands: return "New command"
        case .agents: return "New subagent"
        default: return "New skill"
        }
    }

    private var sidebarToggle: some View {
        Button {
            sidebarVisible.toggle()
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 13))
                .foregroundStyle(Color.white.opacity(sidebarVisible ? 0.85 : 0.45))
                .frame(width: 28, height: 26)
                .background(
                    sidebarVisible ? V2.button : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7)
                )
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help(sidebarVisible ? "Hide the sidebar" : "Show the sidebar")
        .pointingHand()
    }

    /// A Mac toolbar button, not a web one: 26pt, quiet fill and hairline, the plus glyph
    /// with the label. The accent stays reserved for selection.
    private func newSkillButton(compact: Bool = false) -> some View {
        Button {
            model.isCreating = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                if !compact {
                    Text(newButtonTitle)
                        .font(.system(size: 12.5))
                        .fitsOnOneLine()
                }
            }
            .foregroundStyle(Color.white.opacity(0.88))
            .padding(.horizontal, compact ? 7 : 11)
            .frame(height: 26)
            .background(V2.button, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help("\(newButtonTitle) (⌘N)")
        .pointingHand()
    }
}

// MARK: - Kind tabs

/// The five kinds as one segmented control in the title bar — the design's replacement for
/// the old icon bar above the list. The selected segment is a lifted tile; the counts ride
/// along quieter than the names.
struct KindTabs: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 1) {
            ForEach(Selection.allCases, id: \.self) { selection in
                tab(selection)
            }
        }
        .padding(2)
        .background(V2.well, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.black.opacity(0.5), lineWidth: 0.5))
    }

    private func tab(_ selection: Selection) -> some View {
        V2SegmentTab(
            label: selection.title,
            count: model.count(for: selection),
            selected: model.selection == selection
        ) {
            model.selection = selection
        }
        .help(selection.rowHint)
        .spotlight(Spotlight.tab(selection.title))
    }
}
