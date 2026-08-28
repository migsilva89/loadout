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
    /// The switch in Settings › Updates. On by default, and read before the request is built, so
    /// off means Loadout makes no network call at all.
    static let automaticKey = "checksForUpdates"
    /// When the launch check last ran. Opening the app ten times in a morning is still one request.
    private static let lastCheckKey = "lastUpdateCheck"

    /// Roughly a day, and short of it on purpose: exactly 24h means somebody who opens Loadout
    /// each morning at the same time never gets a second check.
    private static let interval: TimeInterval = 20 * 60 * 60

    static var checksAutomatically: Bool {
        get { UserDefaults.standard.object(forKey: automaticKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: automaticKey) }
    }

    /// Runs shortly after launch, and only ever opens a window for a version it has not raised
    /// before. Never blocks the launch: it is a detached task, and a failed check says nothing.
    static func checkOnLaunch() {
        guard checksAutomatically else { return }
        let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > interval else { return }
        guard let running = UpdateCheck.runningVersion() else { return }
        Task {
            let outcome = await UpdateCheck.check(against: running)
            // Only an answer starts the clock. A check that never reached GitHub taught nobody
            // anything, so the next launch asks again rather than waiting out the day.
            guard outcome != .unreachable else { return }
            UserDefaults.standard.set(Date(), forKey: lastCheckKey)
            guard case .available(let update) = outcome,
                  UserDefaults.standard.string(forKey: announcedKey) != update.version
            else { return }
            UserDefaults.standard.set(update.version, forKey: announcedKey)
            present(update)
        }
    }

    /// The Loadout menu's "Check for Updates…", which answers either way. Somebody asked, so it
    /// ignores both the once-a-day throttle and the switch: those govern the uninvited check.
    static func checkNow() {
        UserDefaults.standard.set(Date(), forKey: lastCheckKey)
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
            switch await UpdateCheck.check(against: running) {
            case .available(let update):
                UserDefaults.standard.set(update.version, forKey: announcedKey)
                present(update)
            case .upToDate:
                say("Loadout \(running) is the latest version", "You're up to date.", link: false)
            case .unreachable:
                say(
                    "Couldn't check for updates",
                    "GitHub could not be reached. Try again in a moment.",
                    link: false
                )
            }
        }
    }

    /// Settings › Updates asks the same question but shows the answer in the pane instead of a
    /// window, so it records what it found here — otherwise the launch notice would later raise a
    /// version somebody has already been shown.
    static func noteShown(_ version: String) {
        UserDefaults.standard.set(version, forKey: announcedKey)
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
