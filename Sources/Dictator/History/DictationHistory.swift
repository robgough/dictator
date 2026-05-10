import Foundation
import Observation

@MainActor
@Observable
final class DictationHistory {
    static let shared = DictationHistory()

    /// Newest first.
    private(set) var records: [DictationRecord] = []

    private static let maxAgeDays = 7
    private static let maxEntries = 500

    private static var storeURL: URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("Dictator", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }

    private init() {
        load()
        prune()
    }

    func append(_ record: DictationRecord) {
        records.insert(record, at: 0)
        prune()
        persist()
    }

    func remove(id: UUID) {
        records.removeAll(where: { $0.id == id })
        persist()
    }

    func clear() {
        records.removeAll()
        persist()
    }

    /// Most recent N records (used by the menu bar).
    func mostRecent(_ count: Int) -> [DictationRecord] {
        Array(records.prefix(count))
    }

    // MARK: - Pruning + persistence

    private func prune() {
        let cutoff = Calendar.current.date(byAdding: .day, value: -Self.maxAgeDays, to: Date()) ?? Date.distantPast
        records.removeAll { $0.timestamp < cutoff }
        if records.count > Self.maxEntries {
            records = Array(records.prefix(Self.maxEntries))
        }
    }

    private func load() {
        guard
            let data = try? Data(contentsOf: Self.storeURL),
            let decoded = try? JSONDecoder.iso8601.decode([DictationRecord].self, from: data)
        else { return }
        records = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder.iso8601.encode(records) else { return }
        try? data.write(to: Self.storeURL, options: .atomic)
    }
}

private extension JSONDecoder {
    static let iso8601: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

private extension JSONEncoder {
    static let iso8601: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
}
