---
title: "Granola-style meeting notes from a local Apple foundation model"
date: 2026-07-28
status: proposed
affects: "post-transcription pipeline, config, minimum OS version"
---

## Context

Quill records two tracks, transcribes each with Parakeet, and merges the
segments into `transcript.json` (canonical) plus `transcript.md` (readable).
The pipeline ends there. `on_stop` exists as the documented seam for whatever
comes next — summarization, filing, indexing — and currently receives a folder
containing only a raw transcript.

The goal is intelligent notes in the style of Granola: a specific title, a
short abstract, template-driven sections, explicit decisions, and owned action
items — produced entirely on-device, preserving the property asserted in
`Info.plist` and the README that nothing leaves the Mac.

Quill starts from an unusually good position for this. Two-track capture gives
speaker attribution that most summarizers have to infer, and every segment
already carries millisecond timestamps against a single shared clock.

## Platform survey (July 2026)

Apple's Foundation Models framework exposes the on-device model to Swift via
`SystemLanguageModel` and `LanguageModelSession`, with guided generation:
annotate a type `@Generable` and constrained decoding returns that type
populated and type-checked rather than a string to parse
[1](https://developer.apple.com/videos/play/wwdc2026/241/).

WWDC 2026 moved the baseline substantially:

| | macOS 26 (shipping) | macOS 27 (developer beta) |
|---|---|---|
| On-device context | 4,096 tokens, input+output shared | 8,192 tokens, model rebuilt |
| Token introspection | `contextSize`, `tokenCount(for:)` (26.4+) | same |
| CLI | — | `fm` preinstalled |
| Alternate local backends | — | `MLXLanguageModel` (GPU), `CoreAILanguageModel` (ANE) |
| Private Cloud Compute | available | 32k context, `.light`/`.deep` reasoning |

The framework core is open source, and a separately-versioned utilities package
ships profile modifiers for transcript management. A new `LanguageModel`
protocol lets any local or hosted model back a `LanguageModelSession`, so the
choice of backend is swappable without touching downstream code
[2](https://developer.apple.com/videos/play/wwdc2026/339/).

macOS 27 is developer-beta as of this writing; public release is expected in
the autumn. Anything depending on 8,192 tokens or `fm` is a beta-only bet
today.

## Constraint 1 — the transcript does not fit, and `transcript.md` makes it worse

Conversational speech runs 130–150 wpm, so an hour of meeting is roughly 8,500
words, or about 12,000 tokens. That overflows 4,096 by threefold and 8,192 by
half. Exceeding the window throws rather than truncating; there is no overflow
strategy to opt into [3](https://zats.io/blog/making-the-most-of-apple-foundation-models-context-window/).

Feeding `transcript.md` directly is additionally wasteful. `ParakeetEngine`
breaks a segment at every sentence-ending token, so an hour produces several
hundred segments, each rendered with a `**[12:34] them:** ` prefix — on the
order of 5,000 tokens of pure scaffolding, nearly a full macOS 26 context
window spent on formatting. The summarizer must read `transcript.json` and
re-render compactly: speaker label only on change, no per-segment timestamps.

Map-reduce is therefore mandatory, not an optimization
[4](https://www.f22labs.com/blogs/map-reduce-for-large-document-summarization-with-llms/):

1. **Map.** Chunk the compact transcript to roughly 70% of `contextSize` less
   instructions and reserved output — about 3,000 tokens on macOS 26, 6,500 on
   27 — with ~10% overlap so a boundary never severs an exchange. Extract
   structured findings per chunk.
2. **Reduce.** An hour yields four chunks on macOS 26, two on 27. At ~400
   tokens of extraction each, all partials fit a single reduce call. One level
   of reduction covers meetings to roughly three hours; beyond that, merge
   pairwise and re-reduce.

Read the budget from `contextSize` and measure with `tokenCount(for:)` rather
than hardcoding 4,096 or estimating by character count. The same binary then
adapts to the larger macOS 27 window with no change.

**Do not ask the model for timestamps.** It will invent them, and citation back
into the audio is quill's distinguishing feature. Each chunk already knows the
`[start_ms, end_ms]` of the segments that composed it; attach that range
structurally to whatever is extracted from that chunk. "Decision at 14:02"
becomes ground truth rather than a guess.

## Constraint 2 — quill is a background daemon

Rate limiting applies when the process is in the background *and* the device is
on battery [5](https://developer.apple.com/documentation/foundationmodels/languagemodelsession/generationerror/ratelimited(_:)) —
precisely `com.digimata.quill` running as a `KeepAlive` LaunchAgent on an
unplugged laptop after a meeting. Apple's guidance for background use is to
avoid streaming and call `respond` for the whole response, since streaming
costs more power and reaches the limit sooner.

Quill's filesystem-as-queue idiom absorbs this for free: a session with
`transcript.json` and no `summary.json` is pending, so `rateLimited` is a
deferral rather than a failure, retried on next drain or next launch.

## Constraint 3 — Granola is not a summarizer

Granola takes three inputs: the transcript, the sparse notes typed during the
call, and the calendar event. The user's shorthand is the skeleton and the
transcript supplies evidence — type "pricing concerns" and it locates every
pricing discussion and attaches the quotes. Their documentation describes the
notes as a guide that helps the model "add context, summaries, and structure
from the transcript," and the user's own lines remain visually distinct in the
output [6](https://docs.granola.ai/help-center/taking-notes/ai-enhanced-notes).
Templates define the sections that always get populated
[7](https://www.granola.ai/blog/meeting-recipes-repeatable-formats).

That human-authored skeleton is why the output reads as specific rather than
generic. Quill has no note-taking surface — the entire UI is an `NSStatusItem`,
and a floating overlay was already tried and reverted (`60c1571`). So the
skeleton has to come from somewhere else:

- **Templates as the skeleton (chosen).** Template sections replace the user's
  notes as the structure the model fills from the transcript. Markdown files in
  `~/.config/quill/templates/`, selected by config or per session. No UI work,
  and it captures the half of Granola's mechanic that does the most work.
- **A notes affordance (deferred).** Much closer to the real product, but it
  contradicts quill's single-status-item design and has been reverted once.
- **Calendar context (phase 4).** EventKit gives the event title for
  auto-naming a session and the event type for auto-selecting a template. Costs
  one additional TCC prompt.

## Design

A `SummarizationEngine` protocol mirrors the existing `TranscriptionEngine` —
`prepare()` / `summarize()` / `release()` — preserving the lazy-prepare,
release-on-drain discipline so quill never idles holding a model session.
`TranscriptionCoordinator` gains a summarize step between
`try transcript.write(to: dir)` and `runHook(for: dir)`, writing `summary.json`
and `summary.md`. The hook consequently receives a summarized folder, which is
strictly better for anything chained downstream.

Output shape, as a guided-generation type:

```swift
@Generable struct MeetingNotes {
    @Guide(description: "Specific title naming the actual topic, never 'Meeting Notes'")
    var title: String
    @Guide(description: "Two sentences: what this meeting was for, and what came out of it")
    var tldr: String
    var sections: [Section]        // heading + bullets, driven by the template
    var decisions: [Decision]      // explicitly stated only, with time range
    var actionItems: [ActionItem]  // owner: me | them | unassigned
    var openQuestions: [String]
}
```

Action-item ownership can only be `me` / `them` / `unassigned`, because
attribution is filesystem-based (`mic.caf` → `me`, `system.caf` → `them`) and
every remote participant collapses into a single `them`. EventKit attendees
could seed better guesses; inventing who said what is worse than admitting the
limit.

Config, additive and off by default until it earns being on:

```json
{ "summarization": { "enabled": true, "model": "on-device", "template": "default" } }
```

`FoundationModels` requires macOS 26, while quill targets macOS 15. Keep
`platforms: [.macOS(.v15)]` and gate the summarizer with
`@available(macOS 26, *)`, so recording and transcription continue to work
unchanged on older systems.

### Security

Transcript content is untrusted input: anyone on a call can say "ignore your
instructions and…" and it lands in the prompt. The API separates trusted
`instructions:` from the prompt — the template and rules belong in
`instructions`, the transcript in the prompt, never the reverse. Handle
`guardrailViolation` by leaving the transcript in place and logging to
`transcribe.log`; a heated meeting must not cost the user their notes.

### Quality expectations

The on-device model is roughly 3B parameters at about 2 bits per weight.
Granola uses frontier hosted models. Expect competent extraction (action items
and decisions where explicitly stated), materially weaker synthesis (thematic
narrative, subtext), and a pull toward generic filler. What helps: extractive
framing over abstractive, several small focused prompts over one large one,
guided generation to force structure, and the new Evaluations framework to
measure prompt changes instead of eyeballing them.

Two escape hatches, both reachable without changing downstream code because
`LanguageModel` is a protocol:

- **`MLXLanguageModel`** runs a 7–14B model on the Mac's GPU — much closer to
  Granola's quality, with a context window large enough that map-reduce may
  become unnecessary, at the cost of multi-gigabyte weights and slower
  inference.
- **Private Cloud Compute** offers 32k context and reasoning with no API key
  and strong privacy guarantees, but it *is* network egress. It contradicts
  `Info.plist`'s "Audio never leaves this Mac" and the README's "Nothing ever
  leaves the machine." Admissible only as explicit opt-in with both texts
  amended. Not a default, and not in scope here.

## Plan of attack

**Phase 0 — availability spike (blocking).** Confirm
`SystemLanguageModel.default.availability` returns `.available` from inside the
LaunchAgent context, not merely from a terminal run. Quill deliberately has no
`.app` bundle and already needed `-sectcreate __info_plist` for TCC
attribution; Apple has moved away from requiring bundles, but this assumption
underpins everything downstream and is worth twenty lines to settle. Log
`contextSize` and a `tokenCount(for:)` sample while there.

**Phase 1 — prompt and template iteration outside Swift.** On macOS 27, wire
`fm` to the existing `on_stop` hook and iterate with no changes to quill at all
[8](https://developer.apple.com/videos/play/wwdc2026/334/):

```sh
fm schema object --name MeetingNotes \
  --string title --string tldr \
  --string decisions --array --string action_items --array > /tmp/notes.json

fm respond --schema /tmp/notes.json \
  --instructions "$(cat ~/.config/quill/templates/standup.md)" \
  "$(compact-transcript "$1/transcript.json")" > "$1/summary.json"
```

`--model pcc` gives a quality ceiling to compare the on-device result against.
Learn what the small model can actually do against real sessions before
committing Swift. This script is throwaway by design.

**Phase 2 — the compaction and chunking layer.** `TranscriptCompactor`: read
`transcript.json`, render compactly, chunk against `contextSize` with 10%
overlap, and carry each chunk's `[start_ms, end_ms]`. Pure functions over
fixtures, independent of the model, and the first thing in this repo that
genuinely wants unit tests.

**Phase 3 — `SummarizationEngine` in-process.** Implement the protocol, the
`@Generable` types, map-reduce, and `summary.json` / `summary.md` writing.
Extend `resumePending` to treat a missing `summary.json` as work, which is also
the `rateLimited` retry path. Add the config block and a `doctor` check for
model availability, mirroring the existing Parakeet cache check.

**Phase 4 — templates and calendar.** Ship two or three templates
(`default`, `standup`, `1:1`), document authoring them, then EventKit for event
title and template selection.

Phases 2 and 3 are the real work. Phase 0 gates all of it. Phase 1 is
sequenced first deliberately: prompt quality, not plumbing, decides whether
this feature is worth shipping, and the cheapest way to find that out involves
writing no Swift.

## Relevant files

**Fix targets:**

- `Sources/quill/Transcription/TranscriptionCoordinator.swift` — insert the
  summarize step between transcript write and `runHook`; extend
  `resumePending` to treat a missing `summary.json` as pending work.
- `Sources/quill/Config.swift` — add the `summarization` block.
- `Sources/quill/Doctor.swift` — add a model-availability check alongside the
  existing Parakeet cache check.
- `Package.swift` — no new dependency; `FoundationModels` is a system
  framework. `platforms` stays `.macOS(.v15)`.
- `README.md` — document summarization, templates, and the macOS 26 floor for
  this feature specifically.

**New:**

- `Sources/quill/Summarization/SummarizationEngine.swift` — protocol and
  `MeetingNotes` types.
- `Sources/quill/Summarization/AppleFoundationEngine.swift` — the
  `FoundationModels` implementation, `@available(macOS 26, *)`.
- `Sources/quill/Summarization/TranscriptCompactor.swift` — compact rendering
  and chunking.

**Flow:**

- `Sources/quill/Transcription/ParakeetEngine.swift` — the segmentation rules
  that make `transcript.md` prefix-heavy, and the source of word timings.
- `Sources/quill/RecordingSession.swift` — writes the `start_offset_ms` that
  makes both tracks share one clock.
