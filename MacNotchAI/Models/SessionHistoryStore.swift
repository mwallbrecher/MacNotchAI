import Foundation
import Combine

// MARK: - Session history
//
// Remembers the last `maxSessions` sessions — the file(s) dropped plus the full
// AI conversation (every action/result turn). Surfaced as the "Recent Sessions"
// submenu in the menu-bar dropdown; clicking a row reopens the session.
//
// A "session" is one DROP. OverlayViewModel.setChips() calls beginSession() on
// every fresh drop, which arms a pending id. The record is only PERSISTED on the
// first recordTurn(), so a file that was dropped but never run never clutters the
// list. Adding files / running more actions within the same drop append to the
// same record.
//
// Persisted as JSON in Application Support (conversation text is far too large for
// UserDefaults). All access is @MainActor — the store is mutated from the overlay
// run-loop and read by the menu builder, both on the main thread.

/// One AI turn: the action that ran and the text it produced.
struct SessionTurn: Codable, Hashable {
    /// `AIAction` rawValue, so the action can be restored on reopen.
    let actionRaw: String
    /// Human-facing label: the typed question for a freeform query, otherwise the
    /// action's title. Shown if we ever surface a transcript.
    let promptTitle: String
    let resultText: String
    let date: Date
}

/// One session: the file(s) used and the conversation that happened over them.
struct SessionRecord: Codable, Identifiable, Hashable {
    let id: UUID
    var primaryPath: String
    var additionalPaths: [String]
    var turns: [SessionTurn]
    var updatedAt: Date

    var fileURL: URL { URL(fileURLWithPath: primaryPath) }
    var fileName: String { (primaryPath as NSString).lastPathComponent }

    /// The most recent turn — what gets shown when the session is reopened.
    var lastTurn: SessionTurn? { turns.last }
    /// The turn before the last, restored into the back-arrow cache (if any).
    var previousTurn: SessionTurn? { turns.count >= 2 ? turns[turns.count - 2] : nil }
}

@MainActor
final class SessionHistoryStore: ObservableObject {
    static let shared = SessionHistoryStore()

    /// Newest-first. Capped at `maxSessions`.
    @Published private(set) var sessions: [SessionRecord] = []

    // 25 (was 10) so the Search Sessions window has real depth to search.
    private let maxSessions = 25

    /// Sessions whose filename, prompts, or result text contain `query`
    /// (case-insensitive). Empty query → everything, newest first.
    func search(_ query: String) -> [SessionRecord] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return sessions }
        return sessions.filter { rec in
            if rec.fileName.localizedCaseInsensitiveContains(q) { return true }
            return rec.turns.contains {
                $0.promptTitle.localizedCaseInsensitiveContains(q) ||
                $0.resultText.localizedCaseInsensitiveContains(q)
            }
        }
    }

    /// Identity of the drop currently in progress. Armed by beginSession(); the
    /// record itself isn't created until the first turn is recorded.
    private var pendingSessionID: UUID?

    /// Exact identity currently receiving new turns. A normal fresh drop exposes
    /// its pending identity before it has a persisted record; an imported or resumed
    /// session points at the already-persisted record instead.
    var activeSessionID: UUID? { pendingSessionID }

    /// The exact active record, avoiding filename/path matching when the same file
    /// has been used in multiple sessions. `nil` is intentional for a normal pending
    /// drop until its first AI turn preserves the existing lazy-history behaviour.
    var activeSessionRecord: SessionRecord? {
        guard let id = pendingSessionID else { return nil }
        return sessions.first { $0.id == id }
    }

    private let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        let bundle = Bundle.main.bundleIdentifier ?? "com.wallbrecher.MacNotchAI"
        let dir = base.appendingPathComponent(bundle, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("session_history.json")
    }()

    private init() { load() }

    // MARK: - Lifecycle

    /// Begin a new session for a fresh drop. Arms a pending id; the record is
    /// created lazily on the first recordTurn() so unused drops don't persist.
    func beginSession(primary: URL) {
        pendingSessionID = UUID()
    }

    /// Continue an existing session (e.g. reopened from the menu) so any further
    /// turns append to it instead of spawning a duplicate record.
    func resumeSession(id: UUID) {
        pendingSessionID = sessions.contains { $0.id == id } ? id : nil
    }

    /// Persist an already-decoded shared transcript as exactly one local session and
    /// make it the active destination for later turns. Unlike `beginSession`, imports
    /// are intentionally eager: even a valid zero-turn snapshot must remain reopenable.
    ///
    /// `turns` is stored verbatim, so action values, prompts, results, dates, and order
    /// are not reconstructed or timestamped again. `updatedAt` is supplied by the
    /// bundle when available; otherwise the final original turn date (or now for an
    /// empty transcript) is used.
    @discardableResult
    func createImportedSession(primary: URL, additional: [URL] = [],
                               turns: [SessionTurn], updatedAt: Date? = nil) throws -> UUID {
        let id = UUID()
        let rec = SessionRecord(
            id: id,
            primaryPath: primary.path,
            additionalPaths: additional.map(\.path),
            turns: turns,
            updatedAt: updatedAt ?? turns.last?.date ?? Date())

        var committedSessions = sessions.filter { $0.id != id }
        committedSessions.insert(rec, at: 0)
        if committedSessions.count > maxSessions {
            committedSessions.removeLast(committedSessions.count - maxSessions)
        }

        // Imported files become retention-protected only after this durable write succeeds. Do not
        // publish the in-memory identity first: a swallowed disk error would release the file lease
        // while Recent Sessions could not restore it after relaunch.
        try write(committedSessions)
        sessions = committedSessions
        pendingSessionID = id
        return id
    }

    /// Append a turn to the current session, creating the record if this is the
    /// first turn of the drop. Moves the session to the front, trims, and saves.
    func recordTurn(primary: URL, additional: [URL],
                    action: AIAction, prompt: String?, result: String) {
        let id = pendingSessionID ?? UUID()
        pendingSessionID = id

        let turn = SessionTurn(
            actionRaw: action.rawValue,
            promptTitle: (prompt?.isEmpty == false) ? prompt! : action.rawValue,
            resultText: result,
            date: Date())

        if let idx = sessions.firstIndex(where: { $0.id == id }) {
            var rec = sessions.remove(at: idx)
            rec.primaryPath = primary.path
            rec.additionalPaths = additional.map(\.path)
            rec.turns.append(turn)
            rec.updatedAt = turn.date
            sessions.insert(rec, at: 0)
        } else {
            let rec = SessionRecord(
                id: id,
                primaryPath: primary.path,
                additionalPaths: additional.map(\.path),
                turns: [turn],
                updatedAt: turn.date)
            sessions.insert(rec, at: 0)
        }

        trimAndSave()
    }

    /// Replace only the answer of the active record's last turn. Regenerate changes the assistant
    /// reply already visible on screen; keeping the original prompt/action preserves turn identity
    /// while ensuring reopen and Session Sharing receive the exact replacement rather than stale
    /// history. Path matching is deliberately avoided because one file may back many sessions.
    func replaceActiveLastTurnResult(_ result: String, at date: Date = Date()) {
        guard let id = pendingSessionID,
              let sessionIndex = sessions.firstIndex(where: { $0.id == id }),
              let previous = sessions[sessionIndex].turns.last else { return }

        var record = sessions.remove(at: sessionIndex)
        record.turns[record.turns.count - 1] = SessionTurn(
            actionRaw: previous.actionRaw,
            promptTitle: previous.promptTitle,
            resultText: result,
            date: date
        )
        record.updatedAt = date
        sessions.insert(record, at: 0)
        trimAndSave()
    }

    /// Keep the active record's paths fresh after a rename/move (best-effort).
    func remapPath(from old: URL, to new: URL) {
        guard let id = pendingSessionID,
              let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        var rec = sessions[idx]
        if rec.primaryPath == old.path { rec.primaryPath = new.path }
        rec.additionalPaths = rec.additionalPaths.map { $0 == old.path ? new.path : $0 }
        sessions[idx] = rec
        save()
    }

    /// Keep the exact active file set aligned with the live session after the user
    /// removes one file. A still-pending session has no durable record yet, so there
    /// is intentionally nothing to write in that case.
    func replaceActivePaths(primary: URL, additional: [URL]) {
        guard let id = pendingSessionID,
              let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        var rec = sessions[idx]
        rec.primaryPath = primary.path
        rec.additionalPaths = additional.map(\.path)
        sessions[idx] = rec
        save()
    }

    // MARK: - Mutation

    func remove(id: UUID) {
        sessions.removeAll { $0.id == id }
        if pendingSessionID == id { pendingSessionID = nil }
        save()
    }

    func clear() {
        sessions.removeAll()
        pendingSessionID = nil
        save()
    }

    func record(for id: UUID) -> SessionRecord? { sessions.first { $0.id == id } }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let decoded = try? JSONDecoder().decode([SessionRecord].self, from: data) {
            sessions = Array(decoded.prefix(maxSessions))
        }
    }

    private func save() {
        try? write(sessions)
    }

    private func write(_ records: [SessionRecord]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        let data = try encoder.encode(records)
        try data.write(to: fileURL, options: .atomic)
    }

    private func trimAndSave() {
        if sessions.count > maxSessions { sessions.removeLast(sessions.count - maxSessions) }
        save()
    }
}
