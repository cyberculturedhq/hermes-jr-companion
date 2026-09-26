import Foundation
import CryptoKit

/// Display-only snapshots. Never restore runtime IDs, pending actions, or unsent drafts.
struct CachedContent<Value: Codable>: Codable {
    var value: Value
    var updatedAt: Date
}

struct ContentSnapshot: Codable {
    var profiles: CachedContent<[BotProfile]>?
    var sessions: [String: CachedContent<[HermesSession]>] = [:]
    var conversations: [String: [String: CachedContent<[ChatMessage]>]] = [:]
}

@MainActor
final class ContentCache {
    private let directory: URL
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ConversationCache", isDirectory: true)
    }
    static func identity(_ settings: ConnectionSettings) -> String {
        let parts: [String]
        if let companion = settings.companion {
            parts = ["companion", companion.relayURL, companion.installationID, companion.hostPublicKey, companion.deviceID]
        } else { parts = ["direct", settings.address, settings.username] }
        return SHA256.hash(data: Data(parts.joined(separator: "\u{0}").utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func file(_ settings: ConnectionSettings) -> URL {
        directory.appendingPathComponent(Self.identity(settings) + ".json")
    }
    func load(_ settings: ConnectionSettings) -> ContentSnapshot {
        let url = file(settings)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 24_000_000,
              let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(ContentSnapshot.self, from: data) else { return ContentSnapshot() }
        return value
    }
    func save(_ snapshot: ContentSnapshot, for settings: ConnectionSettings) {
        guard let data = try? JSONEncoder().encode(snapshot), data.count <= 24_000_000 else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var root = directory
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try root.setResourceValues(values)
            try data.write(to: file(settings), options: .atomic)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file(settings).path)
        } catch { /* A cache failure must not break a live conversation. */ }
    }
    func remove(_ settings: ConnectionSettings) { try? FileManager.default.removeItem(at: file(settings)) }
}

enum ContentRefreshPhase { case idle, connecting, checking, unavailable, failed }
struct ContentRefreshStatus {
    var phase: ContentRefreshPhase = .connecting
    var updatedAt: Date?
    func text(now: Date = Date()) -> String {
        switch phase {
        case .connecting: return "Connecting…"
        case .checking: return "Checking for latest data…"
        case .idle, .unavailable, .failed:
            let age = updatedAt.map { max(0, Int(now.timeIntervalSince($0) / 60)) }
            let updated = age.map { $0 == 0 ? "Updated just now" : $0 < 60 ? "Updated \($0)m ago" : $0 < 1440 ? "Updated \($0 / 60)h ago" : "Updated \($0 / 1440)d ago" }
            if phase != .idle {
                let problem = phase == .unavailable ? "Offline" : "Couldn’t refresh"
                return updated.map { problem + " · " + $0 } ?? problem + " · Tap to retry"
            }
            return updated ?? "Not updated yet"
        }
    }
}
