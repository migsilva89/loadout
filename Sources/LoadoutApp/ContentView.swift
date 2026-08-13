import SwiftUI
import AppKit
import LoadoutCore

struct ContentView: View {
    @Bindable var model: AppModel
    @AppStorage("sidebarVisible") private var sidebarVisible = true
    /// The sidebar's width, draggable at the divider and remembered between launches.
    @AppStorage("sidebarWidth") private var sidebarWidth = 372.0
    @State private var dragBaseWidth: CGFloat?

    var body: some View {
        VStack(spacing: 0) {
            TitleBar(model: model, sidebarVisible: $sidebarVisible)
            Hairline(color: Color.black.opacity(0.6))
            HStack(spacing: 0) {
                if sidebarVisible {
                    SidebarView(model: model)
                        .frame(width: sidebarWidth)
                        .transition(.move(edge: .leading))
                    sidebarResizeHandle
                }
                DetailView(model: model)
                    .frame(maxWidth: .infinity)
            }
            .animation(.easeOut(duration: 0.18), value: sidebarVisible)
        }
        // The custom bar owns the very top of the window, traffic lights included.
        .ignoresSafeArea(.container, edges: .top)
        .background(V2.window)
        // The design is one deliberate dark theme, not a pair — the palette in Theme.swift
        // is authored against these exact surfaces, so the window opts out of following the
        // system appearance.
        .preferredColorScheme(.dark)
        .background(WindowPlacement())

        .sheet(isPresented: $model.isCreating) { NewSkillSheet(model: model) }
        .sheet(item: $model.askCLI) { cli in CopilotSheet(model: model, cli: cli) }
        .sheet(isPresented: $model.isAddingAssistantCLI) { AssistantCLIFormSheet(model: model, editing: nil) }
        .sheet(item: $model.editingCustomAssistantCLI) { entry in AssistantCLIFormSheet(model: model, editing: entry) }
        .alert("Move \(model.selected?.name ?? "") to the Trash?", isPresented: $model.isConfirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Trash", role: .destructive) { model.deleteSelected() }
        } message: {
            Text("The folder moves to the Trash, and a copy stays in the Loadout backups.")
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
    }

    /// The hairline between the columns, with an 8pt invisible grab area over it: drag to
    /// resize the sidebar, clamped so neither column can be crushed.
    private var sidebarResizeHandle: some View {
        Hairline(vertical: true)
            .overlay {
                Color.clear
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let base = dragBaseWidth ?? sidebarWidth
                                dragBaseWidth = base
                                sidebarWidth = min(560, max(320, base + value.translation.width))
                            }
                            .onEnded { _ in dragBaseWidth = nil }
                    )
            }
    }
}

// MARK: - Title bar

/// The design's own 52pt title bar, in the three zones a Mac toolbar balances: the system's
/// traffic lights and the sidebar toggle at the left, the kind tabs at the optical centre of
/// the whole window — a ZStack, so they centre on the window and not on whatever the side
/// zones leave over — and the actions at the right.
struct TitleBar: View {
    @Bindable var model: AppModel
    @Binding var sidebarVisible: Bool

    var body: some View {
        ZStack {
            KindTabs(model: model)
            HStack(spacing: 12) {
                // The traffic lights render themselves over this leading inset.
                Spacer().frame(width: 68)
                sidebarToggle
                Spacer()
                newSkillButton
            }
            .padding(.horizontal, 14)
        }
        .frame(height: 52)
        .frame(maxWidth: .infinity)
        .background(Color(red: 0.173, green: 0.173, blue: 0.180))   // #2C2C2E
        .overlay(alignment: .top) { Hairline(color: Color.white.opacity(0.06)) }
        // With the system title bar hidden, this strip is what the hand expects to grab.
        .gesture(WindowDragGesture())
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
    /// with the label. Blue stays reserved for selection.
    private var newSkillButton: some View {
        Button {
            model.isCreating = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                Text("New skill")
                    .font(.system(size: 12.5))
            }
            .foregroundStyle(Color.white.opacity(0.88))
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(V2.button, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help("Create a new personal skill (⌘N)")
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
    }
}
