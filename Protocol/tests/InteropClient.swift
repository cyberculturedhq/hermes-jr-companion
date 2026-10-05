import Foundation
import CryptoKit

@main
struct InteropClient {
    static func decode(_ input: [String: Any], _ key: String) throws -> Data {
        guard let string = input[key] as? String, let value = Data(base64Encoded: string) else {
            throw CompanionCryptoError.invalidRecord
        }
        return value
    }

    static func main() {
        var handshake: CompanionClientHandshake?
        var channel: CompanionSecureChannel?
        while let line = readLine() {
            let output: [String: Any]
            do {
                let input = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
                switch input["op"] as? String {
                case "hello":
                    handshake = try CompanionClientHandshake(hostPublicKey: decode(input, "host"), devicePrivateKey: decode(input, "private"))
                    output = ["record": try handshake!.makeHello().base64EncodedString()]
                case "challenge":
                    output = ["record": try handshake!.receiveChallenge(decode(input, "record"), authentication: decode(input, "authentication")).base64EncodedString()]
                case "ready":
                    channel = try handshake!.receiveReady(decode(input, "record"))
                    output = ["ok": true]
                case "seal":
                    output = ["records": try channel!.seal(decode(input, "message")).map { $0.base64EncodedString() }]
                case "receive":
                    let result = try channel!.receive(decode(input, "record"))
                    output = ["message": result.map { $0.base64EncodedString() } as Any? ?? NSNull()]
                case "rfc":
                    var context = try HPKE.Recipient(
                        privateKey: Curve25519.KeyAgreement.PrivateKey(rawRepresentation: decode(input, "private")),
                        ciphersuite: .Curve25519_SHA256_ChachaPoly, info: decode(input, "info"),
                        encapsulatedKey: decode(input, "enc"),
                        authenticatedBy: Curve25519.KeyAgreement.PublicKey(rawRepresentation: decode(input, "public"))
                    )
                    let encryptions = input["encryptions"] as! [[String: Any]]
                    let messages = try encryptions.map { encryption in
                        try context.open(decode(encryption, "ct"), authenticating: decode(encryption, "aad")).base64EncodedString()
                    }
                    output = ["messages": messages]
                default:
                    throw CompanionCryptoError.invalidRecord
                }
            } catch {
                output = ["error": error.localizedDescription]
            }
            let data = try! JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
            FileHandle.standardOutput.write(data + Data([10]))
        }
    }
}
