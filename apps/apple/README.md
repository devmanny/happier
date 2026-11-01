# Happier for iOS & macOS (native)

A SwiftUI client for iPhone, iPad and Mac with Messages-style chats. It talks to the same
Happier server and end-to-end encryption as `apps/ui`, so sessions started from the CLI show up here.

## Layout

| Path | What |
| --- | --- |
| `HappierKit/` | Swift package: crypto, auth, HTTP/Socket.IO sync, transcript reducer. Testable with `swift test`. |
| `Happier/` | The multiplatform SwiftUI app. |
| `HappierWidgets/`, `HappierShare/` | Home Screen widgets and the share extension (iOS and macOS). |
| `HappierWatch/`, `HappierWatchWidgets/` | The Apple Watch app and its complications, embedded in the iPhone app. |
| `project.yml` | XcodeGen spec; `Happier.xcodeproj` is generated and not committed. |

## Build

```sh
brew install xcodegen
cd apps/apple
xcodegen generate
open Happier.xcodeproj          # Run the "Happier" scheme on My Mac or an iPhone
(cd HappierKit && swift test)   # unit tests
(cd HappierKit && HAPPIER_LIVE_SERVER=https://api.happier.dev swift test --filter LiveServerTests)
```

## Passkeys in the iOS browser

The integrated browser uses WebKit's WebAuthn implementation and the system credential picker.
Passkeys stay in Apple Passwords or the user's credential provider. Happier does not implement
a JavaScript credential bridge or store private keys. Authentication requires the user to show
the tab and complete the system prompt.

**Status: entitlement request submitted; Apple approval and physical-device authentication validation remain pending.**
The ordinary `project.yml` does not request restricted browser capabilities. To use passkeys for
third-party sites such as Google, GitHub and Vercel in `WKWebView`, first obtain Apple's
`com.apple.developer.web-browser` managed entitlement for `com.devmanny.happier`:

1. Review [Apple's browser requirements](https://developer.apple.com/documentation/xcode/preparing-your-app-to-be-the-default-browser)
   and submit the [default browser entitlement request](https://developer.apple.com/contact/request/default-browser-entitlement/).
   Apple decides whether Happier qualifies; generating this project does not grant access.
2. Once granted, enable the capability for the App ID and refresh the development/distribution
   provisioning profiles. The profile and the app's signature must both contain the entitlement.
3. Generate the optional iOS project and build with that approved signing configuration:

   ```sh
   cd apps/apple
   xcodegen generate --spec project.browser-ios.yml
   open Happier.xcodeproj
   ```

This variant registers HTTP/HTTPS links and opens the browser on launch, including before
Happier sign-in. Incoming websites open in user-owned tabs. Existing native session, inbox,
new-session and share URLs retain their destinations.

Apple ignores a browser app's Universal Link claims, so this variant omits the app's associated
domains. A session's HTTPS link opens its landing page in the chosen browser; **Open in Happier Native**
uses the existing `happier-native://session/...` URL. Happier's browser variant also renders that
landing page for an incoming HTTPS link; opening the session natively requires that explicit
action. The ordinary app retains direct session Universal Links. The usual relay-switch
confirmation still applies.
The browser variant hides **Open in Default Browser**, which could otherwise reopen the same app.

Run `xcodegen generate --spec project.yml` to return to the ordinary iOS/macOS project. This
preparation covers iOS/iPadOS. macOS requires its separate
[`com.apple.developer.web-browser.public-key-credential`](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.web-browser.public-key-credential)
approval and is not enabled by the iOS spec.

### Apple entitlement request

Use the signing identity from `project.yml`: display name **Happier**
(**Happier Native** in App Store Connect), bundle ID
`com.devmanny.happier`, development team `DPF7ZLTLN2`. Confirm the same team is selected
in Apple Developer before submitting. Request `com.apple.developer.web-browser`;
the separate app-installation entitlement is not needed for this passkey work.

Apple confirmed receipt on **2026-11-01**, request ID **QHLPSLWXM8**. Receipt does not
grant the entitlement. Wait for Apple's decision before updating provisioning.

Request rationale (summary of the submitted explanation):

> We are preparing an iOS/iPadOS browser configuration for our native Happier client,
> a companion for coding-agent sessions. Its integrated, tabbed browser uses the
> system WKWebView to let people browse websites and authenticate to developer
> services such as Google, GitHub and Vercel. The browser configuration presents an
> address field on launch, including before Happier sign-in, and registers HTTP and
> HTTPS URLs. We request the default-browser entitlement to support this browser
> configuration and WebKit's native WebAuthn flows for third-party websites.
> Credential selection and verification stay in the system interface; Happier does
> not implement a JavaScript passkey bridge or store passkey private keys. This
> configuration still requires validation on a signed, entitled physical device.

The submitted request identifies the existing app as an internal TestFlight build and
clarifies that the browser-entitled configuration is not yet distributed. It does not
claim App Store availability or successful passkey authentication on a physical device.

### Validation

Validation commands:

```sh
python3 -m unittest discover -s tests -v
(cd HappierKit && swift test --filter 'AppLinkTests|SessionLinkTests|DeviceBrowser')
```

Before claiming passkey support, test the **signed, entitled build on a physical device** with
a configured passkey provider. Open each of Google, GitHub and Vercel in a visible browser tab;
select an existing passkey, complete Face ID/device verification, and verify successful sign-in
and session persistence after relaunch. Also cancel the prompt, retry, and exercise a site's
alternative sign-in method. Test session landing links from Safari and native widget links,
with Happier selected and unselected as the default browser. Host tests and a simulator build
do not prove that Apple grants access or that the sites accept authentication.

References: [WebKit's entitlement restriction](https://bugs.webkit.org/show_bug.cgi?id=250912),
[Apple's passkey support for browsers](https://developer.apple.com/documentation/authenticationservices/passkey-use-in-web-browsers).

## Protocol mapping

Each Swift module follows the TypeScript owner it mirrors; check that owner when the protocol changes.

| Swift | Canonical owner |
| --- | --- |
| `Crypto/*` | `packages/protocol/src/crypto`, `apps/ui/sources/encryption`, `docs/encryption.md` (golden vectors in tests) |
| `Auth/*` | `apps/ui/sources/auth/flows`, `buildAccountLinkResponse.ts`, `secretKeyBackup.ts` |
| `Realtime/*` | Socket.IO v4 at `/v1/updates` (`docs/protocol.md`) |
| `Transcript/*` | `apps/ui/sources/sync/typesRaw/normalize.ts`, `apps/ui/sources/sync/reducer/**` |
| `Sync/HappierStore` | `apps/ui/sources/sync/**` (sessions v2 list, messages paging, pending queue v2, session RPC) |
| `Sync/PermissionReply` | `PermissionFooter.tsx`, `apps/cli/src/agent/permissions/**` |
| `Push/*` | `apps/cli/src/api/pushNotifications.ts`, `apps/ui/sources/activity/notifications/notificationRouting.ts` |

## Push notifications

The CLI sends notifications to the tokens registered at `/v1/push-tokens`. This app registers
`apns:<sandbox|production>:<bundle id>:<device token>`, which the CLI delivers directly through
APNs (`apps/cli/src/api/apnsPush.ts`); Expo tokens from the React Native app still go through Expo.

Each machine that runs sessions needs an APNs auth key of the signing team:

```sh
# ~/.happier/AuthKey.p8 is the key downloaded from developer.apple.com → Keys (APNs enabled)
echo '{"keyId":"<KEY ID>","teamId":"DPF7ZLTLN2","keyPath":"AuthKey.p8"}' > ~/.happier/apns.json
```

Without it the CLI skips `apns:` tokens. Development-signed builds register sandbox tokens;
Developer ID/App Store builds production ones.

## Apple Watch

The watch keeps no account keys and never talks to the relay: the iPhone app is its only source.
`AttentionWidgetPublisher` sends it the same two snapshots the Home Screen widgets read
(`AttentionSnapshot` with the first pending request and the agent's last words, `ActivitySnapshot`)
as the WatchConnectivity application context; the watch app saves them in the App Group for its
complications (Needs You, Working Now, Usage). Allow/Deny, a dictated reply and a dictated new
session go back as `WatchMessage`s; the iPhone answers them through `HappierStore.handle(PushTap)`
(the notification buttons' path, which signs in from the saved credentials when woken in the
background) and `QuickSessionStart` → `createSession` with the agent, model, effort, machine and
folder the new-session screen last used (`NewSessionDefaults`). "New session in Happier" is also
an App Shortcut on both the iPhone and the watch (Siri, Shortcuts, the Ultra's Action button).

## Current scope

Sign in by linking from another device (QR) or with the secret key; session list; chat with
Markdown, thinking, tool calls, inline permission approval, agent questions, stop and archive;
new sessions on a machine; attachments; dictation; push notifications.
Not yet: voice, artifacts, file diffs.
