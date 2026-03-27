import Foundation

struct HistoryEntry: Codable, Identifiable, Equatable {
    var id: String { url }
    let url: String
    let title: String
    let repo: String      // "owner/repo"
    let number: Int
    let lastOpened: Date
}

@Observable
@MainActor
final class HistoryManager {
    private static let storageKey = "parley.history"
    private static let maxEntries = 20

    var entries: [HistoryEntry] = []

    init() {
        load()
    }

    func recordVisit(url: String, title: String, owner: String, repo: String, number: Int) {
        // Remove existing entry for same URL
        entries.removeAll { $0.url == url }

        // Prepend new entry
        let entry = HistoryEntry(
            url: url,
            title: title,
            repo: "\(owner)/\(repo)",
            number: number,
            lastOpened: Date()
        )
        entries.insert(entry, at: 0)

        // Cap at max
        if entries.count > Self.maxEntries {
            entries = Array(entries.prefix(Self.maxEntries))
        }

        save()
    }

    func removeEntry(url: String) {
        entries.removeAll { $0.url == url }
        save()
    }

    func clearAll() {
        entries.removeAll()
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey) else { return }
        entries = (try? JSONDecoder().decode([HistoryEntry].self, from: data)) ?? []
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
