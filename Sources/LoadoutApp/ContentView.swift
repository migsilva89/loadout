import SwiftUI
import AppKit
import LoadoutCore

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 340, ideal: 372, max: 520)
        } detail: {
            DetailView(model: model)
        }
        .background(V2.window)
        // The design is one deliberate dark theme, not a pair — the palette in Theme.swift
        // is authored against these exact surfaces, so the window opts out of following the
        // system appearance.
        .preferredColorScheme(.dark)
        .toolbar {
            // The kind bar lives in the title bar now, as the design draws it: one inset
            // segmented control, name and count per kind, window-level because switching
            // kind changes both columns below it.
            ToolbarItem(placement: .principal) {
                KindTabs(model: model)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.isCreating = true
                } label: {
                    Label("New skill", systemImage: "plus")
                }
                .help("Create a new personal skill (⌘N)")
                .pointingHand()
            }
        }
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
        let isActive = model.selection == selection
        return Button {
            model.selection = selection
        } label: {
            HStack(spacing: 6) {
                Text(selection.title)
                    .font(.system(size: 12.5, weight: isActive ? .medium : .regular))
                    .foregroundStyle(isActive ? Color.white : Color.white.opacity(0.55))
                Text("\(model.count(for: selection))")
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(Color.white.opacity(isActive ? 0.6 : 0.3))
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 4)
            .background(
                isActive ? Color.white.opacity(0.16) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(selection.rowHint)
        .pointingHand()
    }
}
