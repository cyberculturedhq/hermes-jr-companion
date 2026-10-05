import Foundation
import CryptoKit

struct CompanionRelease: Codable, Sendable {
    let schema: Int
    let version: String
    let commit: String
    let signature: String
    static let publicKey = Data([0xac,0x07,0x2d,0x31,0xdb,0x54,0x6d,0x1f,0x24,0x1a,0xc1,0xac,0xe4,0x0c,0xb0,0xb4,0x74,0xbd,0x4e,0x83,0x3d,0x78,0x38,0x5c,0xb9,0xf0,0x34,0x99,0xe4,0x47,0x78,0xaf])

    func verified(publicKey: Data = Self.publicKey) throws -> Self {
        guard schema == 1, CompanionUpdateNotice.components(version) != nil,
              commit.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil,
              let signatureBytes = Data(base64Encoded: signature), signatureBytes.count == 64 else {
            throw HermesError.message("The update information could not be verified.")
        }
        let message = Data("hermes-jr-release-v1\ncyberculturedhq/hermes-jr-companion\n\(version)\n\(commit)\n".utf8)
        guard try Curve25519.Signing.PublicKey(rawRepresentation: publicKey).isValidSignature(signatureBytes, for: message) else {
            throw HermesError.message("The update information could not be verified.")
        }
        return self
    }
}

actor CompanionReleaseFeed {
    static let shared = CompanionReleaseFeed()
    private var cached: CompanionRelease?
    private var checked: Date?

    func latest(force: Bool = false) async throws -> CompanionRelease {
        if !force, let checked, Date().timeIntervalSince(checked) < 900, let cached { return cached }
        var request = URLRequest(url: URL(string: SetupPairing.service + "/v1/companion-release")!)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 12
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw HermesError.message("Couldn’t check for updates. Try again later.")
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 4096 else { throw HermesError.message("Invalid update information.") }
            data.append(byte)
        }
        let release = try JSONDecoder().decode(CompanionRelease.self, from: data).verified()
        cached = release; checked = Date()
        return release
    }
}

struct CompanionUpdateReceipt: Codable, Equatable {
    let id: String
    let device_id: String
    let profile: String
    let session_id: String
    let target: String
    let notify: Bool
    let created: Double

    var displayText: String {
        "Update my Hermes Jr. companion to version " + target + (notify ? " and notify me when the verified update is complete." : ".")
    }

    var body: [String: Any] { get throws {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as! [String: Any]
    } }
    var prompt: String { get throws {
        let receipt = try JSONEncoder().encode(self).companionBase64
        return """
        Update my Hermes Jr. companion to version \(target) or the latest signed stable release. Preserve my pairings, profile settings, and other active work. Use the installed companion updater. Keep this completion receipt:

        hermes jr update --install --receipt \(receipt)

        Keep the receipt argument unchanged. Do not download or execute install.py for this installed companion. If --receipt is unavailable, use the installed hermes_jr.update_requests.run_tracked function with the Hermes Python environment and a release verified by the installed hermes_jr.updates.check function. If these installed functions are unavailable, stop and report that a supported manual migration is required. Do not substitute an untracked update command. Report any constraint or failure. Preserve shared dependencies. The bridge can disconnect briefly during restart. Do not stop this conversation's Hermes process. Explain any restart needed for loaded Hermes hooks. Confirm completion only after the installed updater verifies it.
        """
    } }
}

struct CompanionUpdateProgress: Codable, Equatable {
    let receipt: CompanionUpdateReceipt
    var status: String = "requested"
    var installed: String?
    var error: String?
    var pending: Bool { !["completed", "failed"].contains(status) }
    var message: String {
        switch status {
        case "completed": "Companion \(installed ?? receipt.target) installed. Restart Hermes on your computer when its current work is finished to finish applying the update."
        case "failed": error ?? "The update did not complete. Try again or open its conversation for details."
        case "unconfirmed": "The connection was interrupted. Check update status before trying again; the installer may still be running."
        default: "Update requested. You can leave the app; we’ll verify the result when Hermes reconnects."
        }
    }
}
