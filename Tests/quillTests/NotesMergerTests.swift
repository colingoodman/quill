import Foundation
import Testing

@testable import quill

@Suite("normalization")
struct NormalizeTests {
    @Test("folds case, punctuation and spacing")
    func folds() {
        #expect(NotesMerger.normalize("Ship the API, Thursday!") == "ship the api thursday")
        #expect(NotesMerger.normalize("  double   spaced  ") == "double spaced")
        #expect(NotesMerger.normalize("") == "")
    }
}

@Suite("duplicate detection")
struct DuplicateTests {
    @Test("identical after folding")
    func identical() {
        #expect(NotesMerger.isDuplicate("Hold pricing at $40.", "hold pricing at 40"))
    }

    @Test("a restatement contained in a longer phrasing")
    func restatement() {
        #expect(NotesMerger.isDuplicate(
            "Hold pricing at forty per seat",
            "Hold pricing at forty per seat for now"
        ))
    }

    @Test("a short fragment inside a much longer point is not a duplicate")
    func fragmentIsNotDuplicate() {
        #expect(!NotesMerger.isDuplicate(
            "pricing",
            "Hold pricing at forty per seat until finance confirms the discount band"
        ))
    }

    @Test("unrelated points are distinct")
    func distinct() {
        #expect(!NotesMerger.isDuplicate("Ship the API", "Hire a designer"))
    }

    @Test("empty strings never match")
    func empties() {
        #expect(!NotesMerger.isDuplicate("", ""))
        #expect(!NotesMerger.isDuplicate("", "something"))
    }
}

@Suite("merging across chunks")
struct MergeTests {
    private func merge(_ items: [(String, Int?)]) -> [(String, Int?)] {
        NotesMerger.merge(items, text: \.0, at: \.1, rebuild: { ($0, $1) })
    }

    @Test("collapses what chunk overlap found twice")
    func collapsesOverlap() {
        let merged = merge([
            ("Hold pricing at forty", 10_000),
            ("Hold pricing at forty", 14_000),
        ])
        #expect(merged.count == 1)
    }

    @Test("keeps the earliest timestamp when collapsing")
    func keepsEarliest() {
        let merged = merge([
            ("Hold pricing at forty", 14_000),
            ("Hold pricing at forty", 10_000),
        ])
        #expect(merged.count == 1)
        #expect(merged[0].1 == 10_000)
    }

    @Test("prefers the fuller phrasing")
    func prefersLonger() {
        let merged = merge([
            ("Ship the API on Thursday", 5_000),
            ("Ship the API on Thursday after review", 6_000),
        ])
        #expect(merged.count == 1)
        #expect(merged[0].0 == "Ship the API on Thursday after review")
        #expect(merged[0].1 == 5_000)
    }

    @Test("orders by time")
    func ordersByTime() {
        let merged = merge([
            ("Third thing entirely", 30_000),
            ("First thing entirely", 1_000),
            ("Second thing entirely", 10_000),
        ])
        #expect(merged.map(\.0) == [
            "First thing entirely", "Second thing entirely", "Third thing entirely",
        ])
    }

    @Test("items with no timestamp sort last, deterministically")
    func nilTimestampsLast() {
        let merged = merge([("Beta point", nil), ("Alpha point", nil), ("Timed point", 500)])
        #expect(merged.map(\.0) == ["Timed point", "Alpha point", "Beta point"])
    }

    @Test("drops blank items")
    func dropsBlanks() {
        #expect(merge([("   ", 0), ("Real point", 1_000)]).count == 1)
    }

    @Test("preserves genuinely distinct points")
    func preservesDistinct() {
        #expect(merge([
            ("Ship the API", 1_000),
            ("Hire a designer", 2_000),
            ("Renew the certificate", 3_000),
        ]).count == 3)
    }

    @Test("is stable for an empty input")
    func empty() {
        #expect(merge([]).isEmpty)
    }
}

@Suite("notes rendering")
struct RenderTests {
    private func notes(
        sections: [MeetingNotes.Section] = [],
        decisions: [MeetingNotes.Decision] = [],
        actions: [MeetingNotes.ActionItem] = [],
        questions: [String] = []
    ) -> MeetingNotes {
        MeetingNotes(
            engine: "apple-foundation", model: "system-language-model",
            template: "default", created_at: "2026-07-28T00:00:00Z",
            title: "Pricing for the Acme renewal", tldr: "Two sentences here.",
            sections: sections, decisions: decisions,
            action_items: actions, open_questions: questions
        )
    }

    @Test("leads with the title and abstract")
    func header() {
        let md = notes().rendered()
        #expect(md.hasPrefix("# Pricing for the Acme renewal\n"))
        #expect(md.contains("Two sentences here."))
    }

    @Test("stamps decisions with the chunk time they came from")
    func decisionTimestamps() {
        let md = notes(decisions: [.init(text: "Hold at forty", at_ms: 754_000)]).rendered()
        #expect(md.contains("## Decisions"))
        #expect(md.contains("- [12:34] Hold at forty"))
    }

    @Test("renders action items as checkboxes with an owner")
    func actionItems() {
        let md = notes(actions: [
            .init(text: "Confirm with finance", owner: "me", at_ms: 61_000),
        ]).rendered()
        #expect(md.contains("- [ ] **me** — Confirm with finance · 1:01"))
    }

    @Test("omits every empty section rather than printing bare headings")
    func omitsEmpty() {
        let md = notes(sections: [.init(heading: "Discussion", bullets: [])]).rendered()
        #expect(!md.contains("## Discussion"))
        #expect(!md.contains("## Decisions"))
        #expect(!md.contains("## Action items"))
        #expect(!md.contains("## Open questions"))
    }

    @Test("records provenance in a footer")
    func provenance() {
        #expect(notes().rendered().contains("notes: apple-foundation (system-language-model) · template: default"))
    }

    @Test("survives a round trip through JSON")
    func roundTrip() throws {
        let original = notes(
            sections: [.init(heading: "Discussion", bullets: ["A point"])],
            decisions: [.init(text: "Decided", at_ms: 1_000)],
            actions: [.init(text: "Do it", owner: "them", at_ms: nil)],
            questions: ["Unresolved?"]
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(MeetingNotes.self, from: data) == original)
    }
}

@Suite("templates")
struct TemplateTests {
    @Test("parses headings into sections and prose into guidance")
    func parses() {
        let template = Template.parse(name: "custom", markdown: """
        # My template
        Keep it terse and specific.
        ## Progress
        ## Blockers
        """)
        #expect(template.sections == ["Progress", "Blockers"])
        #expect(template.guidance == "Keep it terse and specific.")
    }

    @Test("a template with no headings falls back to the default sections")
    func fallsBackSections() {
        let template = Template.parse(name: "empty", markdown: "Just guidance, no headings.")
        #expect(template.sections == Template.builtin("default").sections)
        #expect(template.guidance == "Just guidance, no headings.")
    }

    @Test("the title line is not treated as a section")
    func ignoresTitle() {
        #expect(Template.parse(name: "t", markdown: "# Title\n## Real").sections == ["Real"])
    }

    @Test("every builtin has sections and guidance")
    func builtinsWellFormed() {
        for (name, template) in Template.builtins {
            #expect(!template.sections.isEmpty, "\(name) has no sections")
            #expect(!template.guidance.isEmpty, "\(name) has no guidance")
            #expect(template.name == name)
        }
    }

    @Test("an unknown name resolves to the default")
    func unknownName() {
        #expect(Template.load(named: "no-such-template-exists").name == "default")
    }

    @Test("asMarkdown round-trips through parse")
    func roundTrip() {
        let original = Template.builtin("standup")
        let reparsed = Template.parse(name: "standup", markdown: original.asMarkdown)
        #expect(reparsed.sections == original.sections)
        #expect(reparsed.guidance == original.guidance)
    }
}

@Suite("summarization errors")
struct ErrorTests {
    /// Only a transcript-specific failure is permanent. An unreachable model is
    /// retryable so that sessions recorded before Apple Intelligence was
    /// enabled get backfilled rather than permanently marked failed.
    @Test("only transcript-specific failures are permanent")
    func retryability() {
        #expect(SummarizationError.retryable("rate limited").isRetryable)
        #expect(SummarizationError.unavailable("off").isRetryable)
        #expect(!SummarizationError.permanent("guardrail").isRetryable)
    }

    @Test("only an unreachable model stops the rest of the queue")
    func engineDown() {
        #expect(SummarizationError.unavailable("off").isEngineDown)
        #expect(!SummarizationError.retryable("rate limited").isEngineDown)
        #expect(!SummarizationError.permanent("guardrail").isEngineDown)
    }

    @Test("descriptions distinguish deferral from failure")
    func descriptions() {
        #expect("\(SummarizationError.retryable("x"))".contains("deferred"))
        #expect("\(SummarizationError.permanent("x"))".contains("failed"))
        #expect("\(SummarizationError.unavailable("x"))".contains("unavailable"))
    }
}
