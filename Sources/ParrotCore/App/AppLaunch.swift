import AppKit
import ApplicationServices
import Foundation

/// Parrot.app, when this process runs from it.
///
/// One executable, two roles: launched by LaunchServices (Finder, `open`,
/// the login item) it is the menu-bar app; run from a terminal, usually
/// through the `/usr/local/bin/parrot` symlink, it is the CLI.
public enum AppBundle {
    /// Parrot's bundle identifier. TCC grants and the login item key to it,
    /// so it never changes (ADR-005). The fork has its own, so it never takes
    /// the grants, the login item or the updates of upstream's app. It must
    /// match `CFBundleIdentifier` in packaging/Info.plist (UpdaterTests).
    static let identifier = "io.github.riturajtiwari.parrot"

    /// The bundle's URL when the main bundle is Parrot.app, else nil (a bare
    /// `swift build` binary).
    static var current: URL? {
        let url = Bundle.main.bundleURL
        guard url.pathExtension == "app", Bundle.main.bundleIdentifier == identifier else { return nil }
        return url
    }

    /// The release version from Info.plist, or "dev" outside the bundle.
    public static var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
    }

    /// Re-executes through the resolved path when this process was started
    /// through a symlink into a bundle. Foundation does not follow the link
    /// when it looks for the main bundle, so without this the CLI would not
    /// find Info.plist and `SMAppService.mainApp` would have no app to
    /// register. Same process, so nothing else changes. Returns if there is
    /// nothing to do or the exec fails.
    public static func resolveSymlinkedLaunch() {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return }
        let invoked = String(cString: buffer)
        guard let real = realpath(invoked, nil) else { return }
        let resolved = String(cString: real)
        free(real)
        guard resolved != invoked, resolved.contains(".app/Contents/MacOS/") else { return }
        // Only when a symlink is involved: realpath of an already-real path
        // that differs only in spelling (./, //) would exec for nothing.
        guard URL(fileURLWithPath: invoked).standardizedFileURL.path != resolved else { return }
        var argv: [UnsafeMutablePointer<CChar>?] = CommandLine.arguments.map { strdup($0) }
        argv.append(nil)
        execv(resolved, &argv)
    }
}

/// Setup that only the app role does: logging to files, the single-instance
/// lock, moving off a pre-app install, and explaining startup failures in a
/// dialog, since there is no terminal to print to.
public enum AppLaunch {
    /// True once `prepare()` ran: this process is the menu-bar app.
    public private(set) static var isApp = false

    /// Whether LaunchServices started this process as the app: inside the
    /// bundle, no subcommand or flags, and stdin not a terminal. Running the
    /// bundled executable from a terminal with no arguments is the CLI's
    /// foreground `run`. `-psn_` is the process serial number older systems
    /// pass to apps launched from Finder.
    static func isAppLaunch(arguments: [String], stdinIsTTY: Bool, inBundle: Bool) -> Bool {
        let args = arguments.dropFirst().filter { !$0.hasPrefix("-psn_") }
        return inBundle && !stdinIsTTY && args.isEmpty
    }

    /// `isAppLaunch` for this process.
    public static var launchedAsApp: Bool {
        isAppLaunch(
            arguments: CommandLine.arguments,
            stdinIsTTY: isatty(STDIN_FILENO) != 0,
            inBundle: AppBundle.current != nil
        )
    }

    /// Runs before the dictation loop when `launchedAsApp`. Exits the process
    /// if another Parrot is already running or the app runs from the DMG.
    @MainActor
    public static func prepare() {
        isApp = true
        redirectOutput()
        Log.info("Parrot \(AppBundle.version) starting")

        guard claimSingleInstance() else {
            // LaunchServices normally activates the running copy instead; this
            // is `open -n` or a login item racing a manual launch.
            Log.info("another Parrot is running; exiting")
            exit(0)
        }

        NSApplication.shared.setActivationPolicy(.accessory)
        guard let bundle = AppBundle.current, let executable = Bundle.main.executableURL else { return }

        if isOnDiskImageOrTranslocated(bundle) {
            _ = alert(
                "Move Parrot to Applications",
                "Parrot is running from the disk image. Drag it to the Applications folder, then open it from there.",
                buttons: ["Quit"]
            )
            exit(0)
        }

        migrateLegacyInstall(executable: executable)
    }

    // MARK: - Single instance

    private static var lockDescriptor: Int32 = -1

    /// Takes the instance lock for this process's lifetime. False if another
    /// Parrot holds it. Idempotent. If the lock file can't be opened, runs
    /// anyway: one extra instance is better than none.
    public static func claimSingleInstance() -> Bool {
        if lockDescriptor >= 0 { return true }
        do {
            try Paths.prepareDirectory(Paths.appSupport)
        } catch {
            Log.warning("couldn't prepare \(Paths.appSupport.path): \(error)")
            return true
        }
        let fd = open(Paths.instanceLock.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            Log.warning("couldn't open \(Paths.instanceLock.path)")
            return true
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }
        lockDescriptor = fd
        return true
    }

    // MARK: - Migration

    /// Moves a machine off the pre-app install, once, on the app's launch:
    /// stops and deletes the old LaunchAgent, keeps launch at login on if it
    /// was, and offers to point the `parrot` command at this app. Models,
    /// config, and logs stay where they are.
    @MainActor
    private static func migrateLegacyInstall(executable: URL) {
        let hadAgent = LegacyLaunchAgent.remove()
        LegacyLaunchAgent.removeTmpFiles()
        if hadAgent {
            // The user had chosen to start Parrot at login; keep that choice.
            do {
                try LoginItem.setEnabled(true)
                Log.info("launch at login moved to the login item")
            } catch {
                Log.warning("couldn't register the login item: \(error)")
            }
        }
        offerCommandLineLink(executable: executable, afterMigration: hadAgent)
    }

    /// Asks before touching `/usr/local/bin/parrot`. A plain binary from the
    /// old install is always offered for replacement; a missing command only
    /// right after a migration, so a fresh install doesn't ask on every launch.
    @MainActor
    private static func offerCommandLineLink(executable: URL, afterMigration: Bool) {
        let link = Paths.commandLineLink
        let title: String
        let message: String
        let action: String
        switch CommandLineLink.state(at: link, target: executable) {
        case .linked, .other:
            return
        case .plainFile:
            title = "Replace the old parrot command?"
            message = "An earlier Parrot install left a separate parrot program at \(link.path). "
                + "Replace it with a link to this app, so the parrot command always runs this version?"
            action = "Replace"
        case .linkedElsewhere(let destination):
            // A link into some other Parrot.app that no longer exists; never
            // a link the user pointed at something of their own.
            guard destination.contains("Parrot.app/"),
                  !FileManager.default.fileExists(atPath: destination) else { return }
            title = "Update the parrot command?"
            message = "\(link.path) points to a Parrot that is no longer there. Point it at this app?"
            action = "Update"
        case .missing:
            guard afterMigration else { return }
            title = "Add the parrot command?"
            message = "Link \(link.path) to this app, so `parrot setup` and `parrot doctor` work in a terminal."
            action = "Add"
        }

        guard alert(title, message, buttons: [action, "Not Now"]) == .alertFirstButtonReturn else {
            Log.info("left \(link.path) as it was")
            return
        }
        do {
            try CommandLineLink.install(at: link, target: executable, privileged: true)
            Log.info("linked \(link.path) to \(executable.path)")
        } catch CommandLineLink.LinkError.cancelled {
            Log.info("left \(link.path) as it was")
        } catch {
            Log.warning("couldn't link \(link.path): \(error)")
            _ = alert("Couldn't add the parrot command", "\(error)", buttons: ["OK"])
        }
    }

    // MARK: - Startup failures

    /// Explains a startup failure in a dialog when running as the app, where
    /// nobody reads stderr. The exit code rule in `Run` is unchanged.
    @MainActor
    public static func presentStartupFailure(_ failure: StartupFailure) {
        guard isApp else { return }
        NSApplication.shared.setActivationPolicy(.accessory)
        let (title, message, pane) = appMessage(for: failure)
        if let pane {
            if alert(title, message, buttons: ["Open System Settings", "Quit"]) == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                NSWorkspace.shared.open(url)
            }
        } else {
            _ = alert(title, message, buttons: ["Quit"])
        }
    }

    /// Title, body, and the Privacy & Security pane to open, for the app's
    /// dialog. Permission failures get app wording; the rest reuse the CLI's.
    static func appMessage(for failure: StartupFailure) -> (String, String, String?) {
        switch failure {
        case .microphoneDenied:
            return (
                "Parrot needs the microphone",
                "Turn on Parrot in System Settings → Privacy & Security → Microphone, then open Parrot again.",
                "Privacy_Microphone"
            )
        default:
            return ("Parrot couldn't start", failure.message, nil)
        }
    }

    // MARK: -

    /// The app has no terminal: send stdout and stderr to the owner-only log
    /// files the LaunchAgent used, so `Log` output keeps landing in
    /// `Paths.logs`.
    private static func redirectOutput() {
        do {
            try Paths.prepareDirectory(Paths.logs)
            for (file, fd) in [(Paths.daemonOutLog, STDOUT_FILENO), (Paths.daemonErrLog, STDERR_FILENO)] {
                try Paths.preparePrivateFile(file)
                let out = open(file.path, O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC)
                guard out >= 0 else { continue }
                dup2(out, fd)
                close(out)
            }
            setvbuf(stdout, nil, _IOLBF, 0)
        } catch {
            // Logging is best effort; the app still runs.
        }
    }

    private static func isOnDiskImageOrTranslocated(_ bundle: URL) -> Bool {
        let path = bundle.path
        if path.contains("/AppTranslocation/") { return true }
        let values = try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey])
        return values?.volumeIsReadOnly == true
    }

    @MainActor
    private static func alert(_ title: String, _ message: String, buttons: [String]) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        for button in buttons { alert.addButton(withTitle: button) }
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
    }
}
