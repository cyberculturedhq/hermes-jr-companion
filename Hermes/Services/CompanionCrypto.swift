import Foundation
import CryptoKit

/// The wire format and its security limits are documented in Protocol/HPKE.md.
enum CompanionCryptoError: LocalizedError {
    case invalidHandshake
    case authenticationFailed
    case invalidRecord
    case messageTooLarge
    case closed

    var errorDescription: String? {
        switch self {
        case .invalidHandshake: "The companion returned an invalid connection handshake."
        case .authenticationFailed: "The encrypted companion connection could not be verified. Pair again if the host key changed."
        case .invalidRecord: "The encrypted connection received an invalid or out-of-order message."
        case .messageTooLarge: "The message exceeds the companion connection limit."
        case .closed: "The encrypted companion connection is closed. Reconnect to continue."
        }
    }
}

enum CompanionCrypto {
    static let maximumRecordSize = 65_536
    static let maximumMessageSize = 40 * 1024 * 1024

    static func generatePrivateKey() -> Data {
        Curve25519.KeyAgreement.PrivateKey().rawRepresentation
    }

    static func publicKey(for privateKey: Data) throws -> Data {
        try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey).publicKey.rawRepresentation
    }
}

private enum CompanionWire {
    static let suite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly
    static let protocolName = Data("hermes-jr/hpke/v1\0".utf8)
    static let recordName = Data("hermes-jr/record/v1\0".utf8)
    static let hostProof = Data("hermes-jr/host-ready/v1".utf8)
    static let readyProof = Data("hermes-jr/authorized/v1\0".utf8)
    static let maximumPlaintext = 48 * 1024
    static let chunkSize = maximumPlaintext - 16
    static let maximumSequence: UInt64 = UInt64(UInt32.max)

    static func integer<T: FixedWidthInteger>(_ value: T) -> Data {
        var big = value.bigEndian
        return withUnsafeBytes(of: &big) { Data($0) }
    }

    static func number(_ data: Data, offset: Int, count: Int) -> UInt64 {
        data[offset..<(offset + count)].reduce(0) { ($0 << 8) | UInt64($1) }
    }
}

/// One handshake per socket. Never copy, persist, or reuse after reconnect.
final class CompanionClientHandshake {
    static func generatePrivateKey() -> Data { CompanionCrypto.generatePrivateKey() }

    private let hostPublicKey: Curve25519.KeyAgreement.PublicKey
    private var devicePrivateKey: Curve25519.KeyAgreement.PrivateKey?
    private let devicePublicKey: Data
    private var clientNonce = Data()
    private var clientEnc = Data()
    private var state = 0
    private var sender: CompanionRecords?
    private var recipient: CompanionRecords?

    init(hostPublicKey: Data, devicePrivateKey: Data) throws {
        self.hostPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: hostPublicKey)
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: devicePrivateKey)
        self.devicePrivateKey = privateKey
        devicePublicKey = privateKey.publicKey.rawRepresentation
    }

    func invalidate() {
        state = -1
        devicePrivateKey = nil
        sender?.invalidate()
        recipient?.invalidate()
    }

    func makeHello() throws -> Data {
        guard state == 0 else { invalidate(); throw CompanionCryptoError.invalidHandshake }
        clientNonce = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        state = 1
        return Data([1]) + devicePublicKey + clientNonce
    }

    /// authentication contains caller-owned JSON (pairing secret/device identifiers).
    func receiveChallenge(_ challenge: Data, authentication: Data) throws -> Data {
        do {
            guard state == 1, let privateKey = devicePrivateKey,
                  challenge.count >= 90, challenge.count <= CompanionCrypto.maximumRecordSize,
                  challenge[0] == 2, authentication.count <= CompanionWire.maximumPlaintext else {
                throw CompanionCryptoError.invalidHandshake
            }
            let hostNonce = challenge.subdata(in: 1..<33)
            let hostEnc = challenge.subdata(in: 33..<65)
            let transcript = CompanionWire.protocolName + hostPublicKey.rawRepresentation
                + devicePublicKey + clientNonce + hostNonce
            let inbound = try HPKE.Recipient(
                privateKey: privateKey, ciphersuite: CompanionWire.suite,
                info: transcript + Data("\0h2c".utf8), encapsulatedKey: hostEnc,
                authenticatedBy: hostPublicKey
            )
            let recipient = CompanionRecords(recipient: inbound, transcript: transcript, direction: "h2c")
            self.recipient = recipient
            guard try recipient.open(kind: 16, record: challenge.subdata(in: 65..<challenge.count)) == CompanionWire.hostProof else {
                throw CompanionCryptoError.authenticationFailed
            }
            let outbound = try HPKE.Sender(
                recipientKey: hostPublicKey, ciphersuite: CompanionWire.suite,
                info: transcript + Data("\0c2h".utf8) + hostEnc, authenticatedBy: privateKey
            )
            clientEnc = outbound.encapsulatedKey
            let sender = CompanionRecords(sender: outbound, transcript: transcript, direction: "c2h")
            self.sender = sender
            let auth = try sender.seal(kind: 17, plaintext: authentication)
            devicePrivateKey = nil
            state = 2
            return Data([3]) + clientEnc + auth
        } catch {
            invalidate()
            throw CompanionCryptoError.authenticationFailed
        }
    }

    /// Called after the host approves this device and sends encrypted authorization.
    func receiveReady(_ record: Data) throws -> CompanionSecureChannel {
        do {
            guard state == 2, let sender, let recipient else { throw CompanionCryptoError.invalidHandshake }
            guard try recipient.open(kind: 18, record: record) == CompanionWire.readyProof + clientEnc else {
                throw CompanionCryptoError.authenticationFailed
            }
            state = 3
            self.sender = nil
            self.recipient = nil
            return CompanionSecureChannel(sender: sender, recipient: recipient)
        } catch {
            invalidate()
            throw CompanionCryptoError.authenticationFailed
        }
    }
}

/// Callers must serialize an entire seal/send operation, including all returned frames.
final class CompanionSecureChannel {
    private let sender: CompanionRecords
    private let recipient: CompanionRecords
    private var sendID: UInt64 = 0
    private var receiveID: UInt64 = 0
    private var buffer = Data()
    private var expectedTotal: Int?
    private var valid = true

    fileprivate init(sender: CompanionRecords, recipient: CompanionRecords) {
        self.sender = sender
        self.recipient = recipient
    }

    func invalidate() {
        valid = false
        sender.invalidate()
        recipient.invalidate()
        buffer.removeAll(keepingCapacity: false)
        expectedTotal = nil
    }

    func seal(_ message: Data) throws -> [Data] {
        do {
            guard valid else { throw CompanionCryptoError.closed }
            guard message.count <= CompanionCrypto.maximumMessageSize, sendID <= CompanionWire.maximumSequence else {
                throw CompanionCryptoError.messageTooLarge
            }
            var records: [Data] = []
            for offset in stride(from: 0, to: max(1, message.count), by: CompanionWire.chunkSize) {
                let end = min(offset + CompanionWire.chunkSize, message.count)
                let plaintext = CompanionWire.integer(sendID) + CompanionWire.integer(UInt32(message.count))
                    + CompanionWire.integer(UInt32(offset)) + message.subdata(in: offset..<end)
                records.append(try sender.seal(kind: 32, plaintext: plaintext))
            }
            sendID += 1
            return records
        } catch {
            invalidate()
            throw error
        }
    }

    /// Returns nil until an entire logical message has been authenticated and assembled.
    func receive(_ record: Data) throws -> Data? {
        do {
            guard valid else { throw CompanionCryptoError.closed }
            let plaintext = try recipient.open(kind: 32, record: record)
            guard plaintext.count >= 16 else { throw CompanionCryptoError.invalidRecord }
            let messageID = CompanionWire.number(plaintext, offset: 0, count: 8)
            let total = Int(CompanionWire.number(plaintext, offset: 8, count: 4))
            let offset = Int(CompanionWire.number(plaintext, offset: 12, count: 4))
            let chunk = plaintext.subdata(in: 16..<plaintext.count)
            guard messageID == receiveID, total <= CompanionCrypto.maximumMessageSize,
                  offset == buffer.count, offset + chunk.count <= total,
                  total == 0 || !chunk.isEmpty else { throw CompanionCryptoError.invalidRecord }
            if expectedTotal == nil { expectedTotal = total }
            guard expectedTotal == total else { throw CompanionCryptoError.invalidRecord }
            buffer.append(chunk)
            if buffer.count == total {
                let message = buffer
                buffer = Data()
                expectedTotal = nil
                receiveID += 1
                return message
            }
            return nil
        } catch {
            invalidate()
            throw error
        }
    }
}

private final class CompanionRecords {
    private var sender: HPKE.Sender?
    private var recipient: HPKE.Recipient?
    private let aadPrefix: Data
    private var sequence: UInt64 = 0

    init(sender: HPKE.Sender, transcript: Data, direction: String) {
        self.sender = sender
        aadPrefix = CompanionWire.recordName + transcript + Data(direction.utf8)
    }

    init(recipient: HPKE.Recipient, transcript: Data, direction: String) {
        self.recipient = recipient
        aadPrefix = CompanionWire.recordName + transcript + Data(direction.utf8)
    }

    func invalidate() { sender = nil; recipient = nil }

    func seal(kind: UInt8, plaintext: Data) throws -> Data {
        do {
            guard sender != nil, sequence <= CompanionWire.maximumSequence,
                  plaintext.count <= CompanionWire.maximumPlaintext else { throw CompanionCryptoError.closed }
            let header = Data([kind]) + CompanionWire.integer(sequence)
            let ciphertext = try sender!.seal(plaintext, authenticating: aadPrefix + header)
            sequence += 1
            return header + ciphertext
        } catch {
            invalidate()
            throw CompanionCryptoError.authenticationFailed
        }
    }

    func open(kind: UInt8, record: Data) throws -> Data {
        do {
            guard recipient != nil, sequence <= CompanionWire.maximumSequence,
                  record.count >= 25, record.count <= CompanionCrypto.maximumRecordSize,
                  record[0] == kind, CompanionWire.number(record, offset: 1, count: 8) == sequence else {
                throw CompanionCryptoError.invalidRecord
            }
            let plaintext = try recipient!.open(record.subdata(in: 9..<record.count),
                                                authenticating: aadPrefix + record.prefix(9))
            guard plaintext.count <= CompanionWire.maximumPlaintext else { throw CompanionCryptoError.messageTooLarge }
            sequence += 1
            return plaintext
        } catch {
            invalidate()
            throw CompanionCryptoError.authenticationFailed
        }
    }
}
