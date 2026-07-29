import AVFoundation
import FluidAudio
import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

enum CheckStatus {
    case ok
    case warn(String)
    case fail(String)
}

struct Check {
    let name: String
    let status: CheckStatus
    let remediation: String?
}

enum DoctorReport {
    static func run(recordingsRoot: URL) -> [Check] {
        [
            checkMicrophone(),
            checkSystemAudio(),
            checkRecordingsRoot(recordingsRoot),
            checkTranscription(),
            checkSummarization(),
        ]
    }

    /// Never discover after an important meeting that notes were never going to
    /// be written. Reports the real availability reason, which is usually that
    /// Apple Intelligence has not been switched on.
    static func checkSummarization() -> Check {
        var reason: String?
        if #available(macOS 26.0, *) {
            if case .unavailable(let r) = SystemLanguageModel.default.availability {
                reason = AppleFoundationEngine.describe(r)
            }
        } else {
            reason = "needs macOS 26 or later"
        }
        return summarizationCheck(
            enabled: Config.summarizationEnabled(),
            unavailableReason: reason,
            template: Config.summarizationEnabled()
                ? Template.load(named: Config.summarizationTemplate()).name
                : Template.fallbackName
        )
    }

    /// Split out from the availability lookup so the reporting rules can be
    /// tested without a model or a config file.
    ///
    /// Never returns `.fail`. `Run` treats a hard failure as fatal, and an
    /// unusable optional summarizer must not stop quill from recording — losing
    /// a meeting is far worse than losing its notes.
    static func summarizationCheck(
        enabled: Bool,
        unavailableReason: String?,
        template: String
    ) -> Check {
        guard enabled else {
            return Check(name: "summarization", status: .warn("disabled in config"), remediation: nil)
        }
        guard let unavailableReason else {
            return Check(
                name: "summarization",
                status: .ok,
                remediation: nil
            )
        }
        return Check(
            name: "summarization",
            status: .warn("\(unavailableReason) — recording and transcription unaffected"),
            remediation: unavailableReason.contains("Apple Intelligence is off")
                ? "System Settings → Apple Intelligence & Siri → turn on Apple Intelligence. "
                    + "Sessions already recorded are summarized on the next run."
                : "template \"\(template)\" is ready; the model is not"
        )
    }

    static func checkMicrophone() -> Check {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return Check(name: "microphone", status: .ok, remediation: nil)
        case .notDetermined:
            return Check(
                name: "microphone",
                status: .warn("not yet requested — will prompt on first recording"),
                remediation: "start a recording once; macOS will prompt"
            )
        case .denied, .restricted:
            return Check(
                name: "microphone",
                status: .fail("denied"),
                remediation: "System Settings → Privacy & Security → Microphone → enable for quill (or your terminal)"
            )
        @unknown default:
            return Check(name: "microphone", status: .fail("unknown state"), remediation: nil)
        }
    }

    /// There is no public API to query the system-audio-capture TCC state
    /// without side effects, so all we can do is describe the flow — accurately.
    ///
    /// It does **not** prompt. `AudioHardwareCreateProcessTap` succeeds without
    /// the permission and then delivers digital silence indefinitely, which is
    /// how a real 21-minute meeting got recorded with only one side of the
    /// conversation. Saying "will prompt on first recording" here is what let
    /// that happen, so this now says the opposite.
    static func checkSystemAudio() -> Check {
        Check(
            name: "system audio",
            status: .warn("cannot be checked up front — and it never prompts"),
            remediation: "grant Screen & System Audio Recording to whatever launches quill "
                + "(your terminal, or quill itself as a LaunchAgent) and restart it. "
                + "quill warns after 20s of silence and records peak_level in meta.json"
        )
    }

    static func checkRecordingsRoot(_ root: URL) -> Check {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            return Check(
                name: "recordings folder",
                status: .fail("can't create \(root.path)"),
                remediation: "check permissions on the parent directory"
            )
        }
        guard FileManager.default.isWritableFile(atPath: root.path) else {
            return Check(
                name: "recordings folder",
                status: .fail("\(root.path) is not writable"),
                remediation: "check permissions on the directory"
            )
        }
        return Check(name: "recordings folder", status: .ok, remediation: nil)
    }

    /// Never discover a missing model after an important meeting: report
    /// whether the parakeet models are already in FluidAudio's cache.
    static func checkTranscription() -> Check {
        guard Config.transcriptionEnabled() else {
            return Check(
                name: "transcription",
                status: .warn("disabled in config"),
                remediation: nil
            )
        }
        let cache = AsrModels.defaultCacheDirectory(for: .v2)
        if AsrModels.modelsExist(at: cache, version: .v2) {
            return Check(name: "transcription", status: .ok, remediation: nil)
        }
        return Check(
            name: "transcription",
            status: .warn("parakeet models not downloaded (~600 MB)"),
            remediation: "downloads automatically on first transcription — record a short test session while online"
        )
    }

    static func print(_ checks: [Check]) {
        for c in checks {
            let (mark, label): (String, String) = {
                switch c.status {
                case .ok: return ("✓", "ok")
                case .warn(let msg): return ("!", msg)
                case .fail(let msg): return ("✗", msg)
                }
            }()
            Swift.print("\(mark) \(c.name): \(label)")
            if let r = c.remediation {
                Swift.print("    → \(r)")
            }
        }
    }

    /// True if no checks are in a hard-fail state. Warnings don't block.
    static func allOK(_ checks: [Check]) -> Bool {
        checks.allSatisfy {
            if case .fail = $0.status { return false }
            return true
        }
    }
}
