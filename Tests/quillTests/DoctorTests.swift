import Foundation
import Testing

@testable import quill

/// `Run.runMain` aborts startup when any check hard-fails. Summarization is
/// optional post-processing, so it must never be the reason quill won't record —
/// losing a meeting is far worse than losing its notes.
@Suite("summarization never blocks startup")
struct SummarizationCheckTests {
    private func isFail(_ check: Check) -> Bool {
        if case .fail = check.status { return true }
        return false
    }

    @Test("no combination of inputs produces a hard failure")
    func neverFails() {
        let reasons: [String?] = [
            nil,
            "Apple Intelligence is off — System Settings → Apple Intelligence & Siri",
            "this Mac does not support Apple Intelligence",
            "the system model is still downloading — try again later",
            "needs macOS 26 or later",
            "unavailable for an unknown reason",
        ]
        for enabled in [true, false] {
            for reason in reasons {
                let check = DoctorReport.summarizationCheck(
                    enabled: enabled, unavailableReason: reason, template: "default"
                )
                #expect(!isFail(check), "enabled=\(enabled) reason=\(reason ?? "nil") hard-failed")
            }
        }
    }

    @Test("a full report with summarization unavailable still passes allOK")
    func reportStaysStartable() {
        let checks = [
            Check(name: "recordings folder", status: .ok, remediation: nil),
            DoctorReport.summarizationCheck(
                enabled: true,
                unavailableReason: "Apple Intelligence is off — System Settings → Apple Intelligence & Siri",
                template: "default"
            ),
        ]
        #expect(DoctorReport.allOK(checks))
    }

    @Test("reports ok only when enabled and the model is reachable")
    func okPath() {
        let check = DoctorReport.summarizationCheck(
            enabled: true, unavailableReason: nil, template: "standup"
        )
        if case .ok = check.status {} else {
            Issue.record("expected ok, got \(check.status)")
        }
    }

    @Test("says it is off when disabled, regardless of model state")
    func disabledPath() {
        let check = DoctorReport.summarizationCheck(
            enabled: false, unavailableReason: "anything at all", template: "default"
        )
        if case .warn(let message) = check.status {
            #expect(message.contains("disabled"))
        } else {
            Issue.record("expected warn, got \(check.status)")
        }
    }

    @Test("points at the settings toggle, and promises a backfill")
    func remediationForDisabledAI() {
        let check = DoctorReport.summarizationCheck(
            enabled: true,
            unavailableReason: "Apple Intelligence is off — System Settings → Apple Intelligence & Siri",
            template: "default"
        )
        #expect(check.remediation?.contains("Apple Intelligence") == true)
        #expect(check.remediation?.contains("next run") == true)
    }

    @Test("makes clear that recording is unaffected")
    func reassures() {
        let check = DoctorReport.summarizationCheck(
            enabled: true, unavailableReason: "the system model is still downloading", template: "default"
        )
        if case .warn(let message) = check.status {
            #expect(message.contains("recording and transcription unaffected"))
        } else {
            Issue.record("expected warn, got \(check.status)")
        }
    }
}
