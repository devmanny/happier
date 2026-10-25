# Happier for iOS & macOS (native)

A SwiftUI client for iPhone, iPad and Mac with Messages-style chats. It talks to the same
Happier server and end-to-end encryption as `apps/ui`, so sessions started from the CLI show up here.

## Layout

| Path | What |
| --- | --- |
| `HappierKit/` | Swift package: crypto, auth, HTTP/Socket.IO sync, transcript reducer. Testable with `swift test`. |
| `Happier/` | The multiplatform SwiftUI app. |
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

## Current scope

Sign in by linking from another device (QR) or with the secret key; session list; chat with
Markdown, thinking, tool calls, inline permission approval, agent questions, stop and archive;
new sessions on a machine; attachments; dictation; push notifications.
Not yet: voice, artifacts, file diffs.
