<div align="center">

  <img src="https://nuvio.tv/assets/nuvio-app-logo-wordmark.webp" alt="Nuvio" width="320" />

  <p>
    A free, open-source media app for your phone, your desktop, and the TV you already own.
    <br />
    Bring your own sources. Nuvio turns them into a library with artwork, ratings, subtitles, and your place saved on every screen.
  </p>

  [Website](https://nuvio.tv) · [GitHub releases](https://github.com/NuvioMedia/NuvioMobile/releases/latest) · [Support Nuvio](https://nuvio.tv/support)

</div>

## Get Nuvio Mobile

- [Android on Google Play](https://play.google.com/store/apps/details?id=com.nuvio.app)
- [Android APK](https://github.com/NuvioMedia/NuvioMobile/releases/latest)
- iOS via AltStore or SideStore: add [this source URL](https://raw.githubusercontent.com/NuvioMedia/NuvioMobile/cmp-rewrite/store.json) in the app's Sources section, then install Nuvio.

## Play on TV

On iOS, tap the TV button at the right of a stream, or hold the stream and choose
**Play on TV**. Keep both devices on the same Wi-Fi and allow Local Network access.
If Nuvio TV is already available, one paired TV starts playing automatically.
Otherwise, the app uses your saved Android TV Remote pairing to launch Nuvio TV
and waits for its companion service to become ready. Pair the remote once in the
Remote screen to enable this launch shortcut. A TV in standby or an unreachable
TV shows an error; it is not automatically powered on.

The first companion connection requires selecting your TV and entering the code
shown on it. Multiple available TVs require selection. Pairings are remembered.
The TV plays directly, so the phone can lock once playback starts. Supports direct
HTTP/HTTPS streams and debrid links resolved to HTTP/HTTPS. Both apps need builds
containing the companion feature.

## Build from source

```bash
git clone https://github.com/NuvioMedia/NuvioMobile.git
cd NuvioMobile
```

### Android

Android development requires Android Studio and the Android SDK.

```bash
./gradlew :androidApp:assembleFullDebug
```

### iOS

iOS development requires macOS and Xcode.

```bash
env NUVIO_IOS_DISTRIBUTION=full xcodebuild \
  -project iosApp/iosApp.xcodeproj \
  -scheme iosApp \
  -configuration Debug \
  -sdk iphonesimulator \
  -derivedDataPath build/ios-derived-full-simulator \
  CODE_SIGNING_ALLOWED=NO \
  build
```

The shared app is built with Kotlin Multiplatform and Compose Multiplatform.


## Trakt and IntroDB in custom builds

IntroDB reads use `https://api.introdb.app/` by default, with no API key required.
An optional `INTRODB_API_URL` in local.properties overrides that endpoint; a blank
value keeps the public default. Skip Intro must be enabled in player settings,
and buttons appear only when IntroDB has timestamps for the selected episode.

Trakt requires a client ID from your own application at
https://developer.trakt.tv/apps. Add these to the ignored `local.properties`:

```properties
TRAKT_CLIENT_ID=your-client-id
TRAKT_REDIRECT_URI=http://localhost
```

New Trakt applications do not issue a client secret. Both apps support Trakt's
device-code flow with just the client ID: open Trakt settings, connect, and enter
the displayed code on the Trakt approval page. A Development application limits
sign-in to its owner and added members; its registered redirect URI can be
`http://localhost` (unused during device approval, sent during token refresh).
The iOS build retains its previous browser callback flow for legacy applications
that configure a client secret.

For GitHub's **Build Test IPA** workflow, add repository Actions variables
`TRAKT_CLIENT_ID` and `TRAKT_REDIRECT_URI`. A `TRAKT_CLIENT_ID` Actions secret is
also supported for existing setups. Keep access tokens and legacy client secrets
out of commits and logs. Rebuild and reinstall after changing configuration.

## License

[GNU General Public License v3.0](./LICENSE)


### iPhone TV remote

The **Remote** bottom-bar action opens the same drawer used by **Play on TV**.
It provides a directional pad, OK, back, home, a horizontal volume slider, standby/wake, keyboard,
and **Launch Nuvio TV**. A green dot means the control connection is live;
**Paired** alone means saved credentials, not an online TV.

The remote uses Android TV Remote Service v2 on the local network. Pair it once
with the six-character code displayed by the TV. This system pairing is separate
from Nuvio's stream-sharing pairing. Private client keys and authenticated TV
certificates stay in the iPhone Keychain. The TV app need not remain open for
remote commands. Launch requires the companion-enabled TV build with the
`nuvio-tv://home` intent filter. Wake requires the TV's network/remote service to
remain reachable during standby; this cannot turn on a TV disconnected from power.

Select a text field on the TV, then use the keyboard button and **Send to TV**.
Text uses the remote service's current input-field counters and UTF-16 positions;
apps with custom input controls may not support it. **Enter / Search** submits the
field. No ADB connection is used by the iPhone app.

Protocol interoperability references: Google's Polo pairing schema and
[androidtvremote2](https://github.com/tronikos/androidtvremote2) (Apache-2.0).
Run `swiftc iosApp/iosApp/AndroidTvProtocol.swift iosApp/iosApp/TvCompanionBehavior.swift scripts/test-tv-remote.swift -o /tmp/nuvio-remote-tests && /tmp/nuvio-remote-tests`
on macOS for packet, framing, parser-boundary, Unicode and RSA-input checks.


In iOS 0.6.6 (build 151), **Play on TV** automatically sends the selected stream
when discovery settles on exactly one available, already-paired Nuvio TV. Multiple
TVs still require a choice; unpaired TVs still require the on-TV pairing code.
Each drawer can make only one automatic attempt, so discovery updates and Refresh
do not replay a stream. The **Remote** tab never sends media by itself.

The volume slider uses the TV's reported range and follows confirmed volume
changes, including adjustments from the physical remote. Changes are coalesced
while dragging, and small calibrated key batches stop at the nearest supported
hardware level. The slider is unavailable until the TV reports its volume range.
