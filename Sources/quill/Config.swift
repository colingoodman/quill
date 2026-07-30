import Foundation

/// Optional user config at ~/.config/quill/config.json:
///
///     {
///       "recordings_dir": "~/Recordings",
///       "transcription": { "enabled": true, "engine": "parakeet" },
///       "summarization": { "enabled": true, "template": "default" },
///       "mic_voice_processing": true,
///       "on_stop": "my-hook"
///     }
///
/// Resolution order for the recordings root: --out flag > config file >
/// ~/Recordings. `on_stop` is a shell command spawned with the session
/// directory as its argument once the session is finished — after the notes
/// when summarization is on, after the transcript when it is not, or right
/// after recording when transcription is disabled. At most once per session.
enum Config {
    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/quill/config.json")

    static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Recordings", isDirectory: true)

    /// The configured recordings root, or nil if no config file / no key.
    static func recordingsDir() -> URL? {
        guard let dir = load()?["recordings_dir"] as? String, !dir.isEmpty else { return nil }
        return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Shell command to spawn once a session is finished, or nil.
    static func onStop() -> String? {
        guard let cmd = load()?["on_stop"] as? String, !cmd.isEmpty else { return nil }
        return cmd
    }

    /// Whether finished recordings are transcribed automatically. Default on.
    static func transcriptionEnabled() -> Bool {
        transcription()?["enabled"] as? Bool ?? true
    }

    /// Configured engine name. Only "parakeet" ships today; the coordinator
    /// warns and falls back for anything else.
    static func transcriptionEngine() -> String {
        transcription()?["engine"] as? String ?? "parakeet"
    }

    private static func transcription() -> [String: Any]? {
        load()?["transcription"] as? [String: Any]
    }

    /// Whether finished transcripts are summarized into Granola-style notes.
    /// Default off: it needs macOS 26 with Apple Intelligence enabled, and a
    /// feature that silently does nothing is worse than one you switch on.
    static func summarizationEnabled() -> Bool {
        summarization()?["enabled"] as? Bool ?? false
    }

    /// Template name resolved against ~/.config/quill/templates/<name>.md, then
    /// the builtins. Its headings are the sections the model fills.
    static func summarizationTemplate() -> String {
        summarization()?["template"] as? String ?? Template.fallbackName
    }

    /// Whether to title notes from the overlapping calendar event. Default off:
    /// switching it on prompts for access to every event in the calendar, which
    /// is a far broader grant than recording audio the user started by hand.
    static func calendarTitles() -> Bool {
        summarization()?["calendar_titles"] as? Bool ?? false
    }

    /// Keep social chatter in the notes. Default off.
    ///
    /// Pre-meeting talk about weekends and holidays is not what a standup is
    /// for, and left in it dominates: a colleague's holiday became a whole
    /// section and the lead item in the title. Set true to keep everything.
    static func includeSmallTalk() -> Bool {
        summarization()?["include_small_talk"] as? Bool ?? false
    }

    private static func summarization() -> [String: Any]? {
        load()?["summarization"] as? [String: Any]
    }

    /// Apple voice processing (acoustic echo cancellation) on the mic, so
    /// speaker playback doesn't bleed into the mic track and get transcribed
    /// as "me". Default off — the live voice unit ducks all other playback,
    /// and on headphones there's no echo to cancel anyway. Set true when
    /// recording meetings through the speakers.
    static func micVoiceProcessing() -> Bool {
        load()?["mic_voice_processing"] as? Bool ?? false
    }

    /// Parse the config file. A malformed config is reported on stderr rather
    /// than silently ignored — recordings landing in an unexpected place is
    /// worse than a warning.
    private static func load() -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        guard
            let data = try? Data(contentsOf: path),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            FileHandle.standardError.write(Data(
                "warning: \(path.path) is not valid JSON — ignoring config\n".utf8
            ))
            return nil
        }
        return json
    }

    /// Resolve the recordings root from an optional CLI override.
    static func resolveRoot(cliOverride: String?) -> URL {
        if let cliOverride {
            return URL(
                fileURLWithPath: (cliOverride as NSString).expandingTildeInPath,
                isDirectory: true
            )
        }
        return recordingsDir() ?? defaultRoot
    }
}
