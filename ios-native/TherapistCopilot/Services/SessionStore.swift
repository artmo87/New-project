import Foundation
import Observation
import UIKit

// MARK: - Aggregate types used by Home / Prepare

/// An action item that is not done yet, together with the session it belongs to.
struct OpenActionItem: Identifiable, Hashable {
    var id: UUID { item.id }
    var sessionID: UUID
    var sessionTitle: String
    var sessionDate: Date
    var item: ActionItem
}

/// A question the user wants to bring to the next session.
struct PendingQuestion: Identifiable, Hashable {
    var id: String { sessionID.uuidString + "|" + question }
    var sessionID: UUID
    var sessionTitle: String
    var question: String
}

/// A theme that has come up in at least two sessions.
struct RecurringTheme: Identifiable, Hashable {
    var id: String { name }
    var name: String
    var sessionCount: Int
}

// MARK: - On-disk format

/// The single JSON document that holds everything except audio.
private struct StoreFile: Codable {
    var version: Int
    var sessions: [TherapySession]
    var journal: [JournalEntry]
}

private enum StoreLayout {
    static let version = 1
    static let fileName = "therapist-copilot-store.json"
    static let corruptFilePrefix = "therapist-copilot-store.corrupt-"
    static let recordingsFolderName = "Recordings"
}

// MARK: - Store

/// Owns every session and journal entry, persists them to one JSON file in the app's
/// Documents directory and manages the audio files next to it. Nothing here ever touches
/// the network.
@MainActor
@Observable
final class SessionStore {

    /// Newest first. Mutate only through the methods below.
    private(set) var sessions: [TherapySession] = []
    /// Newest first.
    private(set) var journal: [JournalEntry] = []
    /// A plain-language problem with reading or writing the store, for the UI to show. nil when all is well.
    private(set) var loadError: String? = nil

    /// True when the store file exists but could not be read (for example because the data
    /// was still protected). While set, nothing is written to disk so the existing file is
    /// never overwritten with an empty store.
    @ObservationIgnored private var needsReload = false
    /// True when `loadError` describes a passing problem that a later successful save may clear.
    @ObservationIgnored private var errorIsTransient = false

    /// Loads synchronously from disk.
    init() {
        load()
        observeProtectedDataAvailability()
    }

    // MARK: - Sessions

    /// Inserts the session (replacing any session with the same id), re-sorts newest first and saves.
    func add(_ session: TherapySession) {
        sessions.removeAll { $0.id == session.id }
        sessions.append(session)
        sortSessions()
        save()
    }

    /// Replaces the stored session with the same id (adds it if missing) and saves.
    func update(_ session: TherapySession) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
        sortSessions()
        save()
    }

    /// Edits a stored session in place and saves. Does nothing if the id is unknown.
    func modify(_ id: UUID, _ change: (inout TherapySession) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        var edited = sessions[index]
        change(&edited)
        edited.id = id
        sessions[index] = edited
        sortSessions()
        save()
    }

    /// Removes the session, deletes its audio file and saves.
    func delete(_ session: TherapySession) {
        if let stored = sessions.first(where: { $0.id == session.id }) {
            removeRecordingFile(named: stored.audioFileName)
        }
        removeRecordingFile(named: session.audioFileName)
        sessions.removeAll { $0.id == session.id }
        save()
    }

    func session(id: UUID) -> TherapySession? {
        sessions.first { $0.id == id }
    }

    // MARK: - Journal

    func addJournalEntry(_ entry: JournalEntry) {
        journal.removeAll { $0.id == entry.id }
        journal.append(entry)
        sortJournal()
        save()
    }

    func updateJournalEntry(_ entry: JournalEntry) {
        if let index = journal.firstIndex(where: { $0.id == entry.id }) {
            journal[index] = entry
        } else {
            journal.append(entry)
        }
        sortJournal()
        save()
    }

    func deleteJournalEntry(_ entry: JournalEntry) {
        let countBefore = journal.count
        journal.removeAll { $0.id == entry.id }
        if journal.count != countBefore {
            save()
        }
    }

    // MARK: - Danger zone

    /// Removes every session, journal entry, audio file and backup copy of the store.
    func deleteAllData() {
        sessions.removeAll()
        journal.removeAll()
        removeAllRecordings()
        removeCorruptBackups()

        let fileManager = FileManager.default
        let storeURL = SessionStore.storeURL
        if fileManager.fileExists(atPath: storeURL.path) {
            try? fileManager.removeItem(at: storeURL)
        }
        needsReload = false
        errorIsTransient = false
        loadError = nil
        save()
    }

    // MARK: - Files

    /// The app's Documents directory.
    nonisolated static var documentsDirectory: URL {
        if let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            return url
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Documents", isDirectory: true)
    }

    /// Documents/Recordings, created on first access.
    nonisolated static var recordingsDirectory: URL {
        let url = documentsDirectory.appendingPathComponent(StoreLayout.recordingsFolderName, isDirectory: true)
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)

        if exists && !isDirectory.boolValue {
            try? fileManager.removeItem(at: url)
        }
        if !exists || !isDirectory.boolValue {
            // CONTRACT NOTE: the directory uses .completeUnlessOpen rather than .complete so a
            // recording that is already open keeps writing while the iPhone is locked (the app
            // records in the background); files are still encrypted at rest.
            let attributes: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUnlessOpen]
            do {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: attributes)
            } catch {
                try? fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
            }
            try? fileManager.setAttributes(attributes, ofItemAtPath: url.path)
        }
        return url
    }

    /// recordingsDirectory/<uuid>.m4a
    func newAudioURL(for sessionID: UUID) -> URL {
        SessionStore.recordingsDirectory.appendingPathComponent(sessionID.uuidString + ".m4a", isDirectory: false)
    }

    /// nil when the session has no audio file name or the file is missing.
    func audioURL(for session: TherapySession) -> URL? {
        guard let url = recordingURL(named: session.audioFileName) else { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Removes the audio file, clears `audioFileName` on the stored session and saves.
    func deleteAudio(for session: TherapySession) {
        removeRecordingFile(named: session.audioFileName)
        if let stored = sessions.first(where: { $0.id == session.id }) {
            if stored.audioFileName != session.audioFileName {
                removeRecordingFile(named: stored.audioFileName)
            }
            modify(session.id) { $0.audioFileName = nil }
        }
    }

    /// Size of the session's audio file in bytes, nil when there is none.
    func audioFileSize(for session: TherapySession) -> Int64? {
        guard let url = audioURL(for: session) else { return nil }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        guard let size = attributes[.size] as? NSNumber else { return nil }
        return size.int64Value
    }

    // MARK: - Aggregates

    /// Every action item that is not done, newest session first.
    var openActionItems: [OpenActionItem] {
        var result: [OpenActionItem] = []
        for session in sessions {
            for item in session.actionItems where !item.isDone {
                result.append(OpenActionItem(
                    sessionID: session.id,
                    sessionTitle: session.displayTitle,
                    sessionDate: session.createdAt,
                    item: item
                ))
            }
        }
        return result
    }

    /// Questions saved for the next session, newest session first.
    var pendingQuestions: [PendingQuestion] {
        var result: [PendingQuestion] = []
        for session in sessions {
            var seen = Set<String>()
            for raw in session.nextSessionQuestions {
                let question = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if question.isEmpty || seen.contains(question) { continue }
                seen.insert(question)
                result.append(PendingQuestion(
                    sessionID: session.id,
                    sessionTitle: session.displayTitle,
                    question: question
                ))
            }
        }
        return result
    }

    /// Themes that appear in at least two sessions, most frequent first.
    var recurringThemes: [RecurringTheme] {
        var counts: [String: Int] = [:]
        var displayNames: [String: String] = [:]
        for session in sessions {
            guard let insights = session.insights else { continue }
            var namesInSession = Set<String>()
            for theme in insights.themes {
                let name = theme.name.trimmingCharacters(in: .whitespacesAndNewlines)
                if name.isEmpty { continue }
                let key = name.lowercased()
                if namesInSession.contains(key) { continue }
                namesInSession.insert(key)
                counts[key, default: 0] += 1
                if displayNames[key] == nil {
                    displayNames[key] = name
                }
            }
        }
        return counts
            .filter { $0.value >= 2 }
            .map { RecurringTheme(name: displayNames[$0.key] ?? $0.key, sessionCount: $0.value) }
            .sorted { lhs, rhs in
                if lhs.sessionCount != rhs.sessionCount {
                    return lhs.sessionCount > rhs.sessionCount
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    func setActionItemDone(sessionID: UUID, itemID: UUID, isDone: Bool) {
        modify(sessionID) { session in
            if let index = session.actionItems.firstIndex(where: { $0.id == itemID }) {
                session.actionItems[index].isDone = isDone
            }
        }
    }

    func removeQuestion(sessionID: UUID, question: String) {
        let target = question.trimmingCharacters(in: .whitespacesAndNewlines)
        modify(sessionID) { session in
            session.nextSessionQuestions.removeAll {
                $0.trimmingCharacters(in: .whitespacesAndNewlines) == target
            }
        }
    }

    // MARK: - Sorting

    private func sortSessions() {
        sessions.sort { $0.createdAt > $1.createdAt }
    }

    private func sortJournal() {
        journal.sort { $0.createdAt > $1.createdAt }
    }

    // MARK: - Persistence

    private nonisolated static var storeURL: URL {
        documentsDirectory.appendingPathComponent(StoreLayout.fileName, isDirectory: false)
    }

    private nonisolated static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private nonisolated static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private func load() {
        let url = SessionStore.storeURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            needsReload = false
            return
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            needsReload = true
            errorIsTransient = true
            loadError = "Your saved sessions couldn't be opened just now (\(error.localizedDescription)). They are still on this iPhone and the app will try again shortly."
            return
        }

        do {
            let decoded = try SessionStore.makeDecoder().decode(StoreFile.self, from: data)
            sessions = decoded.sessions
            journal = decoded.journal
            sortSessions()
            sortJournal()
            needsReload = false
            errorIsTransient = false
            loadError = nil
        } catch {
            needsReload = false
            errorIsTransient = false
            loadError = SessionStore.corruptFileMessage(backupName: SessionStore.backUpUnreadableFile(at: url))
        }
    }

    /// Retries a load that failed because the file could not be read. Anything created in the
    /// meantime is kept and merged with what the file contains.
    private func reloadIfNeeded() {
        guard needsReload else { return }
        let url = SessionStore.storeURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            needsReload = false
            errorIsTransient = false
            loadError = nil
            return
        }
        guard let data = try? Data(contentsOf: url) else { return }

        do {
            let decoded = try SessionStore.makeDecoder().decode(StoreFile.self, from: data)

            var mergedSessions = decoded.sessions
            let knownSessionIDs = Set(mergedSessions.map { $0.id })
            mergedSessions.append(contentsOf: sessions.filter { !knownSessionIDs.contains($0.id) })
            sessions = mergedSessions

            var mergedJournal = decoded.journal
            let knownEntryIDs = Set(mergedJournal.map { $0.id })
            mergedJournal.append(contentsOf: journal.filter { !knownEntryIDs.contains($0.id) })
            journal = mergedJournal

            sortSessions()
            sortJournal()
            needsReload = false
            errorIsTransient = false
            loadError = nil
        } catch {
            needsReload = false
            errorIsTransient = false
            loadError = SessionStore.corruptFileMessage(backupName: SessionStore.backUpUnreadableFile(at: url))
        }
    }

    private func save() {
        reloadIfNeeded()
        if needsReload {
            errorIsTransient = true
            loadError = "Your earlier sessions couldn't be opened yet, so this change is kept in the app for now and will be saved as soon as they can be read."
            return
        }

        let file = StoreFile(version: StoreLayout.version, sessions: sessions, journal: journal)
        do {
            let data = try SessionStore.makeEncoder().encode(file)
            try data.write(to: SessionStore.storeURL, options: [.atomic, .completeFileProtection])
            if errorIsTransient {
                errorIsTransient = false
                loadError = nil
            }
        } catch {
            errorIsTransient = true
            loadError = "Your latest change couldn't be saved (\(error.localizedDescription)). It stays in the app for now; freeing up a little space on your iPhone may help."
        }
    }

    /// Called when protected data becomes readable again; completes any load that had to wait.
    private func recoverIfNeeded() {
        guard needsReload else { return }
        reloadIfNeeded()
        if !needsReload {
            save()
        }
    }

    private func observeProtectedDataAvailability() {
        _ = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.recoverIfNeeded()
            }
        }
    }

    /// Moves an unreadable store file aside as `therapist-copilot-store.corrupt-<timestamp>.json`.
    /// Returns the backup's file name, or nil if the file could not be moved.
    private nonisolated static func backUpUnreadableFile(at url: URL) -> String? {
        let fileManager = FileManager.default
        let timestamp = Int(Date().timeIntervalSince1970)
        let backupName = StoreLayout.corruptFilePrefix + String(timestamp) + ".json"
        let backupURL = documentsDirectory.appendingPathComponent(backupName, isDirectory: false)
        if fileManager.fileExists(atPath: backupURL.path) {
            try? fileManager.removeItem(at: backupURL)
        }
        do {
            try fileManager.moveItem(at: url, to: backupURL)
            return backupName
        } catch {
            return nil
        }
    }

    private nonisolated static func corruptFileMessage(backupName: String?) -> String {
        if let backupName = backupName {
            return "Your saved sessions couldn't be read, so the app is starting with an empty list. The unreadable file was kept as “\(backupName)” in the app's Documents folder in case it can be recovered."
        }
        return "Your saved sessions couldn't be read, so the app is starting with an empty list."
    }

    // MARK: - Audio file helpers

    private func recordingURL(named fileName: String?) -> URL? {
        guard let fileName = fileName?.trimmingCharacters(in: .whitespacesAndNewlines), !fileName.isEmpty else {
            return nil
        }
        let safeName = URL(fileURLWithPath: fileName).lastPathComponent
        guard !safeName.isEmpty, safeName != ".", safeName != ".." else { return nil }
        return SessionStore.recordingsDirectory.appendingPathComponent(safeName, isDirectory: false)
    }

    private func removeRecordingFile(named fileName: String?) {
        guard let url = recordingURL(named: fileName) else { return }
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) {
            try? fileManager.removeItem(at: url)
        }
    }

    private func removeAllRecordings() {
        let fileManager = FileManager.default
        let directory = SessionStore.recordingsDirectory
        guard let contents = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: []) else {
            return
        }
        for url in contents {
            try? fileManager.removeItem(at: url)
        }
    }

    private func removeCorruptBackups() {
        let fileManager = FileManager.default
        let directory = SessionStore.documentsDirectory
        guard let contents = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: []) else {
            return
        }
        for url in contents where url.lastPathComponent.hasPrefix(StoreLayout.corruptFilePrefix) {
            try? fileManager.removeItem(at: url)
        }
    }
}
