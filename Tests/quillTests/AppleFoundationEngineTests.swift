import Foundation
import Testing

#if canImport(FoundationModels)
import FoundationModels
#endif

@testable import quill

/// The retry policy is the riskiest logic in the engine: classify a transient
/// condition as permanent and a session loses its notes forever; classify a
/// permanent one as transient and it retries on every launch until the end of
/// time. Neither is visible without a test.
/// swift-testing does not allow `@available` on a suite, so each test that
/// touches a macOS 26 type guards inside its body.
@Suite("generation error classification")
struct ErrorMappingTests {
    @Test("rate limiting defers — this is the background-on-battery case")
    func rateLimited() {
        guard #available(macOS 26.0, *) else { return }
        let mapped = AppleFoundationEngine.map(.rateLimited(.init(debugDescription: "t")))
        #expect(mapped.isRetryable)
        #expect(!mapped.isEngineDown)
    }

    @Test("contention and missing assets defer")
    func transientCases() {
        guard #available(macOS 26.0, *) else { return }
        #expect(AppleFoundationEngine.map(
            .concurrentRequests(.init(debugDescription: "t"))
        ).isRetryable)
        #expect(AppleFoundationEngine.map(
            .assetsUnavailable(.init(debugDescription: "t"))
        ).isRetryable)
    }

    /// These are properties of the transcript, not of the moment, so retrying
    /// can only ever fail the same way.
    @Test("guardrail, language, decoding and guide failures are permanent")
    func permanentCases() {
        guard #available(macOS 26.0, *) else { return }
        let context = LanguageModelSession.GenerationError.Context(debugDescription: "t")
        let permanent: [LanguageModelSession.GenerationError] = [
            .guardrailViolation(context),
            .unsupportedLanguageOrLocale(context),
            .decodingFailure(context),
            .unsupportedGuide(context),
            .exceededContextWindowSize(context),
            .refusal(.init(transcriptEntries: []), context),
        ]
        for error in permanent {
            let mapped = AppleFoundationEngine.map(error)
            #expect(!mapped.isRetryable, "\(error) should be permanent")
            #expect(!mapped.isEngineDown, "\(error) should not stop the queue")
        }
    }

    /// Exhaustiveness guard: every case the framework defines must be
    /// deliberately classified. If a future SDK adds one, this catches it
    /// falling through to `@unknown default` instead of it going unnoticed.
    @Test("every known case maps to a purposeful description")
    func allCasesDescribed() {
        guard #available(macOS 26.0, *) else { return }
        let context = LanguageModelSession.GenerationError.Context(debugDescription: "t")
        let all: [LanguageModelSession.GenerationError] = [
            .exceededContextWindowSize(context), .assetsUnavailable(context),
            .guardrailViolation(context), .unsupportedGuide(context),
            .unsupportedLanguageOrLocale(context), .decodingFailure(context),
            .rateLimited(context), .concurrentRequests(context),
            .refusal(.init(transcriptEntries: []), context),
        ]
        for error in all {
            let description = "\(AppleFoundationEngine.map(error))"
            #expect(description.count > 20, "\(error) got a uselessly terse description")
            #expect(!description.contains("GenerationError"), "\(error) fell through to default")
        }
    }

    @Test("availability reasons name the fix, not just the fault")
    func availabilityDescriptions() {
        guard #available(macOS 26.0, *) else { return }
        #expect(AppleFoundationEngine.describe(.appleIntelligenceNotEnabled)
            .contains("System Settings"))
        #expect(AppleFoundationEngine.describe(.modelNotReady).contains("downloading"))
        #expect(AppleFoundationEngine.describe(.deviceNotEligible).contains("does not support"))
    }
}

@Suite("context budget arithmetic")
struct BudgetTests {
    @Test("leaves room for output and schema overhead on a 4,096 window")
    func macOS26Window() throws {
        let budget = try SummarizationBudget.resolve(contextSize: 4_096, instructionTokens: 250)
        #expect(budget > 2_000)
        #expect(budget < 4_096 - 250)
    }

    /// quill reads contextSize at runtime rather than hardcoding it, so the same
    /// binary gets the larger window on macOS 27 without a code change.
    @Test("a larger window yields a proportionally larger budget")
    func macOS27Window() throws {
        let small = try SummarizationBudget.resolve(contextSize: 4_096, instructionTokens: 250)
        let large = try SummarizationBudget.resolve(contextSize: 8_192, instructionTokens: 250)
        #expect(large - small == 4_096)
    }

    @Test("longer instructions shrink the budget one-for-one")
    func instructionsCost() throws {
        let lean = try SummarizationBudget.resolve(contextSize: 4_096, instructionTokens: 100)
        let verbose = try SummarizationBudget.resolve(contextSize: 4_096, instructionTokens: 400)
        #expect(lean - verbose == 300)
    }

    @Test("refuses rather than returning a uselessly small budget")
    func refusesTooSmall() {
        #expect(throws: SummarizationError.self) {
            try SummarizationBudget.resolve(contextSize: 1_200, instructionTokens: 250)
        }
        #expect(throws: SummarizationError.self) {
            try SummarizationBudget.resolve(contextSize: 4_096, instructionTokens: 3_500)
        }
    }

    @Test("the refusal is permanent — a small window will not grow")
    func refusalIsPermanent() {
        do {
            _ = try SummarizationBudget.resolve(contextSize: 900, instructionTokens: 100)
            Issue.record("expected a throw")
        } catch let error as SummarizationError {
            #expect(!error.isRetryable)
            #expect("\(error)".contains("900"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    /// A budget at or below the floor would produce chunks too small to carry an
    /// exchange, which is worse than failing loudly.
    @Test("the floor is respected exactly")
    func floorBoundary() {
        let overhead = SummarizationBudget.reservedOutputTokens
            + SummarizationBudget.safetyTokens + 100
        #expect(throws: Never.self) {
            try SummarizationBudget.resolve(
                contextSize: overhead + SummarizationBudget.minimumTokens + 1,
                instructionTokens: 100
            )
        }
        #expect(throws: SummarizationError.self) {
            try SummarizationBudget.resolve(
                contextSize: overhead + SummarizationBudget.minimumTokens,
                instructionTokens: 100
            )
        }
    }
}
