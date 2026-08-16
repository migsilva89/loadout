import AppKit
import Foundation
import LoadoutCore

/// Tells the owner when a newer Loadout is out — the launch check that speaks only when there is
/// something to say, and the menu item that answers whenever it is asked.
///
/// Two different manners on purpose. The launch check is uninvited, so it stays silent unless
/// there is a new version, and it mentions any one version only once: being told the same thing
/// every morning is how a person learns to dismiss the box without reading it. The menu item was
/// asked a question, so it always answers — including "you are up to date", which is the answer
/// somebody who clicked it actually wants.
@MainActor
enum UpdateNotice {
    /// The last version the launch check mentioned, so it does not mention it again.
    private static let announcedKey = "lastAnnouncedUpdate"

    /// Runs shortly after launch, and only ever opens a window for a version it has not raised
    /// before. Never blocks the launch: it is a detached task, and a failed check says nothing.
    static func checkOnLaunch() {
        Task {
            guard let update = await UpdateCheck.newerRelease() else { return }
            guard UserDefaults.standard.string(forKey: announcedKey) != update.version else { return }
            UserDefaults.standard.set(update.version, forKey: announcedKey)
            present(update)
        }
    }

    /// The Loadout menu's "Check for Updates…", which answers either way.
    static func checkNow() {
        Task {
            guard let running = UpdateCheck.runningVersion() else {
                // A build that was never packaged has no version to compare — say that rather
                // than claim it is current.
                return say(
                    "This build has no version",
                    "Version checks only work on a released build of Loadout, not one run from source.",
                    link: true
                )
            }
            if let update = await UpdateCheck.newerRelease(than: running) {
                UserDefaults.standard.set(update.version, forKey: announcedKey)
                present(update)
            } else {
                say("Loadout \(running) is the latest version", "You're up to date.", link: false)
            }
        }
    }

    /// The one that matters: a new version exists, here is what it is, and here is the way to it.
    private static func present(_ update: UpdateCheck.Available) {
        let alert = NSAlert()
        alert.messageText = "Loadout \(update.version) is available"
        alert.informativeText = "You're running \(UpdateCheck.runningVersion() ?? "an older version"). "
            + "Download the new one and drag it to Applications, replacing this copy."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(update.page)
        }
    }

    private static func say(_ title: String, _ detail: String, link: Bool) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        if link { alert.addButton(withTitle: "Open Releases") }
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(UpdateCheck.releasesPage)
        }
    }
}
