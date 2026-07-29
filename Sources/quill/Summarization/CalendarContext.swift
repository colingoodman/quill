import EventKit
import Foundation

/// The meeting's name, borrowed from the calendar.
///
/// Granola reads the calendar event alongside the transcript, and the human's
/// own name for a meeting is almost always better than one a 3B model invents
/// from its content. This is the cheap half of that.
///
/// Strictly opt-in (`summarization.calendar_titles`), and default off, because
/// switching it on prompts for access to every event in the user's calendar —
/// a much broader grant than recording audio the user explicitly started. A
/// denial is not an error: the model-generated title is a perfectly good
/// fallback, so every failure path here returns nil quietly.
enum CalendarContext {
    /// Title of the calendar event that best overlaps the session, if any.
    static func title(from start: Date, to end: Date, log: (String) -> Void) async -> String? {
        guard await requestAccess(log: log) else { return nil }

        let store = EKEventStore()
        // Widen slightly: recording usually starts a moment after the event.
        let predicate = store.predicateForEvents(
            withStart: start.addingTimeInterval(-15 * 60),
            end: end.addingTimeInterval(15 * 60),
            calendars: nil
        )
        let events = store.events(matching: predicate).filter { !$0.isAllDay }
        guard !events.isEmpty else {
            log("calendar: no event overlaps this session")
            return nil
        }

        // Most-overlapping wins: back-to-back meetings both fall inside the
        // widened window, and the one sharing the most time with the recording
        // is the one that was recorded.
        let best = events.max { a, b in
            overlap(a, start, end) < overlap(b, start, end)
        }
        guard let best, overlap(best, start, end) > 0 else {
            log("calendar: no event shares time with this session")
            return nil
        }
        let title = best.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let title, !title.isEmpty else { return nil }
        log("calendar: titled from event \"\(title)\"")
        return title
    }

    private static func overlap(_ event: EKEvent, _ start: Date, _ end: Date) -> TimeInterval {
        guard let eventStart = event.startDate, let eventEnd = event.endDate else { return 0 }
        return max(0, min(eventEnd, end).timeIntervalSince(max(eventStart, start)))
    }

    private static func requestAccess(log: (String) -> Void) async -> Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            return true
        case .notDetermined:
            do {
                return try await EKEventStore().requestFullAccessToEvents()
            } catch {
                log("calendar: access request failed: \(error)")
                return false
            }
        case .denied, .restricted, .writeOnly:
            log("calendar: access not granted — keeping the generated title")
            return false
        @unknown default:
            return false
        }
    }
}
