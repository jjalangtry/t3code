import Foundation

struct SnapshotCacheStore {
    private let key: String

    init(key: String = "t3code_snapshot_cache") {
        self.key = key
    }

    func save(_ snapshot: OrchestrationReadModel) {
        guard let data = try? JSONEncoder().encode(snapshot),
              let payload = String(data: data, encoding: .utf8) else {
            return
        }
        UserDefaults.standard.set(payload, forKey: key)
    }

    func load() -> OrchestrationReadModel? {
        guard let payload = UserDefaults.standard.string(forKey: key),
              let data = payload.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(OrchestrationReadModel.self, from: data)
    }
}
