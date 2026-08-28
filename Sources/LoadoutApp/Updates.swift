import AppKit
import Sparkle

/// The one thing in Loadout that knows about new versions: Sparkle finds the release, checks the
/// signature against the public key baked into the bundle, and replaces the app in place.
///
/// Loadout 0.3.2 shipped a checker of its own that asked GitHub for a version number and opened
/// the release page — it never installed anything, so every update was still a manual drag into
/// Applications. This replaces it outright rather than sitting beside it. Two update mechanisms
/// mean two schedules, two preferences and two answers to "am I current?", and the moment they
/// disagree the app is lying to somebody in at least one of the places they looked.
///
/// Sparkle owns the schedule and the single preference behind it, so the menu item, the Settings
/// pane and the daily background check are three doors into one state.
@MainActor
enum Updates {
    /// `startingUpdater: false` because the updater must not start while the app is still
    /// assembling itself — `start()` below runs it once the preference migration has happened, so
    /// somebody who turned checks off in 0.3.2 is not checked on the way past.
    private static let controller = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    private static var started = false

    /// The running app's version, from the same `CFBundleShortVersionString` the build script
    /// writes out of the git tag. A build run with `swift run` has no bundle and no version, which
    /// is worth saying out loud in the pane rather than showing as a zero.
    nonisolated static var current: String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !raw.isEmpty, raw != "dev"
        else { return nil }
        return raw
    }

    static var automaticallyChecksForUpdates: Bool {
        get {
            start()
            return controller.updater.automaticallyChecksForUpdates
        }
        set {
            start()
            controller.updater.automaticallyChecksForUpdates = newValue
        }
    }

    /// When Sparkle last got an answer, for the pane to show. Nil until the first check lands.
    static var lastCheck: Date? {
        start()
        return controller.updater.lastUpdateCheckDate
    }

    /// Starts the updater, once, and carries the old preference across first.
    ///
    /// The 0.3.2 checker stored its switch under `checksForUpdates`. Somebody who turned that off
    /// asked not to be checked, and letting Sparkle start on its own default would quietly turn it
    /// back on — so the answer is moved into Sparkle's own preference and the dead key removed,
    /// which also means the migration cannot run twice.
    static func start() {
        guard !started else { return }
        started = true
        let defaults = UserDefaults.standard
        if let previous = defaults.object(forKey: "checksForUpdates") as? Bool {
            controller.updater.automaticallyChecksForUpdates = previous
            defaults.removeObject(forKey: "checksForUpdates")
        }
        // Dead keys from the 0.3.2 checker's own bookkeeping. Harmless, but leaving them behind
        // means the next person to read `defaults read com.migsilva.loadout` finds state that
        // nothing writes and nothing reads.
        defaults.removeObject(forKey: "lastAnnouncedUpdate")
        defaults.removeObject(forKey: "lastUpdateCheck")
        controller.startUpdater()
    }

    /// The Loadout menu's "Check for Updates…" and the Settings button, which are the same
    /// question. Sparkle answers either way — including "you're up to date", which is the answer
    /// somebody who pressed the button actually wants.
    static func checkNow() {
        start()
        controller.checkForUpdates(nil)
    }
}
