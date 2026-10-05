import Foundation

struct BotProfile: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var displayName: String
    var summary: String
    var model: String
    var isGatewayRunning: Bool
    var avatarDataURL: String? = nil
    var botSession: HermesSession? = nil

    var name: String { displayName.isEmpty ? (id == "default" ? "Hermes" : id.capitalized) : displayName }
}

struct HermesSession: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var title: String
    var preview: String
    var lastActive: Date
    var messageCount: Int
    var source: String

    var name: String { title.isEmpty ? "Untitled session" : title }
}

struct DraftPhoto: Identifiable, Hashable, Codable, Sendable {
    var id: UUID = UUID()
    var data: Data
    var filename: String
    var isFile: Bool? = nil
}

enum MessageDelivery: String, Codable, Sendable { case sending, delivered, unknown }

struct ChatMessage: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var role: String
    var text: String
    var isStreaming: Bool = false
    var photos: [DraftPhoto] = []
    var timestamp: Date? = nil
    var delivery: MessageDelivery? = nil
}

enum HermesSendError: LocalizedError {
    case notSubmitted(String)
    case turnFailed(String)
    case outcomeUnknown(String)

    var errorDescription: String? {
        switch self {
        case .notSubmitted(let message), .turnFailed(let message), .outcomeUnknown(let message): message
        }
    }
}

struct ConnectionSettings: Codable, Equatable, Sendable {
    var address: String
    var username: String = ""
    var usesSavedCredentials: Bool? = nil
    var companion: CompanionConnection? = nil
    var serverName: String { URL(string: address)?.host ?? address }
}

enum ConnectionPhase: Equatable {
    case restoring
    case disconnected
    case connecting
    case connected
}

enum HermesError: LocalizedError {
    case message(String)
    case secureConnectionRequired
    var errorDescription: String? {
        switch self {
        case .message(let text): text
        case .secureConnectionRequired: "This direct connection needs HTTPS. Configure HTTPS on your computer, or use encrypted companion mode. Your saved connection is kept until you choose a secure connection."
        }
    }
}

struct HermesHTTPError: LocalizedError {
    let statusCode: Int
    let message: String
    var errorDescription: String? { message }
}

struct HermesCommandSuggestion: Identifiable, Hashable, Sendable {
    /// The complete composer text to insert, including any completed argument.
    var text: String
    var display: String
    var description: String
    var kind: String = "command"
    var argumentMode: String? = nil
    var id: String { text }
}

struct HermesCommandCatalog: Sendable {
    var commands: [HermesCommandSuggestion]
    var aliases: [String: String] = [:]
    var warning: String? = nil

    func canonicalName(for command: String) -> String {
        let name = String(command.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace).first ?? "").lowercased()
        return aliases[name] ?? name
    }
}

enum HermesCommandResult: Sendable {
    case output(String)
    case send(message: String, display: String, notice: String?)
    case prefill(message: String, notice: String)
    case confirmation(message: String)
    case newSession
    case stopped
}

enum HermesCommandError: LocalizedError {
    case rejected(String)
    case outcomeUnknown(String)

    var errorDescription: String? {
        switch self {
        case .rejected(let text), .outcomeUnknown(let text): text
        }
    }
}
