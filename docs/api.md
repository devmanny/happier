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
  `[[links]]`, edited with CAS by any thread or the app. Every provider prompt of an agent thread
  ends with a short summary of its other threads' `now` (`resolveProviderPromptForDispatch`,
  provider-only text). Tools: `memoria_leer`, `memoria_buscar` (searched in the CLI after
  decrypting), `memoria_anotar`, `ahora_actualizar`, `mis_hilos`. One listing returns at most
  1000 rows, so reads go per kind and the journal per day.
- `task/<uuid>` — a task for the user or one of their agents, kind `agent_task`
  (`packages/protocol/src/tasks/agentTask.ts`): title, description, assignee, status (todo,
  in_progress, blocked, in_review, done), start/due dates, optional machine and folder, source with
  link, linked threads and a comment/status log. Any thread (`tarea_crear`, `tarea_actualizar`) or
  the native app edits it with CAS, re-applying the change on a version conflict. An agent thread's
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
  off every board, and its repetitions and scheduled start do nothing. Both fields are optional;
  builds before 2026-11-07 parse such tasks but drop the two fields if they rewrite one.

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
