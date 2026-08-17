import AppKit
import SwiftUI
import LoadoutCore

/// Settings, in the right-hand pane rather than in a window of its own.
///
/// A separate window was the wrong shape for this app. Everything Settings decides is about what
/// is on screen behind it — which projects are listed, which assistants show, how a document reads
/// — and a window floating over the thing it changes has to be moved aside to see whether the
/// change was the one you wanted. Worse, it can end up *behind* the main window, and then the app
/// looks like it ignored the click.
///
/// The first version of this pane shipped with the sections as they were, six toolbar buttons in a
/// row for navigation and no way out at all: its only close button lived in the sidebar footer,
/// and the sidebar is inert while Settings is up. A door locked from the inside. Hence the header
/// that carries its own exit, the rail that admits it is navigation, and the Escape handling
/// below — which is not as simple as it looks.
struct SettingsPane: View {
    @Bindable var model: AppModel

    /// Which section is showing. A view's idea of where you are, not a fact about the machine, so
    /// it lives here rather than in `AppModel`.
    private var section: Section {
        Section(rawValue: model.settingsSection) ?? .projects
    }

    enum Section: String, CaseIterable, Identifiable {
        case projects, appearance, usage, assistants, storage, help

        var id: String { rawValue }

        var title: String {
            switch self {
            case .projects: return "Projects"
            case .appearance: return "Appearance"
            case .usage: return "Usage"
            case .assistants: return "Assistants"
            case .storage: return "Storage"
            case .help: return "Help"
            }
        }

        var symbol: String {
            switch self {
            case .projects: return "folder"
            case .appearance: return "paintpalette"
            case .usage: return "chart.bar"
            case .assistants: return "person.2"
            case .storage: return "internaldrive"
            case .help: return "questionmark.circle"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(V2.hairline)
            HStack(spacing: 0) {
                rail
                Divider().overlay(V2.hairline)
                content
            }
        }
        .background(V2.window)
        .background(SettingsEscape { close() })
    }

    private func close() { model.showsSettings = false }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Text("Settings")
                .font(.system(size: 15, weight: .semibold))
            Rectangle()
                .fill(V2.hairline)
                .frame(width: 1, height: 15)
            Text(section.title)
                .font(.system(size: 13))
                .foregroundStyle(V2.textMid)

            Spacer()

            // Said out loud, because the shortcut for leaving a screen that took over the window
            // is not something anybody should have to guess at.
            HStack(spacing: 4) {
                Text("Press")
                Text("esc")
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.white.opacity(0.07))
                    )
                Text("to close")
            }
            .font(.system(size: 11))
            .foregroundStyle(V2.textFaint)

            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(V2ToolbarButtonStyle(prominent: false, enabled: true))
            .help("Close Settings (Esc)")
            .accessibilityLabel("Close Settings")
            .pointingHand()
        }
        .padding(.horizontal, 16)
        .frame(height: TitleBar.height)
    }

    // MARK: - Rail

    private var rail: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Section.allCases) { entry in
                railRow(entry)
            }
            Spacer(minLength: 0)
            Text(versionLine)
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.28))
                .padding(.horizontal, 7)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 214, alignment: .leading)
    }

    private func railRow(_ entry: Section) -> some View {
        let selected = section == entry
        return Button {
            model.settingsSection = entry.rawValue
        } label: {
            HStack(spacing: 8) {
                Image(systemName: entry.symbol)
                    .font(.system(size: 12))
                    .frame(width: 15)
                Text(entry.title)
                    .font(.system(size: 12.5))
                Spacer(minLength: 4)
                if let count = badge(entry) {
                    Text("\(count)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(selected ? Color.white.opacity(0.75) : V2.textFaint)
                }
            }
            .foregroundStyle(selected ? Color.white : Color.white.opacity(0.68))
            .padding(.horizontal, 7)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? V2.accent : Color.clear)
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointingHand()
    }

    /// Only where a number is a fact worth carrying in the navigation. A count of nothing is not,
    /// so it is absent rather than a zero.
    private func badge(_ entry: Section) -> Int? {
        switch entry {
        case .projects:
            return model.projectRoots.folders.isEmpty ? nil : model.projectRoots.folders.count
        case .assistants:
            return model.assistants.isEmpty ? nil : model.assistants.count
        default:
            return nil
        }
    }

    private var versionLine: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "Loadout \(version ?? "dev")"
    }

    // MARK: - Content

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                switch section {
                case .projects: ProjectsSettings(model: model)
                case .appearance: AppearanceSettings()
                case .usage: UsageTab(model: model)
                case .assistants: AssistantsTab(model: model)
                case .storage: StorageSettings(model: model)
                case .help: HelpTab(model: model)
                }
            }
            .frame(maxWidth: SettingsChrome.columnWidth, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.top, 26)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Escape, caught above the pane.
///
/// `.onExitCommand` only fires when the view that carries it has focus, and this pane has nothing
/// focusable in it — so it silently never fired, which is why the first version had no working
/// exit at all. A local key monitor sees the key press whatever has focus. It is removed when the
/// pane goes away, so nothing keeps swallowing Escape once Settings is closed.
private struct SettingsEscape: NSViewRepresentable {
    let onEscape: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onEscape: onEscape) }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.start()
        return NSView(frame: .zero)
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.onEscape = onEscape
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        var onEscape: () -> Void
        private var monitor: Any?

        init(onEscape: @escaping () -> Void) {
            self.onEscape = onEscape
        }

        func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // 53 is Escape. Compared by code rather than by character so a keyboard layout
                // cannot change what it means.
                guard event.keyCode == 53, let self else { return event }
                // A sheet over the pane owns Escape — cancelling the sheet is what the key means
                // then, and closing Settings underneath it would take the sheet with it.
                //
                // Asking the key window for its `attachedSheet` asked the wrong window: while a
                // sheet is up, the sheet *is* the key window, its own `attachedSheet` is nil, and
                // the guard passed — so Escape over a sheet closed Settings behind it and never
                // reached the sheet. The question is whether the key window is a sheet, or has one.
                let key = NSApp.keyWindow
                guard key?.attachedSheet == nil, key?.isSheet == false else { return event }
                onEscape()
                return nil
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { stop() }
    }
}
