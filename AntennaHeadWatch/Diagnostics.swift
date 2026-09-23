import Foundation
import os
import WatchKit

/// Temporary diagnostics for "the app won't come back to the foreground
/// while audio plays in the background". Writes to stderr (unbuffered, so
/// `devicectl device process launch --console` shows it live), to a file in
/// the app container, and to the unified log.
///
/// - Lifecycle: every WKApplicationDelegate transition.
/// - Main-thread heartbeat: a main-queue timer stamps `lastBeat` each second.
/// - Watchdog: a background thread reports whenever the main thread has
///   missed beats for 3 s or more, and when it recovers — so a hang shows up
///   with its start time and length even though the UI can't.
enum Diagnostics {
    nonisolated private static let log = Logger(subsystem: "com.dsward.AntennaHeadiOS.watchkitapp", category: "Diagnostics")
    nonisolated private static let lastBeat = OSAllocatedUnfairLock(initialState: Date())

    /// `Documents/diagnostics.log` in the app container, so the log survives
    /// without a console attached. Copy it off with
    /// `devicectl device copy from --domain-type appDataContainer
    /// --domain-identifier com.dsward.AntennaHeadiOS.watchkitapp
    /// --source Documents/diagnostics.log --destination <file>`.
    nonisolated private static let file: FileHandle? = {
        let url = URL.documentsDirectory.appending(path: "diagnostics.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        return handle
    }()
    nonisolated private static let fileLock = OSAllocatedUnfairLock()

    nonisolated static func note(_ message: String) {
        let line = "[\(Date().formatted(.iso8601.time(includingFractionalSeconds: true)))] \(message)\n"
        let data = Data(line.utf8)
        FileHandle.standardError.write(data)
        fileLock.withLock { try? file?.write(contentsOf: data) }
        log.info("\(message, privacy: .public)")
    }

    @MainActor
    static func start() {
        note("launch")
        // `.common` modes, so the heartbeat keeps beating while the Digital
        // Crown scrolls the list (tracking mode) and only a real hang stops it.
        let heartbeat = Timer(timeInterval: 1, repeats: true) { _ in
            lastBeat.withLock { $0 = Date() }
        }
        RunLoop.main.add(heartbeat, forMode: .common)
        let watchdog = Thread {
            var stalled = false
            while true {
                Thread.sleep(forTimeInterval: 1)
                let gap = Date().timeIntervalSince(lastBeat.withLock { $0 })
                if gap >= 3, !stalled {
                    stalled = true
                    note("MAIN THREAD STALLED (no heartbeat for \(Int(gap)) s)")
                } else if gap >= 3, Int(gap) % 10 == 0 {
                    note("main thread still stalled (\(Int(gap)) s)")
                } else if gap < 3, stalled {
                    stalled = false
                    note("main thread recovered")
                }
            }
        }
        watchdog.name = "Diagnostics watchdog"
        watchdog.start()
    }
}

final class DiagnosticsAppDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() { Diagnostics.note("didFinishLaunching") }
    func applicationDidBecomeActive() { Diagnostics.note("didBecomeActive") }
    func applicationWillResignActive() { Diagnostics.note("willResignActive") }
    func applicationWillEnterForeground() { Diagnostics.note("willEnterForeground") }
    func applicationDidEnterBackground() { Diagnostics.note("didEnterBackground") }
}
