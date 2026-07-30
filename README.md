# quill

A minimal, fully local macOS meeting recorder + transcriber. One menu-bar
click records your mic and all system audio as two separate tracks; when you
stop, quill transcribes both on-device and writes a speaker-tagged transcript.
Nothing ever leaves the machine.

Named for the feather. Sibling of [parrot](https://github.com/digimata/parrot), same skeleton: single
Swift binary, menu-bar tray, no app bundle.

## Install

```sh
cd quill
swift build -c release
sudo cp .build/release/quill /usr/local/bin/quill
quill install --launch-at-login   # optional — runs in the background on login
```

**Requires:** macOS 15+ (Core Audio process taps for system audio — no
virtual device, no kernel extension). Apple Silicon recommended for
transcription speed.

## How to use

1. **Grant Screen & System Audio Recording first** — see
   [System audio permission](#system-audio-permission). This does not prompt,
   and without it the system track records silence.
2. **Run it** (`quill` in a terminal, or the LaunchAgent).
3. **Click the feather in the menu bar → Start recording**, or use the Start
   button in the [live transcript window](#live-transcript-window). First use
   prompts for the microphone. While recording, the icon turns red with a
   running elapsed counter, and macOS shows the purple recording indicator.
4. **Click → Stop recording** when the meeting ends. Transcription starts

   automatically (the menu shows progress); a notification fires when the
   transcript is ready.

Each session lands in `~/Recordings/<yyyy.MM.dd-HHmm>/`:

| File | Contents |
|---|---|
| `mic.caf` | your side (default input device, AAC) |
| `system.caf` | everything the Mac played — the other side of the call (AAC) |
| `meta.json` | start/end timestamps, duration, per-track start offsets |
| `transcript.json` | canonical transcript — engine provenance + timed, speaker-tagged segments |
| `transcript.md` | the same transcript rendered for reading |
| `transcribe.log` | transcription progress/errors for this session |
| `summary.json` | canonical notes — title, abstract, sections, decisions, action items |
| `summary.md` | the same notes rendered for reading |
| `summarize.log` | summarization progress/errors for this session |

`meta.json` also carries `peak_level` per track, and a `warnings` array when a
track captured nothing but silence.

## System audio permission

**The microphone prompts. System audio does not.** `AudioHardwareCreateProcessTap`
succeeds without the permission and then delivers digital silence forever — no
prompt, no error, no clue. If you have never granted it, `system.caf` will be
silence and your transcript will contain only your own half of the conversation.

macOS attributes the permission to the **responsible process**, which for a
plain binary run from a shell is the *terminal app*, not quill. So:

- **Running from a terminal:** System Settings → Privacy & Security → Screen &
  System Audio Recording → enable your terminal (Terminal, iTerm, Ghostty, …).
  **Then restart the terminal** — TCC changes do not reach already-running
  processes.
- **Running as the LaunchAgent:** quill is its own responsible process, so grant
  it to `quill` itself. This is the more durable arrangement.

quill now notices on its own: if the tap delivers nothing but zeros for 20
seconds it fires a notification, and `meta.json` records `peak_level` for both
tracks plus a `warnings` entry. Verify a setup in fifteen seconds — play music,
record briefly, then:

```sh
python3 -c "import json,sys; m=json.load(open(sys.argv[1]));
print(m['peak_level']); print(m.get('warnings','no warnings'))" \
  ~/Recordings/<session>/meta.json
```

A `system` peak of `0` means the permission still is not in effect.

Two tracks on purpose: speech models do better on clean single-source audio,
and mic-vs-system is free two-party diarization — `me` vs `them` with no
speaker-identification model. CAF on purpose: unlike m4a, it needs no
finalization pass — if the process dies mid-meeting, everything already
written is still readable.

## Transcription

Built in, on-device, automatic. The default engine is **Parakeet TDT 0.6B v2**
(English) via [FluidAudio](https://github.com/FluidInference/FluidAudio)'s
Core ML port — roughly 20 seconds per hour of audio on Apple Silicon. Models
(~600 MB) download once on first transcription; `quill doctor` tells you
whether they're already cached so you're never downloading after an important
meeting.

Each track is transcribed separately, shifted by its start offset so both
share one clock, and merged by timestamp. Jobs run in a serial queue — you can
start a new recording while the last one transcribes. Unfinished jobs resume
on next launch (the filesystem is the queue: a session with `meta.json` but no
`transcript.json` is pending). Failures append to the session's
`transcribe.log` and never block later jobs.

The engine sits behind a small protocol; a Whisper engine (WhisperKit
large-v3-turbo) is planned as the fallback / re-transcription option.

## Live transcript window

A window with Start/Stop and the conversation appearing as it happens:

```sh
quill run --window        # open it at launch
```

Or **feather → Show live transcript** (⌘L) any time. Closing the window does
not stop recording — quill stays an `.accessory` app with no Dock icon, and the
window is just a surface you open when you want it.

Both tracks are transcribed live, so you see `me` and `them` interleaved with
the same labels the canonical transcript uses. Text that the recognizer has
committed to is shown normally; the in-flight guess at the end of each speaker's
turn is **dimmed**, because it will change.

Live transcription is a **tee on the capture path, never a dependency**.
Recording does not wait for it, buffers that arrive while its models load are
dropped, and if it fails the window says so while recording carries on. Three
things follow from that, worth knowing:

- **The live text is thrown away.** `transcript.json` still comes from the
  offline pass after you stop, which sees whole files, aligns both tracks on one
  clock, and is more accurate. The window is for watching, not for keeping.
- **Live lines are in arrival order**, not strict speech order. Two people
  talking at once can interleave slightly wrong on screen. The file gets it
  right.
- **It costs real compute** — two sliding-window recognizers for the duration of
  the meeting. Unnoticeable on an M-series desktop, worth knowing on battery.

It reuses the Parakeet models already downloaded for offline transcription: no
second model, no extra dependency.
## Notes

Off by default; switch it on with `summarization.enabled`. Once on, each
finished transcript becomes Granola-style notes — a specific title, a
two-sentence abstract, template-driven sections, decisions, and owned action
items — written by **Apple's on-device foundation model** via the
FoundationModels framework. Still nothing leaves the machine.

**Requires macOS 26 with Apple Intelligence enabled** (System Settings → Apple
Intelligence & Siri). Recording and transcription are unaffected if it isn't:
`quill doctor` reports why, sessions stay queued, and they are summarized on
the next run once the model becomes available. Summarization can never prevent
quill from recording.

The window is the constraint. An hour of meeting is ~12,000 tokens against a
4,096-token on-device context (8,192 on macOS 27, read at runtime), so notes are
produced map-reduce: the transcript is re-rendered compactly, split into
overlapping chunks, each extracted in its own session, and the findings merged.

The split of work is deliberate. The model extracts from one passage at a time
and writes the title and abstract. Deduplication, ordering, ownership and every
**timestamp** are assembled in Swift — a small model asked to reproduce
timestamps invents them, so each chunk carries its own time range and decisions
are stamped from that. Cited times are ground truth, not guesses.

Expect competent extraction and weaker synthesis: this is a ~3B model, not a
frontier one. Action-item ownership is `me` / `them` / `unassigned`, since
attribution is filesystem-based and every remote participant collapses into one
`them`.

Because the model is unreliable at anything but extraction, several guarantees
are enforced in code rather than asked for in the prompt:

- **Timestamps are located, not generated.** Each decision and action is matched
  back to the utterance that produced it by word overlap. An item that can't be
  matched carries no time rather than a wrong one.
- **Bullets must be traceable.** Any section bullet that doesn't match something
  actually said is dropped — the model fabricates plausible filler when a
  section is thin. This biases notes toward the extractive, deliberately.
- **Lines aimed at the summarizer are stripped before it reads them.** A
  transcript is untrusted input: anyone on a call can say "ignore your
  instructions". Prompting the model to disregard such lines was measured and
  made things *worse*, so `InjectionFilter` removes them instead. It's a
  blocklist of known phrasings, so novel wording can still get through — a
  mitigation, not a solution. Every dropped line is logged to `summarize.log`,
  and `transcript.json` is never altered.
- **Duplicates are merged deterministically** across chunks, between decisions
  and action items, and across sections.
- **Off-topic talk is labelled and dropped.** Every extracted item carries a
  `work`/`social` label the model fills by constrained decoding, and social ones
  are removed. Labelling is asked for because *omitting* is not: told to leave
  small talk out, the model instead promoted a colleague's holiday into its own
  section and into the title. Asking it to file each item and letting Swift act
  on the label works. Set `summarization.include_small_talk` to keep everything.
- **Titles are validated.** A title that is really a pile of keywords — every
  topic in the meeting welded together with hyphens — is rejected in favour of
  the first usable section heading.

### Templates

Granola's trick is that the sparse notes you type during a call guide the model.
quill has no note surface, so a template plays that role: its `##` headings are
the sections the model fills from the transcript.

```sh
quill templates            # list them; shows which is active
quill templates --write    # write the built-ins to ~/.config/quill/templates/
```

Built-ins: `default`, `standup`, `one-on-one`, `interview`, `sales`. Edit any
written file to change the shape of your notes; `--write` never clobbers your
edits. Select one with `summarization.template`.

### Re-running notes

`quill summarize <session-dir>` runs the same pipeline against a session that
already has a `transcript.json`, so you can try a different template — or a
different prompt — in seconds without recording anything:

```sh
quill summarize ~/Recordings/2026.07.28-1400 --template standup --print
quill summarize ~/Recordings/2026.07.28-1400 --force   # replace summary.json
```

`--print` writes nothing and sends the notes to stdout (progress goes to
stderr, so piping is clean). It ignores `summarization.enabled` — asking
explicitly is consent enough. This is also the quickest way to see whether the
model is reachable at all: it exits non-zero with the reason if not.

Two fixtures ship with the repo so notes can be exercised without recording:

```sh
quill summarize Tests/quillTests/Fixtures/pricing-call --print --template sales
quill summarize Tests/quillTests/Fixtures/injection-attempt --print
```

`pricing-call` has real decisions, owned commitments, and open questions to
find. `injection-attempt` is a transcript that tries to talk the summarizer out
of its instructions — its notes should describe a migration timeline, and
should not contain "BANANA", "PWNED", or pirate dialect. That the transcript is
untrusted input is the reason the template and rules go in the model's
`instructions` channel and never in the prompt.

## Config

Optional, at `~/.config/quill/config.json`:

```json
{
  "recordings_dir": "~/Recordings",
  "transcription": { "enabled": true, "engine": "parakeet" },
  "summarization": { "enabled": true, "template": "default",
                     "include_small_talk": false, "calendar_titles": false },
  "on_stop": "my-hook"
}
```

- `recordings_dir` — where sessions land. Resolution order: `--out` flag >
  config > `~/Recordings`.
- `transcription.enabled` — set `false` to just record.
- `summarization.enabled` — on-device notes after each transcript. Default
  `false`; needs macOS 26 with Apple Intelligence on.
- `summarization.template` — which template shapes the notes. See
  `quill templates`.
- `summarization.include_small_talk` — keep social chatter in the notes.
  Default `false`. Pre-meeting talk about weekends and holidays otherwise
  dominates a standup's notes.
- `summarization.calendar_titles` — title notes after the calendar event the
  recording overlaps, which is usually better than one the model invents.
  Default `false`, and deliberately so: enabling it prompts for access to every
  event in your calendar, a far broader grant than recording audio you started
  by hand. Denied access is not an error — the generated title stands.
- `mic_voice_processing` — Apple's echo cancellation on the mic (default off).
  Set `true` when recording meetings through the speakers, so playback doesn't
  bleed into the mic track and get transcribed twice as "me". The trade: while
  the voice unit is live, macOS ducks other playback slightly (`.min` ducking
  is configured, but it can't be zeroed). On headphones there's no echo to
  cancel, so raw capture is the better default.
- `on_stop` — shell command spawned with the session directory as its
  argument, once the session is **finished**: after the notes are written when
  summarization is on, after the transcript when it isn't, or right after
  recording when transcription is off too. Fires at most once per session even
  if a deferred summary means quill visits it again. Wire it to whatever comes
  next: filing, indexing, sending.

## CLI

```sh
quill                        # run the menu-bar daemon (^C to quit)
quill run --window           # ...and open the live transcript window
quill run --out <dir>        # custom recordings root (default ~/Recordings)
quill doctor                 # check permissions, recordings folder, models
quill templates              # list summary templates
quill templates --write      # write the built-ins out to edit
quill summarize <dir>        # (re)write notes for one session
quill summarize <dir> --template standup --print
quill install --launch-at-login
quill install --uninstall
```

## Stack

- **Swift** — single SPM executable target
- **Core Audio process tap** (`AudioHardwareCreateProcessTap`, macOS 14.2+) —
  system audio capture via a private aggregate device
- **AVAudioEngine** — mic capture
- **AVAudioFile** — streaming AAC encode into CAF
- **FluidAudio / Parakeet** — on-device Core ML transcription, offline plus
  sliding-window streaming for the live view
- **FoundationModels** — Apple's on-device model for notes (macOS 26+),
  guided generation for structure
- **NSStatusItem + SwiftUI** — menu bar, and an optional window hosted in an
  `NSHostingView` (no app bundle, so no SwiftUI `App` lifecycle)

## Gotchas

- A global tap records *everything* the Mac plays — notification dings,
  music, all of it. Don't play Spotify during meetings (or ask for a
  per-process picker if it bothers you).
- If the system track comes out silent, the permission is missing and nothing
  will have told you — see [System audio permission](#system-audio-permission).
  A `peak_level.system` of `0` in `meta.json` is the tell.
- Parakeet v2 is English-only. Other languages will come with the Whisper
  engine.
- The binary embeds its Info.plist (`__TEXT,__info_plist`) so TCC can
  attribute permissions to quill itself when running as a LaunchAgent.
- Notes need Apple Intelligence switched on, which is separate from having a
  supported Mac. `quill doctor` distinguishes the two.
- The on-device model is rate-limited for background processes on battery —
  which is what quill is when installed as a LaunchAgent. A deferred summary
  isn't lost; it's retried on the next drain or the next launch. Plug in if
  you want notes immediately.
- Notes are English-only, following Parakeet. An unsupported language records a
  permanent `summary.failed` and leaves the transcript untouched.
