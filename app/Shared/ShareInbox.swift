import Foundation

/// Files handed over from the Share Extension to the main app live in the
/// App Group container. The extension only stages bytes and a manifest; the
/// app owns the cold-start, session picker and delivery to DSH.
enum ShareInbox {
    static let appGroup = "group.com.brooks.idsh"
    static let rootName = "share-inbox"

    struct Item: Codable, Identifiable, Hashable {
        var id: String { relativePath }
        let relativePath: String
        let name: String
        let type: String
        let size: Int64
    }

    struct Batch: Codable, Identifiable, Hashable {
        let id: String
        let createdAt: Date
        var sourceApp: String?
        var items: [Item]
        var status: String   // pending | delivered | failed
    }

    static var containerURL: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroup
        )
    }

    static var rootURL: URL? {
        containerURL?.appendingPathComponent(rootName, isDirectory: true)
    }

    static func ensureRoot() throws -> URL {
        guard let root = rootURL else {
            throw NSError(domain: "idsh.share", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "App Group 不可用"])
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func batchURL(_ id: String) -> URL? {
        rootURL?.appendingPathComponent(id, isDirectory: true)
    }

    static func loadBatches() -> [Batch] {
        guard let root = rootURL,
              let dirs = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil
              ) else { return [] }
        var out: [Batch] = []
        for dir in dirs where dir.hasDirectoryPath {
            let manifest = dir.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifest),
                  let batch = try? JSONDecoder.share.decode(Batch.self, from: data)
            else { continue }
            out.append(batch)
        }
        return out.sorted { $0.createdAt > $1.createdAt }
    }

    static func save(_ batch: Batch) throws {
        guard let dir = batchURL(batch.id) else { return }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder.share.encode(batch)
        try data.write(to: dir.appendingPathComponent("manifest.json"), options: .atomic)
    }

    static func markDelivered(_ id: String) {
        guard var batch = loadBatches().first(where: { $0.id == id }) else { return }
        batch.status = "delivered"
        try? save(batch)
    }

    static func itemURL(_ item: Item, in batchID: String) -> URL? {
        batchURL(batchID)?.appendingPathComponent(item.relativePath)
    }
}

extension JSONEncoder {
    static let share: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

extension JSONDecoder {
    static let share: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
