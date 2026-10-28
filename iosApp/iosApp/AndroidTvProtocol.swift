import Foundation
import Security
import Network
import CryptoKit

// Wire fields follow Android TV Remote v2 and Google's Polo pairing protocol.
// Interoperability reference: tronikos/androidtvremote2 (Apache-2.0).
// This codec intentionally implements only the messages used by Nuvio.
enum TVRemoteError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

enum TVWire {
    struct Field {
        let number: Int
        let integer: UInt64?
        let bytes: Data?
    }
    static func varint(_ value: UInt64) -> Data {
        var value = value, result = Data()
        while value > 127 { result.append(UInt8(value & 127) | 128); value >>= 7 }
        result.append(UInt8(value)); return result
    }
    static func int(_ number: Int, _ value: UInt64, includeZero: Bool = false) -> Data {
        guard value != 0 || includeZero else { return Data() }
        return varint(UInt64(number << 3)) + varint(value)
    }
    static func bytes(_ number: Int, _ value: Data) -> Data {
        varint(UInt64(number << 3 | 2)) + varint(UInt64(value.count)) + value
    }
    static func string(_ number: Int, _ value: String) -> Data { bytes(number, Data(value.utf8)) }
    static func readVarint(_ data: Data, _ cursor: inout Int) throws -> UInt64 {
        var value: UInt64 = 0
        for shift in stride(from: 0, through: 63, by: 7) {
            guard cursor < data.count else { throw TVRemoteError.message("Incomplete TV message.") }
            let byte = data[data.startIndex + cursor]; cursor += 1
            guard shift != 63 || byte < 2 else { throw TVRemoteError.message("Invalid TV message.") }
            value |= UInt64(byte & 127) << shift
            if byte & 128 == 0 { return value }
        }
        throw TVRemoteError.message("Invalid TV message.")
    }
    static func fields(_ data: Data) throws -> [Field] {
        var cursor = 0, fields = [Field]()
        while cursor < data.count {
            let tag = try readVarint(data, &cursor), number = Int(tag >> 3)
            guard number > 0 else { throw TVRemoteError.message("Invalid TV field.") }
            switch tag & 7 {
            case 0: fields.append(Field(number: number, integer: try readVarint(data, &cursor), bytes: nil))
            case 2:
                let size = try readVarint(data, &cursor)
                guard size <= 1_048_576, size <= data.count - cursor else { throw TVRemoteError.message("Oversized TV message.") }
                let end = cursor + Int(size)
                fields.append(Field(number: number, integer: nil, bytes: data.subdata(in: cursor..<end))); cursor = end
            case 1, 5:
                let size = tag & 7 == 1 ? 8 : 4
                guard cursor + size <= data.count else { throw TVRemoteError.message("Incomplete TV field.") }
                cursor += size
            default: throw TVRemoteError.message("Unsupported TV message.")
            }
        }
        return fields
    }
    static func integer(_ fields: [Field], _ number: Int) -> UInt64 { fields.first { $0.number == number }?.integer ?? 0 }
    static func data(_ fields: [Field], _ number: Int) -> Data? { fields.first { $0.number == number }?.bytes }
    static func text(_ fields: [Field], _ number: Int) -> String { data(fields, number).flatMap { String(data: $0, encoding: .utf8) } ?? "" }
    static func pairing(_ field: Int, _ body: Data) -> Data { int(1, 2) + int(2, 200) + bytes(field, body) }
    static func key(_ code: UInt64) -> Data { bytes(10, int(1, code) + int(2, 3)) }
    static func edit(_ value: String, ime: UInt64, field: UInt64) -> Data {
        let position = UInt64(bitPattern: Int64(value.utf16.count - 1))
        let object = int(1, position) + int(2, position) + string(3, value)
        return bytes(21, int(1, ime) + int(2, field) + bytes(3, int(1, 1) + bytes(2, object)))
    }
}

struct TVFrameBuffer {
    private var buffer = Data()
    mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        guard buffer.count <= 2_097_152 else { throw TVRemoteError.message("Oversized TV response.") }
        var result = [Data]()
        while !buffer.isEmpty {
            var cursor = 0
            // A length prefix may be split across TCP reads.
            guard let terminator = buffer.prefix(4).firstIndex(where: { $0 & 128 == 0 }) else {
                if buffer.count >= 4 { throw TVRemoteError.message("Invalid TV frame length.") }; break
            }
            let size = try TVWire.readVarint(Data(buffer.prefix(terminator + 1)), &cursor)
            guard size <= 1_048_576 else { throw TVRemoteError.message("Oversized TV frame.") }
            guard buffer.count - cursor >= Int(size) else { break }
            result.append(buffer.subdata(in: cursor..<(cursor + Int(size))))
            buffer = Data(buffer.dropFirst(cursor + Int(size)))
        }
        return result
    }
}

// Minimal DER writer for an RSA client certificate generated entirely on-device.
// The private key never leaves the Keychain. No bundled/shared client credentials.
enum TVDER {
    static func item(_ tag: UInt8, _ value: Data) -> Data {
        var length = Data()
        if value.count < 128 { length.append(UInt8(value.count)) }
        else {
            var size = value.count, digits = [UInt8]()
            while size > 0 { digits.insert(UInt8(size & 255), at: 0); size >>= 8 }
            length.append(128 | UInt8(digits.count)); length.append(contentsOf: digits)
        }
        return Data([tag]) + length + value
    }
    static func sequence(_ value: Data) -> Data { item(0x30, value) }
    static func rsaParts(_ key: SecKey) throws -> Data {
        guard let external = SecKeyCopyExternalRepresentation(key, nil) as Data? else { throw TVRemoteError.message("Couldn’t read TV public key.") }
        var cursor = 0
        func element() throws -> (UInt8, Data) {
            guard cursor + 2 <= external.count else { throw TVRemoteError.message("Invalid RSA key.") }
            let tag = external[cursor]; cursor += 1
            var size = Int(external[cursor]); cursor += 1
            if size & 128 != 0 {
                let count = size & 127; size = 0
                guard count <= 4, cursor + count <= external.count else { throw TVRemoteError.message("Invalid RSA length.") }
                for _ in 0..<count { size = (size << 8) | Int(external[cursor]); cursor += 1 }
            }
            guard cursor + size <= external.count else { throw TVRemoteError.message("Invalid RSA value.") }
            let value = external.subdata(in: cursor..<(cursor + size))
            if tag != 0x30 { cursor += size }
            return (tag, value)
        }
        _ = try element()
        let modulus = try element().1, exponent = try element().1
        return Data(modulus.drop(while: { $0 == 0 })) + Data(exponent.drop(while: { $0 == 0 }))
    }
}

enum TVRemoteIdentity {
    private static let label = "Nuvio Android TV Remote"
    private static let tag = Data("com.nuvio.remote.rsa.v1".utf8)
    static func load() throws -> SecIdentity {
        if let identity = existing() { return identity }
        var error: Unmanaged<CFError>?
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tag, kSecAttrLabel as String: label,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]]
        // Reuse an orphaned key if certificate creation was interrupted.
        var found: CFTypeRef?
        let keyQuery: [String: Any] = [kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: tag,
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecReturnRef as String: true]
        let privateKey: SecKey
        if SecItemCopyMatching(keyQuery as CFDictionary, &found) == errSecSuccess, let found {
            privateKey = (found as! SecKey)
        } else if let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) { privateKey = key }
        else { throw TVRemoteError.message("Couldn’t create the remote’s secure identity.") }
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              let publicData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else { throw TVRemoteError.message("Couldn’t create TV public key.") }
        let rsaOID = Data([0x06,0x09,0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x01,0x01,0x05,0x00])
        let shaOID = Data([0x06,0x09,0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x01,0x0b,0x05,0x00])
        let algorithm = TVDER.sequence(shaOID)
        let name = TVDER.sequence(TVDER.item(0x31, TVDER.sequence(Data([0x06,0x03,0x55,0x04,0x03]) + TVDER.item(0x0c, Data(label.utf8)))))
        var serial = Data(count: 16)
        guard serial.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }) == errSecSuccess else { throw TVRemoteError.message("Couldn’t create certificate serial.") }
        serial[0] &= 0x7f; serial[0] |= 1
        let validity = TVDER.sequence(TVDER.item(0x18, Data("20200101000000Z".utf8)) + TVDER.item(0x18, Data("20500101000000Z".utf8)))
        let spki = TVDER.sequence(TVDER.sequence(rsaOID) + TVDER.item(0x03, Data([0]) + publicData))
        let tbs = TVDER.sequence(TVDER.item(0xa0, TVDER.item(2, Data([2]))) + TVDER.item(2, serial) + algorithm + name + validity + name + spki)
        guard let signature = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, tbs as CFData, &error) as Data?,
              let cert = SecCertificateCreateWithData(nil, TVDER.sequence(tbs + algorithm + TVDER.item(3, Data([0]) + signature)) as CFData) else { throw TVRemoteError.message("Couldn’t create remote certificate.") }
        let add: [String: Any] = [kSecClass as String: kSecClassCertificate, kSecValueRef as String: cert, kSecAttrLabel as String: label]
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem, let identity = existing() else { throw TVRemoteError.message("Couldn’t save remote identity (\(status)).") }
        return identity
    }
    private static func existing() -> SecIdentity? {
        var result: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassIdentity, kSecAttrLabel as String: label,
            kSecReturnRef as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let result else { return nil }
        return (result as! SecIdentity)
    }
    static func pin(_ host: String) -> Data? {
        var result: CFTypeRef?
        var query = pinQuery(host); query[kSecReturnData as String] = true
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
    static func savePin(_ data: Data, host: String) throws {
        let query = pinQuery(host)
        let status: OSStatus
        if pin(host) != nil { status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) }
        else {
            var add = query; add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw TVRemoteError.message("Couldn’t save TV pairing.") }
    }
    private static func pinQuery(_ host: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.nuvio.remote.peer.v1", kSecAttrAccount as String: host.lowercased()]
    }
}

// All callbacks and framing run serially on the main queue, like the UI owner.
final class TVRemoteTransport {
    var onFrame: ((Data) -> Void)?
    var onReady: (() -> Void)?
    var onError: ((String) -> Void)?
    private(set) var peerCertificate: SecCertificate?
    private var connection: NWConnection?
    private var frames = TVFrameBuffer()
    private var timeout: DispatchWorkItem?
    func open(host: String, port: UInt16, identity: SecIdentity, expectedPeer: Data?) throws {
        close()
        guard let localIdentity = sec_identity_create(identity) else { throw TVRemoteError.message("Couldn’t load the remote identity.") }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, localIdentity)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        // Android TV's pairing and control endpoints must each authenticate the
        // client certificate; do not resume a TLS session across these ports.
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_tls_resumption_enabled(tls.securityProtocolOptions, false)
        sec_protocol_options_set_tls_tickets_enabled(tls.securityProtocolOptions, false)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { [weak self] _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let certificate = (SecTrustCopyCertificateChain(secTrust) as? [SecCertificate])?.first else { complete(false); return }
            self?.peerCertificate = certificate
            // During explicit code pairing the code authenticates this certificate.
            complete(expectedPeer == nil || SecCertificateCopyData(certificate) as Data == expectedPeer)
        }, .main)
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.includePeerToPeer = false
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, self.connection === connection else { return }
            switch state {
            case .ready: self.timeout?.cancel(); self.onReady?(); self.receive()
            case .failed(let error): self.fail(error.localizedDescription)
            case .waiting: break // Bounded by the connection deadline.
            default: break
            }
        }
        let deadline = DispatchWorkItem { [weak self] in self?.fail("TV didn’t respond. Check Wi-Fi and whether the TV is awake.") }
        timeout = deadline; DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: deadline)
        connection.start(queue: .main)
    }
    func send(_ data: Data) {
        guard let connection else { return }
        connection.send(content: TVWire.varint(UInt64(data.count)) + data, completion: .contentProcessed { [weak self, weak connection] error in
            guard let self, self.connection === connection else { return }
            if let error { self.fail(error.localizedDescription) }
        })
    }
    private func receive() {
        guard let connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self, weak connection] data, _, complete, error in
            guard let self, self.connection === connection else { return }
            do {
                if let data { for frame in try self.frames.append(data) { self.onFrame?(frame) } }
                if let error { self.fail(error.localizedDescription) }
                else if complete { self.fail("TV disconnected. Tap Connect to reconnect.") }
                else { self.receive() }
            } catch { self.fail(error.localizedDescription) }
        }
    }
    private func fail(_ message: String) { close(); onError?(message) }
    func close() { timeout?.cancel(); timeout = nil; connection?.cancel(); connection = nil; frames = TVFrameBuffer(); peerCertificate = nil }
    deinit { connection?.cancel(); timeout?.cancel() }
}
