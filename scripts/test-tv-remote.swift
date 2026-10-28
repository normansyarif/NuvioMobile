// Run: swiftc iosApp/iosApp/AndroidTvProtocol.swift iosApp/iosApp/TvCompanionBehavior.swift scripts/test-tv-remote.swift -o /tmp/nuvio-remote-tests && /tmp/nuvio-remote-tests
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
        var input = TVInputState()
        let snapshot = TVWire.bytes(1, TVWire.int(1, 3)) + TVWire.bytes(2, TVWire.int(1, 13) + TVWire.string(2, "first"))
        try input.receive(number: 20, body: TVWire.fields(snapshot))
        try check(input.session == 3 && input.revision == 13 && input.active, "Use both counters from active field snapshot")
        try input.receive(number: 21, body: TVWire.fields(TVWire.int(1, 1) + TVWire.int(2, 1)))
        try check(input.session == 3 && input.revision == 13, "Empty initial acknowledgement must not roll back counters")
        try input.receive(number: 22, body: TVWire.fields(TVWire.bytes(2, TVWire.int(1, 14) + TVWire.string(2, "edited 📺"))))
        try check(input.session == 3 && input.revision == 14 && input.text == "edited 📺", "Field revision updates without changing session")
        try input.receive(number: 20, body: TVWire.fields(TVWire.bytes(1, TVWire.int(1, 4))))
        try check(!input.active && input.text.isEmpty, "App switch clears active input")
        func claim(_ policy: inout TVAutomaticPlayback, playback: Bool = true, devices: Int = 1,
                   services: Int = 1, pending: Int = 0, more: Bool = false, paired: Bool = true,
                   busy: Bool = false, active: Bool = true) -> Bool {
            policy.claim(hasPlayback: playback, deviceCount: devices, serviceCount: services,
                         unresolvedCount: pending, moreComing: more, paired: paired, busy: busy, active: active)
        }
        var automatic = TVAutomaticPlayback()
        try check(!claim(&automatic, pending: 1), "Wait for pending Bonjour resolutions")
        try check(!claim(&automatic, more: true), "Wait for the Bonjour discovery batch")
        try check(!claim(&automatic, devices: 2, services: 2), "Multiple available TVs require selection")
        try check(!claim(&automatic, services: 2), "An unresolved or incompatible second TV cannot trigger automatic playback")
        try check(!claim(&automatic, paired: false), "Unpaired TV requires pairing")
        try check(!claim(&automatic, playback: false), "Remote-only drawer never sends a stream")
        try check(!claim(&automatic, busy: true), "Do not race another operation")
        try check(!claim(&automatic, active: false), "No automatic playback after dismissal or backgrounding")
        try check(claim(&automatic), "One resolved paired TV starts automatically")
        try check(!claim(&automatic), "Refresh and discovery updates cannot replay the stream")
        var manual = TVAutomaticPlayback(); manual.suppress()
        try check(!claim(&manual), "Manual selection cancels pending automatic playback")
        var volumeUp = TVVolumeAdjustment(fraction: 0.13, maximum: 100)
        try check(volumeUp.nextKey(level: 9) == 24, "Slider increases real TV volume")
        try check(volumeUp.nextKey(level: 11) == 24, "Follow confirmed two-unit hardware steps")
        try check(volumeUp.nextKey(level: 13) == nil, "Stop when target reached")
        var coarse = TVVolumeAdjustment(fraction: 0.13, maximum: 100)
        try check(coarse.nextKey(level: 12) == 24 && coarse.nextKey(level: 14) == nil, "Never oscillate around an unreachable volume")
        var overshoot = TVVolumeAdjustment(fraction: 0.13, maximum: 100)
        try check(overshoot.nextKey(level: 12) == 24 && overshoot.nextKey(level: 16) == 25 && overshoot.nextKey(level: 12) == nil, "Restore the closer level after a coarse overshoot")
        var quiet = TVVolumeAdjustment(fraction: 0, maximum: 15)
        try check(quiet.nextKey(level: 2) == 25 && quiet.nextKey(level: 0) == nil, "Slider reaches silence")
        try check(TVVolumeAdjustment(fraction: 2, maximum: 15).target == 15, "Clamp slider to the reported TV range")
        try check(TVVolumeAdjustment(fraction: .nan, maximum: 15).target == 0, "Reject invalid slider fractions safely")
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
        let key = SecKeyCreateRandomKey(attributes as CFDictionary, nil)!
        try check(try TVDER.rsaParts(SecKeyCopyPublicKey(key)!).count == 259, "RSA hash inputs contain unsigned modulus and exponent")
        print("\(passed) Android TV protocol checks passed")
    }
}
