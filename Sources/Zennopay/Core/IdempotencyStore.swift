import Foundation

/// A durable record of an in-flight (or completed) confirm attempt.
///
/// Persisted to disk BEFORE the `/confirm` call (design doc T-CONFIRM-DURABILITY
/// / D5). On relaunch the SDK looks for a record matching the intent; if one
/// exists it re-`GET /:id` to recover the real terminal status instead of
/// re-confirming, and any retry reuses the same idempotency key so the backend
/// deduplicates the money movement.
struct ConfirmRecord: Codable, Equatable {
    let intentID: String
    let idempotencyKey: String
    /// When the record was written, for TTL-based cleanup of stale records.
    let createdAt: Date
}

/// Persists `ConfirmRecord`s to disk. Backed by a JSON file in Application
/// Support by default; the storage directory is injectable for tests.
///
/// The store is keyed by `intentID` (one confirm per intent), so writing a
/// record for an intent that already has one returns the EXISTING record —
/// guaranteeing key stability across retries and relaunches.
final class IdempotencyStore {

    private let fileURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    /// - Parameter directory: where to keep the store file. Defaults to the
    ///   app's Application Support directory (persists across launches, not
    ///   backed up to iCloud by convention, survives app updates).
    init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let dir: URL
        if let directory {
            dir = directory
        } else {
            let base = (try? fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )) ?? fileManager.temporaryDirectory
            dir = base.appendingPathComponent("Zennopay", isDirectory: true)
        }
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("confirm-records.json")
    }

    /// Return the persisted record for `intentID`, if any.
    func record(for intentID: String) -> ConfirmRecord? {
        lock.lock(); defer { lock.unlock() }
        return load()[intentID]
    }

    /// Ensure a record exists for `intentID`, persisting it synchronously
    /// BEFORE the caller makes the confirm request. If a record already
    /// exists, it is returned unchanged (stable key on retry / relaunch).
    ///
    /// - Parameter makeKey: factory for a fresh idempotency key when none
    ///   exists yet. Injectable so tests can assert a deterministic key.
    /// - Returns: the record whose `idempotencyKey` the caller must send.
    @discardableResult
    func persistIfNeeded(
        intentID: String,
        makeKey: () -> String = { UUID().uuidString },
        now: Date = Date()
    ) -> ConfirmRecord {
        lock.lock(); defer { lock.unlock() }
        var all = load()
        if let existing = all[intentID] {
            return existing
        }
        let record = ConfirmRecord(
            intentID: intentID,
            idempotencyKey: makeKey(),
            createdAt: now
        )
        all[intentID] = record
        save(all)
        return record
    }

    /// Remove the record for `intentID` (call once a terminal result is
    /// delivered, so the store doesn't grow unbounded).
    func clear(intentID: String) {
        lock.lock(); defer { lock.unlock() }
        var all = load()
        all.removeValue(forKey: intentID)
        save(all)
    }

    // MARK: - Disk I/O

    private func load() -> [String: ConfirmRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: ConfirmRecord].self, from: data)) ?? [:]
    }

    private func save(_ records: [String: ConfirmRecord]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(records) else { return }
        // Atomic write so a crash mid-write can't corrupt the store.
        try? data.write(to: fileURL, options: .atomic)
    }
}
