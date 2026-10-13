# iOS 17 backport (branch `ios17-backport`)

Minimal-change backport of the iOS app at tag `v2026.10.2` (commit `b8952d4`) so it
deploys to iOS 17.0. Base commit is intentionally the tag that matches the running
Gateway; do not rebase onto `main`.

## What changed and why

| Area | Change | Why |
| --- | --- | --- |
| `apps/ios/project.yml` | global `deploymentTarget.iOS` `18.0` -> `17.0` | Applies to every iOS target: app, Share extension, Activity widget, tests. watchOS (`11.0`) untouched. |
| `apps/shared/OpenClawKit/Package.swift` | `.iOS(.v18)` -> `.iOS(.v17)` | Package floor must not exceed the app. macOS/watchOS untouched. Other deps (ElevenLabsKit iOS 17, GRDB iOS 13, SwiftMath, swift-markdown, WebRTC, Sodium, Swabble iOS 17) already allow 17. |
| `OpenClawKit/CompatMutex.swift` (new) | `CompatMutex<Value>` backed by `OSAllocatedUnfairLock` (iOS 16+), same `init(_:)` / `withLock(_:)` shape as `Mutex` | `Synchronization.Mutex` is iOS 18+. Used in `GatewayChannel`, `GatewayWebSocketTransport`, `GatewayTLSPinning`, `DeviceIdentity`, `AsyncTimeout`, `ChatMessageMetadata` (only the type name changed at call sites). |
| `ChatViewModel`, `ChatSessionSidebarData`, `IOSDeviceSettingsBridge` | `isolated deinit` -> plain `deinit` (`MainActor.assumeIsolated` when on the main thread; direct `Task.cancel()` for the Sendable task) | `isolated deinit` needs the Swift 6.1 runtime (iOS 18.4+). macOS-only files keep `isolated deinit`. |
| `ChatView` / `ChatScrollCommand` | `onScrollGeometryChange` + `onScrollPhaseChange` moved into `ChatReaderScrollObserversModifier` behind `#available(iOS 18.0, *)`; `chatReaderScrollReleasesFollow` marked `@available(iOS 18.0, *)` | Both modifiers and `ScrollPhase` are iOS 18+. iOS 17 fallback: the reader always stays at the live edge, i.e. the transcript auto-follows the newest message. |
| `ChatTheme.desktopUserBubble` | `Color.mix(with:by:in:)` behind `#available(iOS 18.0, *)`; iOS 17 uses a 15% accent tint | `Color.mix` is iOS 18+ (desktop/iPad-wide layout only). |
| `DevicePermissions`, `ContactsService`, `GatewayConnectionController+Capabilities` | `CNAuthorizationStatus.limited` read through `isLimitedCompat` (availability-checked) | `.limited` contacts access is iOS 18+ (cannot occur on iOS 17). |
| `WatchMessageJournal.changes()` | returns GRDB's concrete `AsyncValueObservation<[OpenClawWatchMessageEntry]>` instead of `some AsyncSequence<_, any Error> & Sendable` | `AsyncSequence` primary associated types (`<Element, Failure>`) are iOS 18+. Call sites unchanged. |

Already safe on iOS 17 (verified, no change): all Liquid Glass / `glassEffect` /
`scrollEdgeEffectStyle` / `.glass` button styles are behind `#available(iOS 26.0, *)`;
`@Entry`, `onGeometryChange` (back-deployed), `onChange(of:initial:)`, `onKeyPress`,
`ContentUnavailableView`, `safeAreaPadding`, `contentMargins`, `symbolEffect(.replace)`,
`EKAuthorizationStatus.fullAccess/.writeOnly`, `AVAudioApplication`, `DataScannerViewController`,
`HKStatisticsQueryDescriptor`, App Intents / App Shortcuts used here, ActivityKit request API
(`pushType:` only), Observation. `presentationSizing` is macOS-only code. Swabble's
`SpeechAnalyzer` paths are already gated to iOS 26.

## Remaining risks (not verifiable without a compiler)

- **Compile-only verification pending.** All edits are static; expect a follow-up round for any
  diagnostics. Most likely spots: Swift 6 strict-concurrency diagnostics around the new `deinit`s
  (`MainActor.assumeIsolated` capturing `self`) and the `@MainActor` closures stored in
  `ChatReaderScrollObserversModifier`.
- **Missed iOS 18 APIs.** The scan was grep-based. If Xcode reports
  "`X` is only available in iOS 18.0 or newer", wrap it in `if #available(iOS 18.0, *)` the same way.
- **Deinit off the main thread.** If `OpenClawChatViewModel` or `IOSDeviceSettingsBridge` is ever
  released off the main thread, cleanup is skipped instead of hopping to the main actor
  (previous `isolated deinit` behaviour). Should not happen for SwiftUI-owned objects.
- **iOS 17 chat scrolling.** Without scroll geometry/phase callbacks the chat cannot detect that the
  user scrolled up, so while a reply streams it keeps snapping to the bottom, and the
  "jump to latest" affordance is driven only by explicit navigation (search, etc.).
- **`AVAudioSession.CategoryOptions.allowBluetoothHFP`** is the iOS 26 SDK spelling of the old
  `.allowBluetooth`. It compiled for iOS 18.0 so it should be back-available; if Xcode flags it for
  iOS 17, switch to `.allowBluetooth` there.
- SF Symbols that only exist in SF Symbols 6 (iOS 18) render blank on iOS 17 (no crash).
- `switch` over `CNAuthorizationStatus` without an explicit `.limited` case may produce a
  "switch must be exhaustive" **warning** (not an error; warnings are not treated as errors).
- Untested at runtime on an iOS 17 device: Live Activity widget, Share extension, Watch companion pairing.

## Build on the Mac (macOS 27 + Xcode 26.x)

Prerequisites (from `apps/ios/README.md` at this commit): Xcode 26.x with iOS + watchOS SDKs,
`pnpm`, `xcodegen` (`brew install xcodegen`), Node, the pinned Watch Rust toolchain, and the
pinned SwiftFormat 0.63.0 / SwiftLint 0.65.1 (the app target runs them as **pre-build lint
phases**, the build fails if they are missing or a different version).

```bash
# 1. Get a full checkout of this branch (the Pi checkout is sparse; push nothing upstream).
git clone https://github.com/openclaw/openclaw.git && cd openclaw
git fetch ssh://<pi-host>/home/mafu/src/openclaw ios17-backport:ios17-backport
git switch ios17-backport          # based on v2026.10.2 / b8952d4

# 2. JS deps (xcodegen preGenCommand runs scripts/prepare-apple-mermaid.mjs)
pnpm install

# 3. Pinned lint tools used by the Xcode pre-build phases
scripts/install-swift-tools.sh .build/swift-tools
export PATH="$PWD/.build/swift-tools:$PATH"

# 4. Watch companion (embedded by the OpenClaw scheme) needs the pinned Rust nightly
rustup toolchain install nightly-2026-09-05 --profile minimal --component rust-src
export PATH="$(brew --prefix rustup)/bin:$PATH"   # if rustup came from Homebrew

# 5. Signing for a personal team
cp apps/ios/LocalSigning.xcconfig.example apps/ios/LocalSigning.xcconfig
#    edit: OPENCLAW_DEVELOPMENT_TEAM = <your team id>, and unique bundle ids, e.g.
#    OPENCLAW_APP_BUNDLE_ID = com.<you>.openclaw (share/activitywidget/watchkitapp + app group to match)
#    (scripts/ios-configure-signing.sh also auto-writes apps/ios/.local-signing.xcconfig
#     from your Xcode team; LocalSigning.xcconfig is included after it and wins.)

# 6. Generate the project and open it
pnpm ios:gen        # = ios-configure-signing + version xcconfig + swift filelist + xcodegen generate
open apps/ios/OpenClaw.xcodeproj
#    or: pnpm ios:open
```

In Xcode: scheme `OpenClaw`, configuration **Debug**, destination = your iOS 17 iPhone, Run.
(CLI alternative: `IOS_DEST='platform=iOS,name=<iPhone>' pnpm ios:build`.)

If you do not need the Watch app and want to skip the Rust toolchain, locally remove the
`- target: OpenClawWatchApp` line from the `OpenClaw` target's `dependencies` in
`apps/ios/project.yml` before `pnpm ios:gen` (do not commit that).

### Push notifications (Debug = sandbox, direct APNs)

- Debug builds use `OpenClawPushMode=localSandbox`: direct APNs registration with the
  development `aps-environment` entitlement (Release = `localProduction`). The hosted relay is
  only for official App Store builds.
- Your team/profile must have Push Notifications enabled for the bundle ID you sign with.
- On the **Gateway host** (this Pi), set direct APNs credentials (names verified at this commit):

```bash
export OPENCLAW_APNS_TEAM_ID="TEAMID"
export OPENCLAW_APNS_KEY_ID="KEYID"
# either the key contents ...
export OPENCLAW_APNS_PRIVATE_KEY_P8="$(cat /path/to/AuthKey_KEYID.p8)"
# ... or a path (recommended storage: ~/.openclaw/credentials/apns/, chmod 600)
export OPENCLAW_APNS_PRIVATE_KEY_PATH="$HOME/.openclaw/credentials/apns/AuthKey_KEYID.p8"
```

Restart the Gateway after setting them, pair the app, then check `push.test` / Xcode logs
(`APNs registration failed` indicates an entitlement/provisioning problem).
