// DiskImageInstaller.swift
// RightClickPasteKing
//
// The "nice installer" behaviors macOS doesn't provide natively:
//
//   * Launched FROM the disk image (or App-Translocated from it): offer to
//     move the app to /Applications. On consent: copy there, relaunch the
//     installed copy with a cleanup flag, and quit. The relaunched copy
//     silently ejects the image and moves the .dmg to the Trash — consent
//     was already given in the move prompt.
//
//   * Launched from a normal install location while our disk image is
//     still mounted (the user dragged the app out properly): ask whether
//     to eject the image and move the .dmg file to the Trash.
//
// The mount-point -> backing-.dmg mapping comes from `hdiutil info -plist`,
// the canonical source. Ejection uses NSWorkspace; trashing uses
// FileManager.trashItem (never a permanent delete).
//
// Note: Info.plist sets LSMultipleInstancesProhibited, so the relaunch
// can't simply spawn a second instance while we're alive — instead a
// detached shell helper waits for our PID to exit, then opens the
// installed copy (the classic LetsMove technique).

import AppKit
import os.log

enum DiskImageInstaller {

    private static let log = Logger(subsystem: "com.mrbco.RightClickPasteKing",
                                    category: "installer")

    /// Argument passed to the relaunched /Applications copy meaning "the
    /// user already consented to cleanup — eject our image and trash the
    /// .dmg without asking again".
    static let cleanupArgument = "--rcpk-cleanup-dmg"

    // MARK: - Startup entry points (called from AppDelegate)

    /// Handles the running-from-the-image case. Returns true if the app is
    /// relaunching into /Applications and the caller should abort the rest
    /// of its launch sequence.
    static func offerMoveToApplicationsIfNeeded() -> Bool {
        guard isRunningFromDiskImage else { return false }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.dmgMoveTitle
        alert.informativeText = L10n.dmgMoveBody
        alert.addButton(withTitle: L10n.dmgMoveConfirm)
        alert.addButton(withTitle: L10n.dmgMoveCancel)
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            log.info("move to /Applications declined; running from image")
            return false
        }
        return moveToApplicationsAndRelaunch()
    }

    /// Handles the relaunch-with-consent case: silently eject our image
    /// and trash the .dmg. No prompt — consent came with the move.
    static func performConsentedCleanupIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains(cleanupArgument) else { return }
        log.info("cleanup argument present — ejecting and trashing our image")
        cleanupOurMountedImage()
    }

    /// Handles the dragged-properly-but-image-still-mounted case: ask, then
    /// eject + trash. Call a beat after launch so it doesn't collide with
    /// the first-run window appearing.
    static func offerCleanupOfLeftoverImage() {
        // Not applicable while we're the copy ON the image — that's the
        // move flow's territory — and don't double-handle the consented case.
        guard !isRunningFromDiskImage,
              !ProcessInfo.processInfo.arguments.contains(cleanupArgument),
              mountedImageContainingOurApp() != nil else { return }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.dmgCleanupTitle
        alert.informativeText = L10n.dmgCleanupBody
        alert.addButton(withTitle: L10n.dmgCleanupConfirm)
        alert.addButton(withTitle: L10n.dmgCleanupCancel)
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        cleanupOurMountedImage()
    }

    // MARK: - Detection

    /// True when the running bundle lives on a mounted disk image, either
    /// directly (/Volumes/... on an hdiutil-managed volume) or via App
    /// Translocation (the randomized read-only mount macOS uses for
    /// quarantined apps launched in place).
    static var isRunningFromDiskImage: Bool {
        let path = Bundle.main.bundlePath
        if path.contains("/AppTranslocation/") { return true }
        guard path.hasPrefix("/Volumes/") else { return false }
        return mountedImages().contains { image in
            image.mountPoints.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
    }

    struct MountedImage: Equatable {
        let imagePath: String
        let mountPoints: [String]
    }

    /// All currently mounted disk images, per hdiutil.
    static func mountedImages() -> [MountedImage] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["info", "-plist"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()  // discard
        do {
            try process.run()
        } catch {
            log.error("hdiutil launch failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parseImages(fromPlistData: data)
    }

    /// Pure plist parsing, split out for unit testing.
    static func parseImages(fromPlistData data: Data) -> [MountedImage] {
        guard let plist = try? PropertyListSerialization.propertyList(
                from: data, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else {
            return []
        }
        return images.compactMap { image in
            guard let imagePath = image["image-path"] as? String else { return nil }
            let entities = image["system-entities"] as? [[String: Any]] ?? []
            let mounts = entities.compactMap { $0["mount-point"] as? String }
            return MountedImage(imagePath: imagePath, mountPoints: mounts)
        }
    }

    /// Finds a mounted disk image carrying a copy of THIS app (matched by
    /// bundle identifier at the volume root), along with where.
    static func mountedImageContainingOurApp() -> (image: MountedImage, mountPoint: String)? {
        guard let ourBundleID = Bundle.main.bundleIdentifier else { return nil }
        let fm = FileManager.default
        for image in mountedImages() {
            for mount in image.mountPoints where mount.hasPrefix("/Volumes/") {
                guard let items = try? fm.contentsOfDirectory(atPath: mount) else { continue }
                for item in items where item.hasSuffix(".app") {
                    if Bundle(path: mount + "/" + item)?.bundleIdentifier == ourBundleID {
                        return (image, mount)
                    }
                }
            }
        }
        return nil
    }

    // MARK: - Move + relaunch

    private static func moveToApplicationsAndRelaunch() -> Bool {
        let fm = FileManager.default
        let source = Bundle.main.bundleURL
        let dest = URL(fileURLWithPath: "/Applications")
            .appendingPathComponent(source.lastPathComponent)
        do {
            // An older copy in /Applications goes to the Trash first —
            // recoverable, unlike a removeItem.
            if fm.fileExists(atPath: dest.path) {
                try fm.trashItem(at: dest, resultingItemURL: nil)
            }
            try fm.copyItem(at: source, to: dest)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "RightClickPasteKing"
            alert.informativeText = String(format: L10n.dmgMoveFailed,
                                           error.localizedDescription)
            alert.runModal()
            return false
        }

        // LSMultipleInstancesProhibited forbids a second live instance, so:
        // a detached shell waits for THIS pid to exit, then opens the
        // installed copy with the cleanup-consent flag. The child survives
        // our termination (it isn't in our signal path).
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.1; done; "
                   + "/usr/bin/open -a \"\(dest.path)\" --args \(cleanupArgument)"
        let relauncher = Process()
        relauncher.executableURL = URL(fileURLWithPath: "/bin/sh")
        relauncher.arguments = ["-c", script]
        do {
            try relauncher.run()
        } catch {
            log.error("relauncher spawn failed: \(error.localizedDescription, privacy: .public)")
            // The copy is in /Applications regardless; worst case the user
            // launches it by hand. Still proceed with quitting.
        }
        log.info("moved to /Applications; quitting so the installed copy can take over")
        DispatchQueue.main.async { NSApp.terminate(nil) }
        return true
    }

    // MARK: - Eject + trash

    private static func cleanupOurMountedImage() {
        guard let found = mountedImageContainingOurApp() else {
            log.info("no mounted image carrying our app — nothing to clean up")
            return
        }
        // Never saw off the branch we're sitting on.
        if Bundle.main.bundlePath.hasPrefix(found.mountPoint) {
            log.info("we are running from that image — skipping cleanup")
            return
        }

        var allEjected = true
        for mount in found.image.mountPoints where mount.hasPrefix("/Volumes/") {
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: URL(fileURLWithPath: mount))
                log.info("ejected \(mount, privacy: .public)")
            } catch {
                allEjected = false
                log.error("eject failed for \(mount, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        // Trash the backing .dmg only if every mount ejected — trashing the
        // file under a still-mounted image is asking for trouble.
        guard allEjected else { return }
        do {
            try FileManager.default.trashItem(
                at: URL(fileURLWithPath: found.image.imagePath),
                resultingItemURL: nil)
            log.info("trashed \(found.image.imagePath, privacy: .public)")
        } catch {
            // Common benign case: the .dmg was already deleted or lives
            // somewhere we can't write. The eject succeeded; good enough.
            log.error("trash failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
