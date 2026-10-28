// Run: swiftc iosApp/iosApp/AndroidTvProtocol.swift scripts/test-tv-remote.swift -o /tmp/nuvio-remote-tests && /tmp/nuvio-remote-tests
import Foundation
import Security
@main struct RemoteProtocolTests {
    static func main() throws {
        var passed = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
            guard try condition() else { fatalError(label) }; passed += 1
        }
        func rejected(_ data: Data) -> Bool { do { _ = try TVWire.fields(data); return false } catch { return true } }
        func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
        try check(hex(TVWire.key(19)) == "520408131003", "DPAD wire packet must match RemoteMessage schema")
        try check(hex(TVWire.pairing(10, TVWire.string(1, "atvremote") + TVWire.string(2, "Nuvio"))) == "080210c80152120a0961747672656d6f746512054e7576696f", "Polo request schema")
        try check(TVWire.int(1, 0).isEmpty, "Omit proto3 default counters")
        for value: UInt64 in [0, 127, 128, 16384, UInt64.max] {
            var cursor = 0; let data = TVWire.varint(value)
            try check(try TVWire.readVarint(data, &cursor) == value && cursor == data.count, "Varint roundtrip")
        }
        var buffer = TVFrameBuffer()
        let payload = Data(repeating: 42, count: 300), framed = TVWire.varint(300) + payload
        try check(try buffer.append(Data(framed.prefix(1))).isEmpty, "Split prefix")
        try check(try buffer.append(Data(framed.dropFirst(1).prefix(5))).isEmpty, "Split body")
        try check(try buffer.append(Data(framed.dropFirst(6))) == [payload], "Reassemble TCP fragments")
        try check(try buffer.append(Data([1, 8, 1, 9])) == [Data([8]), Data([9])], "Multiple frames per read")
        do { _ = try buffer.append(Data([0xff,0xff,0xff,0x7f])); fatalError("Oversized frame accepted") } catch { passed += 1 }
        try check(rejected(Data([0x0a, 0xff])), "Truncated field")
        try check(rejected(Data([0x08] + Array(repeating: 0xff, count: 10))), "Overflow varint")
        try check(rejected(Data([0])), "Field zero is invalid")
        for text in ["", "a", "café", "TV 📺"] {
            let outer = try TVWire.fields(TVWire.edit(text, ime: 0, field: 7))
            let batch = try TVWire.fields(TVWire.data(outer, 21)!)
            try check(!batch.contains { $0.number == 1 }, "Zero IME counter must be omitted")
            let edit = try TVWire.fields(TVWire.data(batch, 3)!)
            let object = try TVWire.fields(TVWire.data(edit, 2)!)
            try check(TVWire.text(object, 3) == text, "Unicode text preserved")
            try check(TVWire.integer(object, 1) == UInt64(bitPattern: Int64(text.utf16.count - 1)), "IME indices use UTF16 including emoji and clearing")
        }
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
        let key = SecKeyCreateRandomKey(attributes as CFDictionary, nil)!
        try check(try TVDER.rsaParts(SecKeyCopyPublicKey(key)!).count == 259, "RSA hash inputs contain unsigned modulus and exponent")
        print("\(passed) Android TV protocol checks passed")
    }
}
