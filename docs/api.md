# API

This document covers the HTTP API surface and authentication flows. For WebSocket updates and event payloads, see `protocol.md`. For encryption boundaries and encoding details, see `encryption.md`.

## Method conventions
- **GET** is used for reads.
- **POST** is used for mutations or actions, even when the operation doesn't map cleanly to a single entity.
- **DELETE** is used when intent is unambiguous (e.g., removing a token or deleting a session/artifact).

We intentionally avoid the full REST verb palette because many operations span multiple entities or have non-CRUD semantics.

## Authentication
Most endpoints require `Authorization: Bearer <token>`.

Auth flows:
- `POST /v1/auth`
  - Body: `{ publicKey, challenge, signature }` (base64 strings)
  - Verifies signature using the provided public key.
  - Upserts account by public key and returns `{ success, token }`.

- `POST /v1/auth/request`
  - Body: `{ publicKey, supportsV2? }`
  - Creates or returns a terminal auth request.
  - Response: `{ state: "requested", expiresAt }` or `{ state: "authorized", token, response }`.
  - Development correction for #403: `expiresAt` is Unix time in milliseconds, computed from the persisted request creation time and effective server TTL. Repeating a pending request does not renew it. Older clients ignore this additive field; older servers omit it.
  - Current development CLIs cap pairing crypto validity by this deadline. `auth request --json` reports the effective `expiresAtMs` and `expiryNotice`; if the server omits expiry, `expiresAtMs` is `null` and the notice advises prompt approval and rerunning after failure. The nested `pairing.expiresAtMs` remains the crypto binding deadline, not a promise of server acceptance.

- `GET /v1/auth/request/status?publicKey=...`
  - Response: `{ status: "not_found" | "pending" | "authorized", supportsV2 }`.

- `POST /v1/auth/response`
  - Body: `{ response, publicKey }` (requires Bearer auth)
  - Approves a terminal auth request.

- `POST /v1/auth/account/request`
  - Body: `{ publicKey }`
  - Similar to terminal auth, but for account linking.

- `POST /v1/auth/account/response`
  - Body: `{ response, publicKey }` (requires Bearer auth)

- `POST /v1/auth/external/:provider/token-exchange`
  - Body: `{ accessToken }`: a JWT access token the caller obtained from the provider itself.
  - Off unless the provider's config has `tokenExchange.allowedClientIds` and keyless login is enabled for the provider.
  - The provider owns the token check (`OAuthFlowProvider.verifyExternalAccessToken`; OIDC: allowlisted client claim, then `/userinfo` with the token's subject claim as the expected `sub`). The route only signs in to an account already linked to that identity, refuses E2EE accounts (`409 restore-required`), and applies `enforceLoginEligibility`.
  - Response: `{ success, token }`.

## Endpoint catalog
### Sessions
- `GET /v1/sessions`
- `GET /v2/sessions/active?limit=...`
- `GET /v2/sessions?cursor=cursor_v1_<id>&limit=...&changedSince=...`
- `POST /v1/sessions` (create or load by `tag`)
- `GET /v1/sessions/:sessionId/messages`
- `DELETE /v1/sessions/:sessionId`

### Machines
- `POST /v1/machines` (create or load by id)
- `GET /v1/machines`
- `GET /v1/machines/:id`

### Artifacts
- `GET /v1/artifacts`
- `GET /v1/artifacts/:id`
- `POST /v1/artifacts`
- `POST /v1/artifacts/:id` (versioned update)
- `DELETE /v1/artifacts/:id`

### Access keys
- `GET /v1/access-keys/:sessionId/:machineId`
- `POST /v1/access-keys/:sessionId/:machineId`
- `PUT /v1/access-keys/:sessionId/:machineId`

### Key-value store
- `GET /v1/kv/:key`
- `GET /v1/kv?prefix=...&limit=...`
- `POST /v1/kv/bulk`
- `POST /v1/kv` (batch mutate)

Keys are clear text, so they stay opaque; everything readable lives in the sealed value
(account-scoped blob, `packages/protocol/src/crypto/accountScopedCipher.ts`). Current client-owned
prefixes:

- `agentprofile/<uuid>` — a user-defined Agent (name, emoji, description, provider/model/effort,
  account label and optional Claude config folder), kind `agent_profile`. Written by the native app.
  Builds before 2026-11-07 kept it at `agent/<uuid>/profile`, mixed with the agent's memory. Current
  builds read both places, copy a profile only the old place has (or that an old build edited later,
  by `updatedAt`) with a versioned write (concurrent migrations: one lands, the other re-reads), and
  keep the old key in step on edit/delete; the old key is never deleted by the migration. Drop the
  legacy read/write once no older build is installed.
  Optional `canDo: string[]` is what the user says the agent can do, shown on its card in the native
  app; written only when non-empty, each item trimmed and none blank (clearing the list removes the
  key). Only the native app reads and writes it: the daemon's passthrough `AgentProfileV1Schema`
  keeps it, and the spawn identity leaves it out, so the agent is never told. A future TypeScript
  reader must parse it leniently (drop non-string and blank items, read a malformed value as empty,
  never reject the profile over it), as the app does.
  A spawn carries only `agentIdentityV1` `{v, id, name, emoji?, description?}`; the runner keeps
  `{v, id, name, emoji?}` in session metadata `agentIdentityV1` and adds the description to the
  coding prompt (`packages/protocol/src/agentProfiles/agentIdentity.ts`).
- `presence/<sessionId>` — "who is where", kind `agent_presence`, written only by that session's
  runner while a turn runs (folder, task, files being edited, declared shared resources), refreshed
  every 60 s and ignored by readers after 3 min without a signal; removed when the turn ends.
  Advisory, never a lock (`packages/protocol/src/agentProfiles/agentPresence.ts`). Claude sessions
  on the Agent SDK runner get a pre-edit warning through a `PreToolUse` hook; Codex app-server in
  yolo mode exposes no pre-edit hook, so its patches are only recorded as they start. Agents can
  ask and declare resources with the `quien_esta_aqui` MCP tool (`session.presence.who`).
- `agent/<uuid>/now/<sessionId>`, `agent/<uuid>/journal/<YYYY-MM-DD>/<entryId>`,
  `agent/<uuid>/note/<noteId>` — the agent's shared memory, kind `agent_memory`
  (`packages/protocol/src/agentProfiles/agentMemory.ts`). `now` is written only by that thread (its
  title at each turn start, then what the agent says with `ahora_actualizar`); journal entries are
  append-only, one key each (version -1), so threads never collide; notes are Markdown with
  `[[links]]`, edited with CAS by any thread or the app. Every provider prompt that opens a
  conversation turn in an agent thread ends with a short summary of its other threads' `now`
  (`resolveProviderPromptForDispatch`, provider-only text). A command the provider must receive
  verbatim (a Claude slash command, `/compact`, an ACP-native command) and a prompt an earlier
  dispatch already resolved carry no such summary and no replay seed. Tools: `memoria_leer`, `memoria_buscar` (searched in the CLI after
  decrypting), `memoria_anotar`, `ahora_actualizar`, `mis_hilos`. One listing returns at most
  1000 rows, so reads go per kind and the journal per day.
- `task/<uuid>` — a task for the user or one of their agents, kind `agent_task`
  (`packages/protocol/src/tasks/agentTask.ts`): title, description, assignee, status (todo,
  in_progress, blocked, in_review, done), start/due dates, optional machine and folder, source with
  link, the threads that worked it and a comment/status log. Any thread (`tarea_crear`,
  `tarea_actualizar`) or the native app edits it with CAS, re-applying the change on a version
  conflict. A thread joins `threads` only when it works the task (assigned to its agent or to the
  session itself). A session that creates a task for the user or another agent stays in
  `createdBy` and `source.sessionId`, one that updates it in the log, because the native app counts every session in
  `threads` as a task session and leaves it out of the usual list. An agent thread's
  provider prompt ends with its open tasks (its board). Each daemon checks every 5 minutes for the
  user's open tasks due within a day or overdue; it records `notifiedV1` with a versioned write
  before pushing, so only one machine notifies.
  A task may repeat (`recurrence`, `packages/protocol/src/tasks/agentTaskRecurrence.ts`): rules in
  the user's time zone (weekdays + time, every N days from an anchor date, a day of the month), each
  one a server Automation (`/v2/automations`, cron + time zone, assigned to the task's machine, named
  opaquely `task <id> rule <id>`) whose sealed template carries only `agentTaskV1 {taskId, ruleId}`.
  The Automations engine stays the only scheduler. When a run is claimed, the daemon works the
  occurrence with the agent's current profile (identity, account, engine): it continues the task's
  last thread or opens a new one, as the task says. "Every N days" fires daily and is decided against
  its anchor at run time. Occurrences never overlap: while the previous occurrence's thread has a
  live presence record the new firing is recorded as skipped (waiting would hold the run past its
  lease, and the next firing comes anyway). Each occurrence (running, completed at its turn end,
  skipped, failed, interrupted) is kept in the task's history with its thread. A repeating task
  stays open: an agent's `tarea_actualizar` with status done records the result of the occurrence
  its thread is working (and is refused with a clear message when it has none); only the user
  closes or pauses the task, and closing it from the app pauses its Automations so they stop
  firing (the daemon also skips firings on a closed task without recording them).
  A task's assignee is the user, an agent, or an existing session (with or without an agent); a
  session's provider prompt ends with the tasks assigned to it too, and `tarea_actualizar` works the
  same from a session without an agent ("me" is the session). A one-time "Schedule…" start
  (`scheduledStartV1 {at, timezone, automationId}`) is one Automation whose cron names that minute,
  day and month (so within a year) with an `agentTaskV1 {taskId, kind: scheduled_start}` template.
  When it fires the daemon opens the agent's thread, or sends the assigned session the task through
  the canonical send path (resuming it), links the thread, clears the schedule and deletes the
  Automation; a later yearly firing finds no schedule and does nothing.
  Each task keeps its permission mode (`permissionMode`: `read_only`, `default`, `auto`, `yolo`;
  absent means `yolo`, for new tasks and for tasks written before the field). "Start now",
  "Schedule…" and every occurrence use it: a new thread is spawned with it, and a message to an
  existing session carries it as that message's permission intent (`sendSessionMessage`
  `permissionModeOverride`, as `session send --permission-mode`) without changing the session's
  mode. `archivedAt` marks a task the user is not going to do: hidden by default, never deleted,
  off every board, and its repetitions and scheduled start do nothing. Both fields are optional.
  Task writers keep fields they don't know, at every level (passthrough schemas in the CLI; kept
  JSON in the native app), so a newer build's field survives an older writer. CLI builds up to
  0.2.17-native.22 and app builds before 2026-11-07 14:30 strip unknown fields when they rewrite a
  task (they would drop `permissionMode` and `archivedAt`).
- `diag/<uuid>` — a MetricKit report (crash/hang diagnostic or daily metrics) from the native Apple
  app, kind `device_diagnostics` (`packages/protocol/src/diagnostics/deviceDiagnostics.ts`):
  `{v:1, kind, createdAt, device {model, os}, appVersion, build, encoding: 'zlib', payloadBase64}`,
  where the payload is `jsonRepresentation()` compressed with Apple's zlib (raw DEFLATE). Written
  once (version -1); a report whose write would exceed the relay's request body limit (100 MiB
  `bodyLimit`) is saved as `{v:1, kind, tooLarge: true, compressedBytes, rawBytes, build, createdAt}`.
  No client reads it back: `happier diagnostics pull [--out <dir>] [--keep] [--json]` saves each one
  to `<out>/<createdAt>-<kind>-<build>-<uuid>.json` (default `~/.happier/diagnostics`) and deletes the
  key only after its file is written. `diag` is not a change family the relay knows, so a write
  marks the `self` KV family: the native app's next catch-up after a reconnect re-reads its tasks,
  profiles and open memories once; the RN client filters it out by prefix (`todo.`).
- `room/<uuid>`, `roommsg/<uuid>/<seq10>`, `roomseat/<uuid>/<agentId>` — rooms (salas): group chats
  of the user and the agents they invite, kind `agent_room`
  (`packages/protocol/src/rooms/agentRoom.ts`, delivery policy in `agentRoomDelivery.ts`). The room
  holds `{title, kind?, userName?, members [{agentId, name?, emoji?, machineId, directory, wakeByAgents?,
  permissionMode?, dismissedMentionSeq?}], lastSeq, pausedAt?, archivedAt?}`; `kind: 'direct'` marks an
  agent's own chat (id `direct-<agentId>`, written by the Apple app, that agent its only member,
  every user message mentioning it), delivered like any room. In an agent's chat the model pill
  changes only the model and effort of the session of that agent's seat, never the agent or provider:
  the chat sends with `sendRoomMessage`, which never applies an armed agent switch. Each message is its own row
  `{seq, at, author (user | agent with name/emoji/sessionId), text, mentions [agentId], mentionsUser?,
  replyTo? {seq}, sendNow?}`
  created with version -1 in the same atomic write that moves the room's `lastSeq` to its seq, so
  concurrent writers (the app, every member's thread) get gap-free ordered seqs and re-run on a
  conflict. Messages are read by exact key through `POST /v1/kv/bulk` (≤100 keys per call), never
  listed, so a long room never crowds a listing. A member's seat holds its thread (`sessionId`), its
  read marker (`readThroughSeq`) and the delivery in flight (`inFlight {localId, throughSeq, at,
  sent?, steers? {localId, throughSeq, ended?}, sendNowSupported?}`). Writers: the app writes the room and the user's messages (mentions resolved by its
  picker; "Que conteste" is the user's own message mentioning that member); the daemon of each
  member's machine writes that member's seat; the member's thread posts its replies. The app may
  also withdraw, edit or flag `sendNow` (Steer Now) a user message its member hasn't got (seq above
  both `readThroughSeq` and `inFlight.throughSeq`): one atomic `kvMutate` that deletes (null value)
  or rewrites the message at its version and writes that member's seat back byte for byte at the
  version it read. That seat
  write is only a version guard; seat content stays daemon-owned. The daemon reads seats before
  messages and claims a delivery with a CAS on the seat version it read, so either the app's write
  lands first and the claim fails (the next run reads the room as it is then), or the app's write
  conflicts and the returned seat shows the member already has it. Daemons skip missing
  messages (pinned by `reconcileRoomDeliveries.test.ts`). A withdrawn message's seq stays a gap for
  good: the relay keeps the deleted key as a tombstone (null value, higher version), appends only
  take the seq after `lastSeq` (which the withdrawal leaves as it was), and an edit that finds the
  message gone fails instead of writing it again, so nothing re-creates it. The app revises only in
  an agent's own chat, and there `sala_leer` gives the member the user's messages only through what
  its seat has (`readThroughSeq` or `inFlight.throughSeq`), its own replies all, reading the seat
  before the messages as the daemon does, so the agent never reads a message that may still change
  (pinned by `runAgentRoomTool.test.ts`). A user's
  message with `replyTo` answers that message: Reply (quoting any message) mentions its author when
  that is a member, plus whoever the user names, never the quoted message's own mentions; picking an
  agent's `<options>` option mentions only its author. A member's `dismissedMentionSeq` is app-only
  state: the user dismissed its "Let It Answer" notice for the agent mention at that seq, so no device
  shows it until a later agent mention; daemons don't read it and keep it when they rewrite the room
  (passthrough), and it changes no delivery.
  Delivery runs in the daemon of the member's machine (`apps/cli/src/daemon/agentRooms/`), so a room
  may span machines without a coordinator and works with the app closed. The machine socket does
  not carry KV writes, so the daemon keeps a lean user-scoped socket (`updates-lean-v1`) and
  reconciles a room on each of its `kv-batch-update`s and every room it has a member in on each
  (re)connect. A member mentioned with `@` by a message it may answer gets everything it hadn't read,
  from others, in order with who said what, as one message to its thread in the room (opened the
  first time in its folder as its agent, YOLO unless `permissionMode` says otherwise), sent with the
  localId `room.<roomId>.<agentId>.<nonce8>` (URL-safe and under the relay's 100-character route
  parameter, since readers look messages up by localId) through the canonical send path; a send
  that failed is retried with the same localId, so it lands once. Over 15 unread messages, the newest
  15 go in full, the 50 before as one line each (≤160 characters) and the rest only counted, with a
  pointer to `sala_leer` (`room.read`, a member reads its room by seq range). A message shown in full
  that answers another says which, quoting it in one line (≤160 characters; "your #N" when it is the
  member's own); the daemon reads quoted messages outside the unread range for that. A send that
  finds the thread archived or gone (`session_archived`, `session_not_found`) opens a new thread. A
  thread archived or deleted while its turn runs (the transcript reader returns `thread_gone`: the
  session is not found, or it is archived and the turn hadn't finished; a turn that finished before
  the archive still posts its reply) is cleared from the seat without moving the marker, and the
  same run delivers again to a new thread with a new localId, so a late reply of the old thread
  can't finish it. A new thread for a member that had read the room (`readThroughSeq > 0`) gets a
  continuation delivery: the room through `throughSeq`, its own replies included, cut the same way
  (the daemon reads only the newest 65 seqs; earlier ones are counted with the `sala_leer`
  pointer), what the thread before had answered (through the marker, and its own replies) apart
  from what is new, and that thread's session id for `mis_hilos`. A member's first thread ever gets
  only the unread backlog. Every agent reply's `author.sessionId` names the seat thread that wrote
  it, whether its runner or the daemon's reconcile posted it, so clients can tell a reply from a new
  thread (the Apple app captions it "New thread", `AgentRoom.newThreadSeqs`). The delivery prompt
  also teaches the member to put one of its sessions' id alone on a line as `<session>ID</session>`
  (the ids are in its other-threads list and `mis_hilos`). The Apple app (`MarkdownSegments`)
  takes a line that is only `<session>ID</session>`, spaces or tabs around it allowed, with ID
  matching `[A-Za-z0-9_-]{1,128}` (it goes into the session's URL path); consecutive such lines,
  blank lines between them allowed, form one stack of cards, and any other `<session>` line stays
  text. Each card shows the session's title, what its thread says it is doing (its `now`) or else its
  folder, and its live state, and a tap opens it with `openRelatedSession` (fetched when the device
  doesn't list it). `apps/ui` doesn't parse them: a thread's transcript there shows the raw lines.
  Push previews leave them out (`buildAssistantMessagePreview`). The other
  members are not woken by a reply that doesn't mention them; it stays in the room's history, so
  their next delivery (or `sala_leer`) includes it. A member mid-turn gets
  nothing new: what arrives meanwhile is delivered together once that turn ends, except what the
  user sends now. Steer Now (the Apple app, in an agent's own chat) flags a waiting message
  `sendNow`; once the delivery in flight was sent, is in its thread's transcript and its turn still
  runs, the member's daemon claims a new delivery (`decideRoomDelivery` returns `steer`) through the
  newest flagged user message that mentions the member, earlier unflagged ones riding along and
  later ones staying queued, with `steers` naming the delivery it was sent past. It carries only the
  messages after that one's `throughSeq` and goes through the ordinary send path (no requested
  action, so the relay's pending queue steers it into the turn while the turn can take it and
  otherwise runs it right after). A flag at or below `inFlight.throughSeq` does nothing. A retried
  send of it carries the same messages; its thread gone, it is dropped together with the delivery
  it was sent past, the marker unmoved, and the next run gives a new thread everything since the
  marker. Every delivery a daemon starts carries `sendNowSupported: true`: the app offers Steer Now
  only on a seat that has it, while the thread's session is working and can steer. The user's
  messages without `@` go to no one. When a room turn is ready (`sendReadyWithPushNotification`, after the
  transcript is flushed) the thread posts the turn's final assistant text as its reply (mentions
  resolved by name, `@<userName>` sets `mentionsUser`), moves its marker to what the delivery read
  through (messages that came during the turn stay unread) and clears the delivery, all in one
  atomic write; the daemon finishes a turn from the thread's transcript when its runner ended
  without doing so. Both apply one rule (`settleRoomTurn`): the delivery a Steer Now was sent past
  posts its own reply when its turn ended first (the marker moves to its `throughSeq` and the Steer
  Now stays in flight), and the delivery in flight posts the text after its own user row when its
  turn ends, which also ends the one sent past when the steer joined that turn (it gets no reply of
  its own). The runner drops `steers` at the ready of the turn it names; when the daemon posted that
  reply first, from the transcript, `steers` stays as `ended` until that ready, which then posts
  nothing again and takes over its notice, and no new Steer Now is claimed meanwhile. At a ready a
  turn that ended without a completion marker is ended too, but only the one that ready ended:
  never the Steer Now while the turn it was sent past is the one that finished. The runner keeps
  tracking its room delivery until the seat's delivery in flight is finished, so a Steer Now that
  reaches the transcript later is posted at its own ready. An agent's mention wakes a member only when that member's `wakeByAgents` is true
  (the app sets it, after the Consumer Terms 3.7 warning for Claude members; the CLI never decides
  by provider) and fewer than 6 agent messages came in a row since the user's last one (the brake);
  otherwise it waits for the user. `pausedAt` stops deliveries (running turns finish). The user gets
  one push for every agent reply (`roomReplyNotices` decides; `completeRoomTurn` sends it on the
  account's `expo_push` channel, from the runner or the daemon): titled with the agent's name and
  emoji, its body the reply's plain preview without `<session>` lines or `<options>`, as a messaging
  app does; in a group room the body starts with the room's title, and a reply that mentions the
  user is titled "<agent> mentioned you" instead (one push either way). A hand-off that hits the
  brake adds a "Room on hold" push. Room pushes carry `{type: 'room_mention' | 'room_brake', roomId,
  seq}` and no `sessionId`. A reply's push stands for its thread's turn-finished (`ready`) push,
  which the phone doesn't get for the turn that answered a room delivery, even with the account's
  ready push on (`notifyRoomTurnReady` tells `sendReadyWithPushNotification`, from the delivery its
  runner saw reach the provider last), so it follows that push's settings: no
  room push without an enabled `expo_push` channel; the reply text becomes "New message" when that
  channel's `readyIncludeMessageText` is off; every room push asks `suppressIfComputerFocused` when
  `mutePhoneWhenComputerFocused` is on; a plain reply needs the channel's `ready` topic; and a thread
  whose bell is off (`notificationsMutedV1`) gets no reply or mention push (the brake, the room's,
  still goes). Only the runner sees its thread's bell: a turn the daemon finishes is pushed even
  when muted. Webhook channels get no room push, so they still get the thread's `ready` event for
  a room turn. The thread's ready push still goes to the phone for a turn the user starts in the
  thread itself, and for a room turn whose runner posted no reply (not in the transcript yet, the
  turn wrote no final text, or the post failed), even if the daemon later finishes that turn and
  pushes its reply too. `room*` are not change families the relay knows, so writes mark
  the `self` KV family (the native app's catch-up re-reads what it shows).

`GET /v1/kv` has no cursor: a listing returns at most 1000 rows. Records are split so each listing
stays small (profiles, tasks and presence on their own prefixes; memory per kind and the journal per
day), and every client still reports a full listing as possibly incomplete instead of cutting it
silently. A cursor on the route is a possible future improvement.

### Account and usage
- `GET /v1/account/profile`
- `GET /v1/account/settings`
- `POST /v1/account/settings`
- `POST /v1/usage/query`

Provider Account Usage in development also uses
`/v3/connect/provider-account-usage/:recordId`. Plain writes keep the strict
base snapshot in `content.v` and optional supplemental facts in `metadata`.
`metadata.recoveryCreditDetails` is admitted only with the canonical
`connectedServices.quotaRecoveryCreditDetails` feature enabled. Clients require
an explicit server-enabled bit before sending it; older servers still receive
the supported base usage and recovery-credit shape. Encrypted records carry
account-sealed details beside the base ciphertext instead of readable metadata.
See [quota recovery compatibility](compatibility.md#quota-recovery-details-02-development)
and [encryption](encryption.md) for the owning wire and privacy boundaries.

### Push tokens
- `POST /v1/push-tokens`
- `DELETE /v1/push-tokens/:token`
- `GET /v1/push-tokens`

### Connect (OAuth providers + vendor tokens)
- `GET /v1/auth/external/:provider/params`
- `POST /v1/auth/external/:provider/finalize`
- `POST /v1/auth/external/:provider/token-exchange`
- `DELETE /v1/auth/external/:provider/pending/:pending`
- `GET /v1/connect/external/:provider/params`
- `POST /v1/connect/external/:provider/finalize`
- `DELETE /v1/connect/external/:provider/pending/:pending`
- `DELETE /v1/connect/external/:provider`
- `GET /v1/oauth/:provider/callback`
- `POST /v1/connect/:vendor/register` (`vendor` in `openai | anthropic | gemini`)
- `GET /v1/connect/:vendor/token`
- `DELETE /v1/connect/:vendor`
- `GET /v1/connect/tokens`

### Users, friends, feed
- `GET /v1/user/:id`
- `GET /v1/user/search?query=...`
- `POST /v1/friends/add`
- `POST /v1/friends/remove`
- `GET /v1/friends`
- `GET /v1/feed`

### Version and voice
- `POST /v1/version`
- `POST /v1/voice/token`

### Dev-only
- `POST /logs-combined-from-cli-and-mobile-for-simple-ai-debugging` (only if enabled)

## Implementation references
- API routes: `apps/server/sources/app/api/routes`
- Auth module: `apps/server/sources/app/auth/auth.ts`
