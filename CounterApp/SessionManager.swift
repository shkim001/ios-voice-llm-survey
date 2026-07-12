import Foundation

final class SessionManager {
    static let shared = SessionManager()

    struct Session {
        let id: String
        let directoryURL: URL
        let createdAt: Date
    }

    private init() {}

    private let sessionsFolderName = "SurveySessions"
    private let metadataFileName = "metadata.json"

    private(set) var currentSession: Session?

    func startNewSession(now: Date = Date()) throws -> Session {
        let id = UUID().uuidString
        let sessionsRoot = try sessionsRootDirectory()
        let sessionDir = sessionsRoot.appendingPathComponent(id, isDirectory: true)

        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true, attributes: nil)

        let session = Session(id: id, directoryURL: sessionDir, createdAt: now)
        currentSession = session

        try writeMetadata(for: session)
        return session
    }

    func ensureCurrentSession() throws -> Session {
        if let currentSession { return currentSession }
        return try startNewSession()
    }

    func clearCurrentSessionIfEmpty() {
        guard let currentSession else { return }
        _ = removeSessionIfEmpty(currentSession.directoryURL)
        self.currentSession = nil
    }

    @discardableResult
    func purgeEmptySessions() -> Int {
        do {
            let root = try sessionsRootDirectory()
            let fm = FileManager.default
            let dirURLs = (try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []

            var deletedCount = 0
            for url in dirURLs where removeSessionIfEmpty(url) {
                deletedCount += 1
                if currentSession?.directoryURL == url {
                    currentSession = nil
                }
            }
            return deletedCount
        } catch {
            return 0
        }
    }

    func makeRecordingURL(fileExtension: String = "m4a", now: Date = Date()) throws -> URL {
        let session = try ensureCurrentSession()
        let timestamp = String(format: "%.0f", now.timeIntervalSince1970)
        let filename = "recording_\(timestamp).\(fileExtension)"
        return session.directoryURL.appendingPathComponent(filename)
    }

    func purgeOldSessions(keepLast: Int = 50, maxAgeDays: Int = 7, now: Date = Date()) {
        do {
            let root = try sessionsRootDirectory()
            let fm = FileManager.default

            let dirURLs = (try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            // Sort newest first so we can keep N newest
            let sorted = dirURLs.sorted { a, b in
                let ad = (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let bd = (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return ad > bd
            }

            let keepSet = Set(sorted.prefix(max(0, keepLast)))
            let maxAgeSeconds = Double(maxAgeDays) * 24 * 60 * 60

            for url in sorted {
                guard !keepSet.contains(url) else { continue }

                let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ??
                              (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ??
                              .distantPast
                let age = now.timeIntervalSince(created)
                if age > maxAgeSeconds {
                    try? fm.removeItem(at: url)
                }
            }
        } catch {
            // Best-effort purge; ignore errors.
        }
    }

    // MARK: - Internals

    private func sessionsRootDirectory() throws -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let root = documents.appendingPathComponent(sessionsFolderName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: nil)
        }
        return root
    }

    private func writeMetadata(for session: Session) throws {
        let dict: [String: Any] = [
            "session_id": session.id,
            "created_at_epoch": session.createdAt.timeIntervalSince1970
        ]
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        let url = session.directoryURL.appendingPathComponent(metadataFileName)
        try data.write(to: url, options: [.atomic])
    }

    private func removeSessionIfEmpty(_ sessionURL: URL) -> Bool {
        let fm = FileManager.default
        guard (try? sessionURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            return false
        }

        let fileURLs = (try? fm.contentsOfDirectory(
            at: sessionURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        let hasRecording = fileURLs.contains { $0.pathExtension.lowercased() == "m4a" }
        let hasSessionPackage = fileURLs.contains { $0.lastPathComponent == "session.json" }
        guard !hasRecording && !hasSessionPackage else { return false }

        do {
            try fm.removeItem(at: sessionURL)
            return true
        } catch {
            return false
        }
    }
}
