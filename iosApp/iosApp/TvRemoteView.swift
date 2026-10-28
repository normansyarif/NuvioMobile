import SwiftUI
import UIKit

struct TvRemoteView: View {
    @ObservedObject private var remote = AndroidTvRemote.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var keyboardPresented = false
    @State private var code = ""

    var body: some View {
        VStack(spacing: 22) {
            HStack(spacing: 12) {
                Image(systemName: "appletvremote.gen4.fill").font(.title2)
                Menu {
                    ForEach(remote.devices) { device in
                        Button(device.name) { remote.connect(device) }
                    }
                    Button("Refresh TVs", systemImage: "arrow.clockwise") { remote.refresh() }
                } label: {
                    HStack(spacing: 6) {
                        Text(remote.selected?.name ?? "Choose a TV").font(.headline).lineLimit(1)
                        Image(systemName: "chevron.down").font(.caption.bold())
                    }
                }
                .accessibilityLabel("Choose remote TV")
                Spacer(minLength: 0)
                Circle().fill(remote.connected ? Color.green : Color.gray).frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(remote.connected ? "Connected" : (remote.isPaired ? "Paired" : "Not paired"))
                    .font(.caption.weight(.medium)).foregroundStyle(remote.connected ? .green : .secondary)
            }
            .foregroundStyle(.primary)

            if remote.state == .pairing || remote.state == .enteringCode {
                pairing
            } else if !remote.connected {
                VStack(spacing: 14) {
                    Text(remote.message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if remote.state == .connecting { ProgressView().tint(.white) }
                    else {
                        HStack(spacing: 14) {
                            if remote.isPaired, let selected = remote.selected {
                                Button("Connect") { remote.connect(selected) }.buttonStyle(.borderedProminent)
                            }
                            Button(remote.isPaired ? "Pair again" : "Pair remote") { remote.pair() }
                                .buttonStyle(.bordered).disabled(remote.selected == nil)
                        }
                    }
                    if !remote.isPaired {
                        Text("Pair once using the code on your TV. Nuvio doesn’t need to stay open on the TV.")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                }
            } else {
                Text(remote.message).font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                roundButton("Keyboard", symbol: "keyboard", enabled: remote.connected && remote.supportsKeyboard) { keyboardPresented = true }
                Spacer()
                roundButton(remote.isOn == false ? "Wake TV" : "Power", symbol: "power", enabled: remote.connected && remote.supportsPower) { remote.power() }
            }

            dpad
                .disabled(!remote.connected)
                .opacity(remote.connected ? 1 : 0.4)

            HStack(alignment: .center, spacing: 22) {
                roundButton("Back", symbol: "chevron.backward", size: 64) { remote.key(4) }
                roundButton("Home", symbol: "house", size: 64) { remote.key(3) }
                Spacer(minLength: 0)
                VStack(spacing: 0) {
                    Button { feedback(); remote.key(24) } label: {
                        Image(systemName: "plus").font(.title3.weight(.medium)).frame(width: 64, height: 47)
                    }.accessibilityLabel("Volume up")
                    Image(systemName: "speaker.wave.2").font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
                    Button { feedback(); remote.key(25) } label: {
                        Image(systemName: "minus").font(.title3.weight(.medium)).frame(width: 64, height: 47)
                    }.accessibilityLabel("Volume down")
                }
                .background(.white.opacity(0.075), in: Capsule())
                .disabled(!remote.connected || !remote.supportsVolume)
            }
            .disabled(!remote.connected)
            .opacity(remote.connected ? 1 : 0.4)

            Button { feedback(); remote.launchNuvio() } label: {
                Label("Launch Nuvio TV", systemImage: "tv")
                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 15)
                    .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 18))
            }
            .disabled(!remote.connected || !remote.supportsAppLaunch)
            if let volume = remote.volume, remote.connected {
                Text("Volume · \(volume)").font(.caption).foregroundStyle(.secondary)
            }
            if remote.isOn == false {
                Text("Wake works while your TV keeps its network connection in standby.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(24)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 30))
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
        .preferredColorScheme(.dark)
        .onAppear { remote.resume() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { remote.resume() }
            else if phase == .background { remote.suspend() }
        }
        .sheet(isPresented: $keyboardPresented) { TvKeyboardView(remote: remote) }
    }
    private var pairing: some View {
        VStack(spacing: 14) {
            Text(remote.message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if remote.state == .enteringCode {
                TextField("6-character TV code", text: $code)
                    .font(.title2.monospaced()).multilineTextAlignment(.center)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    .keyboardType(.asciiCapable).textContentType(.oneTimeCode)
                    .padding(12).background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("TV remote pairing code")
                Button("Pair") { remote.pairingCode = code; remote.submitCode() }.buttonStyle(.borderedProminent)
            } else { ProgressView().tint(.white) }
            Button("Cancel pairing") { code = ""; remote.cancelPairing() }.font(.subheadline)
        }
    }
    private var dpad: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 46).fill(.white.opacity(0.065))
            VStack(spacing: 0) {
                direction("Up", symbol: "chevron.up", code: 19).frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack(spacing: 0) {
                    direction("Left", symbol: "chevron.left", code: 21).frame(maxWidth: .infinity, maxHeight: .infinity)
                    Button { feedback(); remote.key(23) } label: {
                        Text("OK").font(.title3.weight(.semibold)).frame(width: 90, height: 90)
                            .background(.white.opacity(0.09), in: Circle())
                    }.accessibilityLabel("Select / OK")
                    direction("Right", symbol: "chevron.right", code: 22).frame(maxWidth: .infinity, maxHeight: .infinity)
                }.frame(height: 90)
                direction("Down", symbol: "chevron.down", code: 20).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: 350).frame(height: 260)
        .accessibilityElement(children: .contain).accessibilityLabel("TV navigation")
    }
    private func direction(_ label: String, symbol: String, code: UInt64) -> some View {
        Button { feedback(); remote.key(code) } label: {
            Image(systemName: symbol).font(.title2.weight(.medium)).frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
        }.accessibilityLabel(label)
    }
    private func roundButton(_ label: String, symbol: String, size: CGFloat = 48, enabled: Bool? = nil, action: @escaping () -> Void) -> some View {
        Button { feedback(); action() } label: {
            Image(systemName: symbol).font(.system(size: 21, weight: .medium))
                .frame(width: size, height: size).background(.white.opacity(0.075), in: Circle())
        }
        .accessibilityLabel(label).disabled(!(enabled ?? remote.connected))
    }
    private func feedback() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
}

private struct TvKeyboardView: View {
    @ObservedObject var remote: AndroidTvRemote
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Text to insert on TV", text: $text, axis: .vertical)
                        .lineLimit(1...6).focused($focused).autocorrectionDisabled()
                        .textInputAutocapitalization(.never).disabled(!remote.connected || !remote.fieldActive)
                        .accessibilityLabel("Text for the active TV field")
                    Button("Send to TV") { remote.sendText(text); text = "" }
                        .disabled(!remote.connected || !remote.fieldActive || text.isEmpty || text.utf8.count > 16_384)
                    Button("Backspace on TV", systemImage: "delete.left") { remote.key(67) }
                        .disabled(!remote.connected || !remote.fieldActive)
                    Button("Enter / Search") { remote.key(66) }.disabled(!remote.connected || !remote.fieldActive)
                } header: { Text(remote.fieldLabel) } footer: {
                    Text(remote.fieldActive ? "Send inserts text at the TV cursor. Backspace deletes on the TV; Enter / Search submits the field." : "Use the remote to select a text field on your TV first. Some apps use a custom keyboard that doesn’t accept remote text.")
                }
            }
            .navigationTitle("TV keyboard").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { focused = remote.fieldActive }
            .onChange(of: remote.fieldActive) { active in
                if active { focused = true }
                else { focused = false }
            }
        }.preferredColorScheme(.dark)
    }
}
