import Foundation
import Testing

/// Launches the built binary as a subprocess.
///
/// Every other test in this package exercises pure logic, which is why a build
/// that crashed on `quill run` — the primary command — passed 89 of them. Two
/// separate regressions came from changing how ArgumentParser dispatches
/// subcommands, and both are invisible to unit tests but obvious the moment the
/// process actually starts:
///
/// 1. `MainActor.assumeIsolated` trapping because an async root command no
///    longer enters `run()` on the main thread — the banner never appears.
/// 2. `NSApp.run()` blocking inside a main-queue work item, starving the serial
///    main queue and with it the SIGINT source, every `Task { @MainActor }`
///    menu-bar update, and the mic's silent-route fallback — the process
///    launches fine and then ignores ^C.
///
/// Needs a GUI session: the status item is created before the banner is printed.
@Suite("daemon smoke")
struct DaemonSmokeTests {
    /// The release or debug binary, whichever has been built. Returns nil when
    /// neither exists so the suite skips rather than failing spuriously.
    private var binary: URL? {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return ["release", "debug"]
            .map { root.appendingPathComponent(".build/\($0)/quill") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    @Test("launches, prints its banner, and exits on SIGINT")
    func launchesAndQuits() throws {
        guard let binary else { return }

        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quill-smoke-\(ProcessInfo.processInfo.processIdentifier)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let errLog = scratch.appendingPathComponent("stderr.log")
        FileManager.default.createFile(atPath: errLog.path, contents: nil)

        let process = Process()
        process.executableURL = binary
        process.arguments = ["run", "--out", scratch.appendingPathComponent("recordings").path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = try FileHandle(forWritingTo: errLog)
        try process.run()
        defer {
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }

        func stderrText() -> String {
            (try? String(contentsOf: errLog, encoding: .utf8)) ?? ""
        }

        var launched = false
        for _ in 0..<60 where process.isRunning {
            if stderrText().contains("quill up") {
                launched = true
                break
            }
            usleep(200_000)
        }
        #expect(
            launched,
            "daemon never printed its banner — it crashed on startup. stderr:\n\(stderrText())"
        )
        guard launched else { return }

        process.interrupt()
        var exited = false
        for _ in 0..<50 {
            if !process.isRunning {
                exited = true
                break
            }
            usleep(200_000)
        }
        let starved = """
            daemon ignored SIGINT — the main queue is starved, so menu-bar updates \
            and the mic fallback are dead too. stderr:
            \(stderrText())
            """
        #expect(exited, "\(starved)")
        if exited {
            #expect(stderrText().contains("shutting down"))
        }
    }
}
