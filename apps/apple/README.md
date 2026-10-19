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

The CLI sends notifications through the Expo push service to tokens registered at
`/v1/push-tokens`. The app converts its APNs token into an Expo token for its own Expo project,
so pushes need:

1. An Expo project (expo.dev) with an iOS APNs key (`.p8`) of the signing team for bundle id
   `com.devmanny.happier` under Credentials. The same key also delivers to the Mac app.
2. That project's id in `HAPPIER_EXPO_PROJECT_ID` in `project.yml`. With it empty, the app skips
   registration.

Development-signed builds register as APNs sandbox tokens; Developer ID/App Store builds as production.

## Current scope

Sign in by linking from another device (QR) or with the secret key; session list; chat with
Markdown, thinking, tool calls, inline permission approval, agent questions, stop and archive;
new sessions on a machine; attachments; dictation; push notifications.
Not yet: voice, artifacts, file diffs.
