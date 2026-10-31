import UIKit
import SwiftUI
import Combine
import Security
import ComposeApp

final class NuvioTvPresenter: NSObject, TvCompanionPresenter {
    static let shared = NuvioTvPresenter()
    private weak var picker: TvPickerController?

    func present(payloadJson: String) {
        DispatchQueue.main.async {
            guard self.picker == nil,
                  let data = payloadJson.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            self.presentPicker(payload)
        }
    }

    func presentRemote() { present(payloadJson: "{}") }

    private func presentPicker(_ payload: [String: Any]) {
        guard picker == nil,
              let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
              var host = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return }
        while let presented = host.presentedViewController {
            // The Compose action sheet dismisses asynchronously on iOS. Present only
            // after its UIKit transition completes, never from the outgoing sheet.
            if presented.isBeingDismissed || presented.isBeingPresented {
                if let transition = presented.transitionCoordinator {
                    transition.animate(alongsideTransition: nil) { _ in self.presentPicker(payload) }
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.presentPicker(payload) }
                }
                return
            }
            host = presented
        }
        let controller = TvPickerController(payload: payload)
        picker = controller
        let navigation = UINavigationController(rootViewController: controller)
        navigation.overrideUserInterfaceStyle = .dark
        host.present(navigation, animated: true)
    }
}

private enum TvCredentials {
    private static let service = "tv.nuvio.companion"
    static func token(for id: String) -> String? {
        var query = base(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ token: String, for id: String) throws {
        var query = base(id)
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = Data(token.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else {
            throw TvError.message("Couldn’t save the TV pairing. Please try again.")
        }
    }
    private static func base(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id]
    }
}

private enum TvError: LocalizedError {
    case message(String), unauthorized
    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        case .unauthorized: return "Please pair this iPhone with the TV again."
        }
    }
}

/// Never forward pairing credentials to a redirect target supplied by another host.
private final class TvSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

private final class TvPickerController: UITableViewController, NetServiceBrowserDelegate, NetServiceDelegate {
    private struct Device {
        let id: String
        let name: String
        let baseURL: URL
    }
    private let payload: [String: Any]
    private let browser = NetServiceBrowser()
    private var services = [NetService]()
    private var devices = [Device]()
    private var operation: Task<Void, Never>?
    private var preparation: Task<Void, Never>?
    private var launchedHost: String?
    private var automaticPlaybackWork: DispatchWorkItem?
    private var automaticPlayback = TVAutomaticPlayback()
    private var unresolvedServices = Set<ObjectIdentifier>()
    private var moreServicesComing = false
    private var discoveryFailed = false
    private var closed = false
    private var busy = false
    private var pairingChallenges: [String: (id: String, expires: Date, attempts: Int)] = [:]
    private let statusLabel = UILabel()
    private lazy var remoteHost = UIHostingController(rootView: TvRemoteView())
    private var remoteObservation: AnyCancellable?
    private var hasPlayback: Bool { payload["url"] is String }
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        config.httpShouldSetCookies = false
        config.urlCache = nil
        return URLSession(configuration: config, delegate: TvSessionDelegate(), delegateQueue: nil)
    }()

    init(payload: [String: Any]) {
        self.payload = payload
        super.init(style: .insetGrouped)
        title = payload["url"] is String ? "Play on TV" : "Remote"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(close))
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .refresh, target: self, action: #selector(search))
        statusLabel.numberOfLines = 0
        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.accessibilityTraits = .updatesFrequently
        addChild(remoteHost)
        remoteHost.view.backgroundColor = .clear
        remoteHost.didMove(toParent: self)
        remoteObservation = AndroidTvRemote.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.layoutStatus(); self?.tableView.reloadData() }
        }
        search()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if navigationController?.isBeingDismissed == true || isBeingDismissed {
            stop()
        }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutStatus()
    }
    deinit { browser.stop(); services.forEach { $0.stop() }; session.invalidateAndCancel() }

    @objc private func close() { stop(); dismiss(animated: true) }
    private func stop() {
        closed = true
        automaticPlayback.suppress(); automaticPlaybackWork?.cancel()
        operation?.cancel()
        browser.stop()
        services.forEach { $0.stop() }
        preparation?.cancel()
        AndroidTvRemote.shared.stopDiscovery()
    }

    @objc private func search() {
        guard !busy else { return }
        preparation?.cancel()
        launchedHost = nil
        automaticPlaybackWork?.cancel()
        unresolvedServices.removeAll(); moreServicesComing = false; discoveryFailed = false
        AndroidTvRemote.shared.refresh()
        browser.stop()
        services.forEach { $0.stop() }
        services.removeAll()
        devices.removeAll()
        tableView.reloadData()
        if !hasPlayback { setStatus(""); return }
        setStatus("Looking for your TV…\nConnect both devices to the same Wi-Fi. Nuvio will open automatically if needed.")
        browser.delegate = self
        browser.searchForServices(ofType: "_nuvio-tv._tcp.", inDomain: "local.")
        preparePlayback()
    }

    /// Prefer the running companion; only launch through the already paired
    /// Android TV remote when no Nuvio companion answers discovery.
    private func preparePlayback() {
        preparation = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // Allow the initial Bonjour batch to arrive before launching.
                try await Task.sleep(nanoseconds: 2_000_000_000)
                guard !closed, !busy, !automaticPlayback.attempted, devices.isEmpty else { return }
                let remote = AndroidTvRemote.shared
                setStatus("Connecting to your TV…")
                for _ in 0..<100 {
                    try Task.checkCancellation()
                    guard devices.isEmpty, !busy, !closed else { return }
                    if remote.connected { break }
                    if remote.selected != nil && !remote.isPaired { break }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                // Discovery can finish while the remote is connecting. Do not
                // launch another TV or report a remote error once Nuvio is ready.
                guard devices.isEmpty, !closed, !busy, !automaticPlayback.attempted else { return }
                guard remote.isPaired else {
                    throw TvError.message("Pair your TV remote below once to enable automatic Nuvio launch, then tap Refresh.")
                }
                guard remote.connected else {
                    throw TvError.message("Couldn’t reach your TV. Make sure it is on and connected to the same Wi-Fi, then tap Refresh.")
                }
                try Task.checkCancellation()
                guard remote.isOn != false else {
                    throw TvError.message("Your TV is in standby. Turn it on, then tap Refresh.")
                }
                launchedHost = remote.selected?.host
                guard remote.launchNuvio() else {
                    throw TvError.message("This TV doesn’t support launching Nuvio remotely. Open Nuvio on the TV, then tap Refresh.")
                }
                setStatus("Opening Nuvio on your TV… Waiting for it to be ready.")
                // Discovery readiness replaces a fixed startup delay. The /info
                // check in startPlayback then verifies the service before sending.
                for _ in 0..<200 {
                    try await Task.sleep(nanoseconds: 100_000_000)
                    guard !closed, !busy else { return }
                    if devices.contains(where: { matchesLaunchTarget($0) }) { return }
                }
                throw TvError.message("Nuvio didn’t become ready on your TV. Check that the updated Nuvio TV app is installed and both devices are on the same Wi-Fi, then tap Refresh.")
            } catch is CancellationError { }
            catch {
                guard !closed, !Task.isCancelled else { return }
                showPlaybackError(error)
            }
        }
    }

    private func showPlaybackError(_ error: Error) {
        setStatus(error.localizedDescription + "\nTap Refresh or select a TV to try again.")
        guard !closed, presentedViewController == nil else { return }
        let alert = UIAlertController(title: "Couldn’t play on TV", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func matchesLaunchTarget(_ device: Device) -> Bool {
        launchedHost == nil || device.baseURL.host?.caseInsensitiveCompare(launchedHost!) == .orderedSame
    }

    private func setStatus(_ text: String) {
        statusLabel.text = text
        layoutStatus()
    }

    private func layoutStatus() {
        let width = tableView.bounds.width
        guard width > 48 else { return }
        let statusHeight: CGFloat = (statusLabel.text ?? "").isEmpty ? 12 : statusLabel.sizeThatFits(CGSize(width: width - 48, height: .greatestFiniteMagnitude)).height + 36
        let remoteSize = remoteHost.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        let height = statusHeight + remoteSize.height
        let footer = tableView.tableFooterView ?? UIView()
        statusLabel.frame = CGRect(x: 24, y: 12, width: width - 48, height: max(0, statusHeight - 24))
        if statusLabel.superview !== footer { footer.addSubview(statusLabel) }
        if remoteHost.view.superview !== footer { footer.addSubview(remoteHost.view) }
        remoteHost.view.frame = CGRect(x: 0, y: statusHeight, width: width, height: remoteSize.height)
        if abs(footer.frame.height - height) > 1 || footer.frame.width != width || tableView.tableFooterView == nil {
            footer.frame.size = CGSize(width: width, height: height)
            tableView.tableFooterView = footer
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service)
        unresolvedServices.insert(ObjectIdentifier(service))
        moreServicesComing = moreComing
        scheduleAutomaticPlayback()
        service.delegate = self
        service.resolve(withTimeout: 8)
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        services.removeAll { $0 == service }
        unresolvedServices.remove(ObjectIdentifier(service))
        moreServicesComing = moreComing
        service.stop()
        devices.removeAll { $0.name == service.name }
        tableView.reloadData()
        scheduleAutomaticPlayback()
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        discoveryFailed = true; automaticPlaybackWork?.cancel()
        setStatus("TV discovery is unavailable. Allow Local Network access for Nuvio in iPhone Settings, then tap Refresh.")
    }
    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        unresolvedServices.remove(ObjectIdentifier(sender))
        discoveryFailed = true
        automaticPlaybackWork?.cancel()
    }
    func netServiceDidResolveAddress(_ sender: NetService) {
        guard services.contains(sender), !closed else { return }
        unresolvedServices.remove(ObjectIdentifier(sender))
        defer { scheduleAutomaticPlayback() }
        guard let host = sender.hostName, sender.port > 0,
              let txt = sender.txtRecordData() else { return }
        let attributes = NetService.dictionary(fromTXTRecord: txt)
        guard let idData = attributes["id"], let id = String(data: idData, encoding: .utf8),
              UUID(uuidString: id) != nil,
              let version = attributes["version"], String(data: version, encoding: .utf8) == "1" else { return }
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = sender.port
        guard let baseURL = components.url else { return }
        devices.removeAll { $0.id == id }
        devices.append(Device(id: id, name: sender.name, baseURL: baseURL))
        let last = UserDefaults.standard.string(forKey: "NuvioLastTV")
        devices.sort {
            if ($0.id == last) != ($1.id == last) { return $0.id == last }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        tableView.reloadData()
        if !busy, !automaticPlayback.attempted { setStatus("Choose a TV to start playing. Your iPhone can be locked once playback starts.") }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { devices.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let device = devices[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = device.name
        cell.imageView?.image = UIImage(systemName: "tv")
        cell.detailTextLabel?.text = TvCredentials.token(for: device.id) == nil ? "Pair and play" : "Paired · Ready to play"
        cell.accessoryType = UserDefaults.standard.string(forKey: "NuvioLastTV") == device.id ? .checkmark : .none
        return cell
    }
    private func scheduleAutomaticPlayback() {
        automaticPlaybackWork?.cancel()
        guard hasPlayback, !automaticPlayback.attempted, !closed, !discoveryFailed else { return }
        // Bonjour arrives incrementally. Let discovery settle and all known
        // services resolve before deciding there is exactly one available TV.
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.discoveryFailed else { return }
            let device = self.devices.first
            let paired = device.flatMap { TvCredentials.token(for: $0.id) } != nil
            guard device.map({ self.matchesLaunchTarget($0) }) == true else { return }
            guard self.automaticPlayback.claim(
                hasPlayback: self.hasPlayback, deviceCount: self.devices.count,
                serviceCount: self.services.count, unresolvedCount: self.unresolvedServices.count,
                moreComing: self.moreServicesComing, paired: paired, busy: self.busy,
                active: !self.closed && UIApplication.shared.applicationState == .active
            ), let device else { return }
            self.startPlayback(on: device)
        }
        automaticPlaybackWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !busy else { return }
        startPlayback(on: devices[indexPath.row])
    }
    private func startPlayback(on device: Device) {
        guard !busy, !closed else { return }
        preparation?.cancel()
        automaticPlayback.suppress(); automaticPlaybackWork?.cancel()
        if let host = device.baseURL.host { AndroidTvRemote.shared.selectCompanion(host: host) }
        run { [self] in
            setStatus("Connecting to \(device.name)…")
            let info = try await request(device, path: "info")
            guard info["id"] as? String == device.id, info["version"] as? Int == 1 else {
                throw TvError.message("This TV uses an incompatible Nuvio companion version.")
            }
            if let token = TvCredentials.token(for: device.id) {
                do { try await play(on: device, token: token) }
                catch TvError.unauthorized { try await beginPairing(device) }
            } else { try await beginPairing(device) }
        }
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        busy = true
        navigationItem.rightBarButtonItem?.isEnabled = false
        navigationController?.isModalInPresentation = true
        operation = Task { @MainActor [weak self] in
            guard let self = self else { return }
            defer {
                self.busy = false
                self.navigationItem.rightBarButtonItem?.isEnabled = true
                self.navigationController?.isModalInPresentation = false
            }
            do { try await work() }
            catch is CancellationError { }
            catch {
                if !Task.isCancelled { self.showPlaybackError(error) }
            }
        }
    }

    private func beginPairing(_ device: Device) async throws {
        let challenge: String
        if let pending = pairingChallenges[device.id], pending.expires > Date(), pending.attempts < 5 {
            challenge = pending.id
        } else {
            let result = try await request(device, path: "pair/start", body: [:])
            guard let id = result["challengeId"] as? String else { throw TvError.message("The TV couldn’t start pairing.") }
            challenge = id
            pairingChallenges[device.id] = (id, Date().addingTimeInterval(120), 0)
        }
        setStatus("Enter the code shown on \(device.name).")
        let alert = UIAlertController(title: "Pair with TV", message: "Enter the 6-digit code displayed on your TV.", preferredStyle: .alert)
        alert.addTextField { field in
            field.keyboardType = .numberPad
            field.placeholder = "6-digit code"
            field.textContentType = .oneTimeCode
            field.accessibilityLabel = "TV pairing code"
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in self?.setStatus("Pairing cancelled. Select a TV when you’re ready.") })
        alert.addAction(UIAlertAction(title: "Pair and Play", style: .default) { [weak self, weak alert] _ in
            guard let self = self else { return }
            let code = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self.run {
                guard code.count == 6 && code.allSatisfy(\.isNumber) else { throw TvError.message("Enter the 6-digit code shown on the TV.") }
                if var pending = self.pairingChallenges[device.id] {
                    pending.attempts += 1
                    self.pairingChallenges[device.id] = pending
                }
                let result = try await self.request(device, path: "pair", body: ["challengeId": challenge, "code": code])
                guard let token = result["token"] as? String else { throw TvError.message("Pairing failed. Please try again.") }
                self.pairingChallenges.removeValue(forKey: device.id)
                try TvCredentials.save(token, for: device.id)
                self.tableView.reloadData()
                try await self.play(on: device, token: token)
            }
        })
        present(alert, animated: true)
    }

    private func play(on device: Device, token: String) async throws {
        var body = payload
        let id = UUID().uuidString.lowercased()
        body["requestId"] = id
        setStatus("Starting playback on \(device.name)…")
        _ = try await request(device, path: "play", token: token, body: body)
        UserDefaults.standard.set(device.id, forKey: "NuvioLastTV")
        if let host = device.baseURL.host { AndroidTvRemote.shared.selectCompanion(host: host) }
        for _ in 0..<45 {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let status = try await request(device, path: "play/\(id)", token: token)
            switch status["state"] as? String {
            case "playing":
                setStatus("Playing on \(device.name).\nYou can close this screen or lock your iPhone.")
                tableView.reloadData()
                return
            case "error": throw TvError.message("The TV couldn’t play this stream. Check the TV or try another source.")
            case "stopped": throw TvError.message("Playback was cancelled on the TV.")
            default: break
            }
        }
        setStatus("The TV received the stream, but hasn’t confirmed playback yet. Check the TV before sending it again.")
    }

    private func request(_ device: Device, path: String, token: String? = nil, body: [String: Any]? = nil) async throws -> [String: Any] {
        try Task.checkCancellation()
        var request = URLRequest(url: device.baseURL.appendingPathComponent("v1/" + path))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let token = token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let body = body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, data.count <= 65536 else { throw TvError.message("Invalid response from TV.") }
        let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if http.statusCode == 401 { throw TvError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw TvError.message(result["error"] as? String ?? "The TV couldn’t accept this request.")
        }
        return result
    }
}
