import Foundation
import Darwin
import Combine
import Security
import CryptoKit

/// A single session is shared by stream casting, the Remote drawer and its badge.
/// Connection and pairing are distinct: a stored pairing is not proof the TV is online.
final class AndroidTvRemote: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    static let shared = AndroidTvRemote()
    struct Device: Identifiable, Equatable, Codable {
        let id: String
        let name: String
        let host: String
        let port: UInt16
        var address: String? = nil
    }
    enum State: Equatable { case idle, connecting, pairing, enteringCode, connected, disconnected }
    @Published private(set) var devices = [Device]()
    @Published private(set) var selected: Device?
    @Published private(set) var state: State = .idle
    @Published private(set) var message = "Choose a TV to connect your remote."
    @Published private(set) var isPaired = false
    @Published private(set) var isOn: Bool?
    @Published private(set) var fieldActive = false
    @Published private(set) var fieldText = ""
    @Published private(set) var fieldLabel = "TV keyboard"
    @Published private(set) var volume: String?
    @Published var pairingCode = ""
    private let browser = NetServiceBrowser()
    private var services = [NetService]()
    private var transport: TVRemoteTransport?
    private var deadline: DispatchWorkItem?
    private var identity: SecIdentity?
    private var features: UInt64 = 0
    private var imeCounter: UInt64 = 0
    private var fieldCounter: UInt64 = 0
    private var discovering = false
    var connected: Bool { state == .connected }
    var supportsKeyboard: Bool { features & 4 != 0 }
    var supportsAppLaunch: Bool { features & 512 != 0 }
    var supportsPower: Bool { features & 32 != 0 }
    var supportsVolume: Bool { features & 64 != 0 }

    override init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: "NuvioRemoteLastDevice"),
           let device = try? JSONDecoder().decode(Device.self, from: data) {
            selected = device; devices = [device]
            isPaired = TVRemoteIdentity.pin(device.host) != nil
        }
    }
    func discover() {
        guard !discovering else { return }
        discovering = true
        browser.delegate = self
        browser.searchForServices(ofType: "_androidtvremote2._tcp.", inDomain: "local.")
    }
    func stopDiscovery() {
        browser.stop(); services.forEach { $0.stop() }; services.removeAll(); discovering = false
    }
    func refresh() {
        stopDiscovery()
        devices = selected.map { [$0] } ?? []
        discover()
        if let selected, isPaired, !connected { connect(selected) }
    }
    func resume() {
        discover()
        if let selected, isPaired, !connected, state != .pairing, state != .enteringCode, state != .connecting { connect(selected) }
    }
    func suspend() {
        cancelConnection()
        state = .disconnected
        message = isPaired ? "Paired · Tap Connect to reconnect." : "Choose a TV to pair."
        stopDiscovery()
    }
    func selectCompanion(host: String) {
        // Both services advertise the same host. Never switch a connected remote
        // to another TV merely because discovery returned a new device.
        if let device = devices.first(where: { $0.host.caseInsensitiveCompare(host) == .orderedSame }), !connected { connect(device) }
    }
    func connect(_ device: Device) {
        cancelConnection()
        selected = device
        isPaired = TVRemoteIdentity.pin(device.host) != nil
        guard isPaired else { message = "Pair this iPhone with \(device.name) to use the remote."; state = .idle; return }
        state = .connecting; message = "Connecting to \(device.name)…"
        do {
            let identity = try TVRemoteIdentity.load(); self.identity = identity
            let transport = makeTransport()
            transport.onFrame = { [weak self] data in self?.receive(data) }
            try transport.open(host: device.address ?? device.host, port: device.port, identity: identity, expectedPeer: TVRemoteIdentity.pin(device.host))
            armDeadline(15, "Couldn’t connect. Check that your TV is on the same Wi-Fi, or pair again if its remote service was reset.")
        } catch { fail(error.localizedDescription) }
    }
    func pair() {
        guard let device = selected else { return }
        cancelConnection(); pairingCode = ""
        state = .pairing; message = "Waiting for the TV’s pairing code…"
        do {
            let identity = try TVRemoteIdentity.load(); self.identity = identity
            let transport = makeTransport()
            transport.onReady = { [weak transport] in
                transport?.send(TVWire.pairing(10, TVWire.string(1, "atvremote") + TVWire.string(2, "Nuvio iPhone")))
            }
            transport.onFrame = { [weak self] data in self?.receivePairing(data) }
            try transport.open(host: device.address ?? device.host, port: 6467, identity: identity, expectedPeer: nil)
            armDeadline(15, "The TV didn’t start pairing. Check Android TV Remote Service and try again.")
        } catch { fail(error.localizedDescription) }
    }
    func submitCode() {
        guard state == .enteringCode, let identity, let peer = transport?.peerCertificate else { return }
        let code = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard code.count == 6, code.allSatisfy({ $0.isHexDigit }) else { message = "Enter all 6 characters shown on your TV (0–9 and A–F)."; return }
        do {
            var client: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &client) == errSecSuccess,
                  let client, let clientKey = SecCertificateCopyKey(client), let serverKey = SecCertificateCopyKey(peer),
                  let check = UInt8(code.prefix(2), radix: 16), let suffix = UInt16(code.suffix(4), radix: 16) else { throw TVRemoteError.message("Couldn’t read the pairing certificates.") }
            let input = try TVDER.rsaParts(clientKey) + TVDER.rsaParts(serverKey) + Data([UInt8(suffix >> 8), UInt8(suffix & 255)])
            let secret = Data(SHA256.hash(data: input))
            guard secret.first == check else { message = "That code doesn’t match. Check the TV and try again."; return }
            state = .pairing
            transport?.send(TVWire.pairing(40, TVWire.bytes(1, secret)))
            armDeadline(12, "Pairing timed out. Tap Pair again for a new code.")
        } catch { fail(error.localizedDescription) }
    }
    func cancelPairing() {
        cancelConnection(); state = .idle; pairingCode = ""
        message = "Pairing cancelled. Tap Pair remote when you’re ready."
    }
    func key(_ code: UInt64) {
        guard connected else { return }
        transport?.send(TVWire.key(code))
    }
    func power() {
        guard connected, supportsPower else { return }
        // Explicit wake/sleep codes avoid accidentally toggling the TV twice.
        if let isOn { key(isOn ? 223 : 224) } else { key(26) }
    }
    func launchNuvio() {
        guard connected, supportsAppLaunch else { return }
        transport?.send(TVWire.bytes(90, TVWire.string(1, "nuvio-tv://home")))
    }
    func sendText(_ text: String) {
        guard connected, supportsKeyboard, fieldActive else { return }
        guard text.utf8.count <= 16_384 else { message = "Please send a shorter text (up to 16 KB)."; return }
        transport?.send(TVWire.edit(text, ime: imeCounter, field: fieldCounter))
    }
    private func makeTransport() -> TVRemoteTransport {
        let transport = TVRemoteTransport()
        self.transport = transport
        transport.onError = { [weak self] message in self?.fail(message) }
        return transport
    }
    private func receivePairing(_ data: Data) {
        do {
            let fields = try TVWire.fields(data)
            guard TVWire.integer(fields, 2) == 200 else { throw TVRemoteError.message("The TV rejected pairing. Tap Pair again for a new code.") }
            let encoding = TVWire.int(1, 3) + TVWire.int(2, 6)
            if TVWire.data(fields, 11) != nil {
                transport?.send(TVWire.pairing(20, TVWire.bytes(1, encoding) + TVWire.int(3, 1)))
            } else if TVWire.data(fields, 20) != nil {
                transport?.send(TVWire.pairing(30, TVWire.bytes(1, encoding) + TVWire.int(2, 1)))
            } else if TVWire.data(fields, 31) != nil {
                state = .enteringCode
                message = "Enter the 6-character code displayed on your TV."
                armDeadline(120, "The pairing code expired. Tap Pair again.")
            } else if TVWire.data(fields, 41) != nil {
                guard let device = selected, let peer = transport?.peerCertificate else { throw TVRemoteError.message("Missing TV certificate.") }
                try TVRemoteIdentity.savePin(SecCertificateCopyData(peer) as Data, host: device.host)
                pairingCode = ""; isPaired = true
                UserDefaults.standard.set(try JSONEncoder().encode(device), forKey: "NuvioRemoteLastDevice")
                connect(device)
            }
        } catch { fail(error.localizedDescription) }
    }
    private func receive(_ data: Data) {
        do {
            let fields = try TVWire.fields(data)
            for field in fields {
                guard let data = field.bytes else { continue }
                let body = try TVWire.fields(data)
                switch field.number {
                case 1:
                    features = TVWire.integer(body, 1) & 615 // ping, key, IME, power, volume, app links
                    guard features & 2 != 0 else { throw TVRemoteError.message("This TV doesn’t support remote buttons.") }
                    let info = TVWire.int(3, 1) + TVWire.string(4, "1") + TVWire.string(5, "com.nuvio.app") + TVWire.string(6, "1.0")
                    transport?.send(TVWire.bytes(1, TVWire.int(1, features) + TVWire.bytes(2, info)))
                case 2: transport?.send(TVWire.bytes(2, TVWire.int(1, features)))
                case 3: message = "The TV couldn’t accept that command. Check the active TV app and try again."
                case 8: transport?.send(TVWire.bytes(9, TVWire.int(1, TVWire.integer(body, 1))))
                case 20:
                    if let status = TVWire.data(body, 2) { try updateField(status) }
                    else { fieldActive = false; fieldText = "" }
                case 21:
                    imeCounter = TVWire.integer(body, 1); fieldCounter = TVWire.integer(body, 2)
                    if let edit = TVWire.data(body, 3), let status = TVWire.data(try TVWire.fields(edit), 2) {
                        fieldText = TVWire.text(try TVWire.fields(status), 3)
                    }
                case 22:
                    if let status = TVWire.data(body, 2) { try updateField(status) }
                case 40:
                    isOn = TVWire.integer(body, 1) != 0
                    state = .connected; deadline?.cancel()
                    message = isOn == true ? "Connected · Paired" : "Connected · TV in standby"
                    if let selected { UserDefaults.standard.set(try JSONEncoder().encode(selected), forKey: "NuvioRemoteLastDevice") }
                case 50:
                    let max = TVWire.integer(body, 6), level = TVWire.integer(body, 7)
                    volume = TVWire.integer(body, 8) == 1 ? "Muted" : (max > 0 ? "\(level) / \(max)" : nil)
                default: break
                }
            }
        } catch { fail(error.localizedDescription) }
    }
    private func updateField(_ data: Data) throws {
        let fields = try TVWire.fields(data)
        fieldCounter = TVWire.integer(fields, 1)
        fieldText = TVWire.text(fields, 2)
        let label = TVWire.text(fields, 6)
        fieldLabel = label.isEmpty ? "TV keyboard" : label
        fieldActive = true
    }
    private func armDeadline(_ seconds: Double, _ message: String) {
        deadline?.cancel()
        let deadline = DispatchWorkItem { [weak self] in self?.fail(message) }
        self.deadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: deadline)
    }
    private func cancelConnection() {
        deadline?.cancel(); deadline = nil
        transport?.onError = nil; transport?.onFrame = nil; transport?.close(); transport = nil
        fieldActive = false; fieldText = ""; isOn = nil; volume = nil; features = 0; imeCounter = 0; fieldCounter = 0
    }
    private func fail(_ text: String) { cancelConnection(); state = .disconnected; message = text }
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service); service.delegate = self; service.resolve(withTimeout: 8)
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        services.removeAll { $0 == service }; service.stop()
        devices.removeAll { $0.id == service.name && $0.id != selected?.id }
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        if !connected { message = "Allow Local Network access in iPhone Settings, then refresh." }
    }
    func netServiceDidResolveAddress(_ service: NetService) {
        guard let host = service.hostName, service.port > 0, service.port <= 65535 else { return }
        let address = service.addresses?.compactMap { data -> String? in
            data.withUnsafeBytes { raw -> String? in
                guard let base = raw.baseAddress, raw.count >= MemoryLayout<sockaddr_in>.size else { return nil }
                let socket = base.assumingMemoryBound(to: sockaddr.self)
                guard socket.pointee.sa_family == sa_family_t(AF_INET) else { return nil }
                var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(socket, socklen_t(raw.count), &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
                return String(cString: name)
            }
        }.first
        let device = Device(id: service.name, name: service.name, host: host, port: UInt16(service.port), address: address)
        devices.removeAll { $0.id == device.id || $0.host == host }; devices.append(device)
        devices.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if selected?.id == device.id || selected?.host == host {
            selected = device
            if state == .idle || state == .disconnected { connect(device) }
        } else if selected == nil { connect(device) }
    }
}
