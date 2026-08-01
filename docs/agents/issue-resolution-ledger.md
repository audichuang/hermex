# Issue resolution ledger

Snapshot: 2026-08-01  
Upstream baseline: `origin/master` at `7d38a3b`  
Contributor integration branch: `develop` at `6d39059`  
Current audit branch: `codex/issue-audit-fixes`

This is a current-state ledger, not a replacement for GitHub issues or Git history.
Update existing rows instead of appending a chronological log.

## Status meanings

- **Upstream resolved**: merged into `uzairansaruzi/hermex` and the GitHub issue is closed.
- **Locally resolved**: implementation and required local acceptance are complete, but the change is not upstream.
- **Implemented, acceptance incomplete**: code exists, but a required live, visual, device, or product-decision gate remains.
- **Unresolved**: no implementation addresses the issue's root cause.
- **Upstream/server issue**: the reported failure is outside the Hermex iOS client unless the product scope changes.

## Open issues with local work

| Issue | For / user scenario | Local commits | Branch / publication | Current verdict | Remaining proof or decision |
|---|---|---|---|---|---|
| [#174](https://github.com/uzairansaruzi/hermex/issues/174) | Users who want opt-in live and persisted tokens-per-second metrics | `a65a999 feat: show opt-in response speed metrics (#174)` | `develop`, pushed to `fork/develop` | Implemented, acceptance incomplete | Validate live metering, final replacement, reopen persistence, Dynamic Type, and VoiceOver against a compatible server. |
| [#178](https://github.com/uzairansaruzi/hermex/issues/178) | New self-hosters who rely on the generated Tailscale setup prompt | `cb66440 fix: make setup prompt use safe Tailscale Serve defaults (#178)`; `1222c96 test: cover Tailscale Funnel guard (#178)` | `develop`, pushed to `fork/develop` | Locally resolved | No remaining code gate; GitHub stays open because no upstream PR was submitted. |
| [#179](https://github.com/uzairansaruzi/hermex/issues/179) | Users who need provider models outside the curated catalog | `93f9a6a fix(models): expose overflow catalogs in pickers (#179)` | `issue/179-model-picker-overflow`, local only | Implemented, acceptance incomplete | Rebase onto current `origin/master`; validate a live Nous overflow selection through chat and Settings. |
| [#180](https://github.com/uzairansaruzi/hermex/issues/180) | Users changing reasoning effort from the composer picker or `/reasoning <level>` | `05dd228 fix(reasoning): scope effort writes to active session (#180)`; `9148913 fix: re-key the #180/#211 fixes on verified upstream behaviour (#180, #211)` | `codex/issue-audit-fixes`, pushed to fork | Implemented, reported root cause unconfirmed | The issue's stated server behaviour does not exist upstream (see "Upstream source verification"). The follow-up keeps `session_id` optional, adds the missing `model`/`provider` pair, and removes the fail-closed gate. Ask the reporter for the raw 400 response body and server version. |
| [#183](https://github.com/uzairansaruzi/hermex/issues/183) | Users sending repeated steering hints during an active response | `1fc606f fix(chat): auto-dismiss steering confirmation (#183)` | `issue/183-auto-dismiss-steering-notice`, pushed to fork | Implemented, product decision incomplete | The commit changes `PROJECT_SPEC.md` from “persist as transcript notice” to “dismiss and never persist.” The owner must explicitly approve that spec change. |
| [#186](https://github.com/uzairansaruzi/hermex/issues/186) | Users whose model reasoning or tool execution is semantically quiet while SSE heartbeats remain healthy | `892324d fix(chat): respect SSE heartbeat activity (#186)`; `9177ed3 fix(chat): recover silent initial streams`; `09a70dd fix(chat): defer silent recovery until timeout` | `develop`, pushed to `fork/develop` | Implemented, acceptance incomplete | Validate a real 60-second heartbeat-only stream and a real transport-stale reconnect/replay. The last two commit messages should identify `#186`. |
| [#201](https://github.com/uzairansaruzi/hermex/issues/201) | Users seeing inconsistent spacing between thinking and tool activity cards | `aae2a37 fix(chat): align activity card spacing (#201)` | `develop`, pushed to `fork/develop` | Implemented, acceptance incomplete | Capture signed-Simulator evidence with adjacent thinking/tool cards; the one-line spacing change has no focused visual proof. |
| [#207](https://github.com/uzairansaruzi/hermex/issues/207) | Users whose stream recovers but leaves a stale timeout warning visible | `e738a8c fix(chat): clear recovered stream warnings (#207)` | `issue/207-clear-recovered-warnings`, pushed to fork | Implemented, acceptance incomplete | Inject a temporary timeout through the real UI, observe resumed streaming, and verify only the recovery-owned warning clears. |
| [#209](https://github.com/uzairansaruzi/hermex/issues/209) | Chinese users composing text with a Pinyin keyboard | `07db061 fix(chat): disable composer auto-capitalization (#209)` | `issue/209-disable-composer-auto-capitalization`, pushed to fork | Locally resolved | Focused/full XCTest and signed-Simulator `nihao` -> `你好` input passed. It is not integrated into `develop`. |
| [#211](https://github.com/uzairansaruzi/hermex/issues/211) | Users opening Telegram, gateway-origin, cron, or delegated sessions that are history-only in Hermes WebUI | `a7d9c2e fix(chat): make CLI sessions visibly read-only (#211)`; `9148913 fix: re-key the #180/#211 fixes on verified upstream behaviour (#180, #211)` | `codex/issue-audit-fixes`, pushed to fork | Implemented, acceptance incomplete | `a7d9c2e` keyed on `is_cli_session`, which upstream reports as `false` for messaging rows and `true` for writable CLI/TUI rows — wrong in both directions. The follow-up keys on `read_only` plus upstream's non-claimable source families and re-latches from the session detail. Repeat with an actual Telegram/gateway session before upstream handoff. |

## Open issues without a completed local fix

| Issue | For / user scenario | Current code evidence | Verdict | Smallest next slice |
|---|---|---|---|---|
| [#145](https://github.com/uzairansaruzi/hermex/issues/145) | Users receiving inline `MEDIA:` PDF, image, or audio references | No matching local commit | Unresolved enhancement | Define supported media types and reuse existing transcript media loaders. |
| [#162](https://github.com/uzairansaruzi/hermex/issues/162) | Users whose server raises `_chat_messages_to_responses_input(... is_github_responses)` | The error originates in server-side request processing | Upstream/server issue | Reproduce and fix in the affected hermes-webui/hermes-agent version; keep the app error visible. |
| [#170](https://github.com/uzairansaruzi/hermex/issues/170) | NetBird users who need provider-specific onboarding | No matching local commit | Unresolved enhancement | Resolve onboarding scope, then add a provider selector without changing the API contract. |
| [#172](https://github.com/uzairansaruzi/hermex/issues/172) | Users connecting to the bundled Hermes Agent dashboard with basic auth | Hermex supports hermes-webui, not the dashboard's provider-auth contract | Unresolved scope/architecture | Decide whether the dashboard becomes supported or redirect the issue to direct Gateway work. |
| [#176](https://github.com/uzairansaruzi/hermex/issues/176) | Users connecting to the bundled dashboard's HTML health/session-token flow | No supported client contract for the embedded dashboard token | Unresolved scope/architecture | Decide supported backend scope before changing health or auth tolerance. |
| [#177](https://github.com/uzairansaruzi/hermex/issues/177) | Users who want direct Hermes Agent Gateway connections | No Gateway backend implementation | Unresolved architecture | Start with capability discovery and a bounded chat/run slice after a backend-boundary design. |
| [#189](https://github.com/uzairansaruzi/hermex/issues/189) | Users who want to hide unused top-level surfaces | No matching local commit | Unresolved enhancement | Triage the exact surfaces and persistence scope before adding settings. |
| [#200](https://github.com/uzairansaruzi/hermex/issues/200) | Users installing the iPad app on Apple silicon Mac or Vision Pro | No matching local commit; part of the outcome may live in App Store Connect | Unresolved release/configuration work | Audit platform availability, capabilities, and a stable visionOS device before code changes. |
| [#204](https://github.com/uzairansaruzi/hermex/issues/204) | Users whose server is configured for Kokoro/OpenAI-compatible TTS | The server defaults an omitted engine to Edge TTS | Upstream/server issue | Fix server fallback to its configured engine; do not make the iOS client duplicate server policy without a contract change. |
| [#208](https://github.com/uzairansaruzi/hermex/issues/208) | Users long-pressing a link inside a chat message | `issue/208-link-long-press` points at `9bc7ab0`, the merged #163/PR #164 cache fix; the bubble still owns an unconditional context menu | Unresolved bug | Make link interaction win without removing non-link message actions; add gesture and signed-Simulator regressions. |
| [#210](https://github.com/uzairansaruzi/hermex/issues/210) | Codex users who want account quota in Hermex | No matching local commit or accepted API contract | Unresolved enhancement | Verify the upstream quota payload and product placement before implementation. |

## Acceptance evidence for this audit branch

- Exact product commit: `9148913`; the validation follow-up adds only one 403 regression test and this ledger update.
- Full XCTest: 1,553 passed, 0 failed, 0 skipped on iPhone 17 / iOS 26.5 Simulator.
- Result bundle: `/tmp/hermex-9148913-final-derived/Logs/Test/Test-HermesMobile-2026.08.01_21-12-48-+0800.xcresult`.
- Signed Debug app: `/tmp/hermex-9148913-derived/Build/Products/Debug-iphonesimulator/HermesMobile.app`; `codesign --verify --deep --strict` passed before install.
- #180 existing-session picker request: `{"model":"gpt-5.4","session_id":"normal-session","effort":"high","provider":"openai"}`.
- #180 New Chat picker request: `{"effort":"xhigh","session_id":"new-session","model":"gpt-5.4","provider":"openai"}`; the option remained selected after background/foreground. Unit coverage also proves the request still sends when `session_id` is absent.
- #211 claimable CLI: composer controls remained enabled and the UI sent `POST /api/chat/start` for `cli-session`.
- #211 Telegram: the row and Traditional Chinese banner showed read-only; every composer control was disabled; activating text/voice controls produced no POST.
- 403 refusal: focused regression coverage verifies the server's JSON error is surfaced instead of the password hint.
- This is contract-mock acceptance, not the required live-server gate. Release-grade verdict remains **INCOMPLETE / NO-GO** until the two issue-specific live scenarios pass.

## Upstream source verification (2026-08-01)

Checked against `nesquena/hermes-webui` at `320789ae` (2026-07-31), the reporter's
`c275db09` (v0.51.365), and `NousResearch/hermes-agent`.

**#180 — the reported server contract does not exist.**

- `POST /api/reasoning` reads only `effort` / `display` / `model` / `provider` / `base_url`
  (`api/routes.py: handle_post`), and writes the profile-wide `agent.reasoning_effort`
  (`api/config.py: set_reasoning_effort`). There is no session scope.
- `git log --all -S "session_id is required for reasoning"` over the full upstream history
  returns nothing. hermes-agent exposes no `/api/reasoning` route at all.
- Real defect found instead: `get_reasoning_status` echoes the effort **coerced for the
  resolved model**. Omitting `model`/`provider` from the POST makes the server coerce
  against the config default model, so the composer chip can snap to a value the user did
  not pick. The WebUI composer always sends the pair (`static/ui.js`).
- Gating the request on a session id is a regression in both directions: it kills the
  picker in a new chat, and a body-level `session_id` activates
  `_guard_request_session_visibility`, which 404s a cross-profile session.
  (Hermex switches the server profile on chat open, so that path is normally unreachable.)

**#211 — real bug, wrong signal.**

- `is_cli_session_row` (`api/agent_sessions.py`) excludes `MESSAGING_SOURCES`, so a
  Telegram row reports `is_cli_session=false` in the sidebar projection — and
  `_merge_cli_sidebar_metadata` re-stamps the same computed value onto the detail payload.
- `read_only` is absent from the sidebar projection entirely, and on v0.51.365 the detail
  stub set it from `cli_meta`, which upstream never populates for messaging rows. On the
  reporter's server both flags are therefore false.
- Conversely, `is_cli_session=true, read_only=false` is upstream's *claimable* state:
  `_claim_or_synthesize_cli_session` materialises a writable sidecar for CLI/TUI/Desktop
  rows on the first `POST /api/chat/start` (added in `31a01e8a`, 2026-06-28).
- The durable signal is the source family in `_is_claimable_cli_source`: messaging
  platforms, `external_agent`, `claude_code`, `cron`, `gateway`, `subagent`. Sidebar rows
  always carry it via `normalize_agent_session_source`.
- Current upstream answers a refused continue with **403** and a specific message, not 404
  (`api/routes.py: _handle_chat_start`). Hermex mapped every 403 to "check the server
  password"; it now surfaces the server's reason.

## Upstream-resolved issues from this work

| Issue | For / user scenario | Upstream commit / PR | Root fix |
|---|---|---|---|
| [#163](https://github.com/uzairansaruzi/hermex/issues/163) | Users reopening a long cached transcript | `9bc7ab0`, [PR #164](https://github.com/uzairansaruzi/hermex/pull/164) | Bound cache-first reads to the newest mobile page. `(#164)` in the commit subject is the PR number; the issue is #163. |
| [#187](https://github.com/uzairansaruzi/hermex/issues/187) | Users navigating the file browser over slow networks | `7d38a3b`, [PR #188](https://github.com/uzairansaruzi/hermex/pull/188) | Shared revision guard makes newest navigation win and suppresses cancellation noise. |

## Commits that need issue traceability

| Commits | Actual purpose | Issue mapping / action |
|---|---|---|
| `9177ed3`, `09a70dd` | Complete the no-initial-byte sibling path of stale-stream recovery without showing premature recovery UI | Rewrite locally as `fix(chat): recover silent initial streams (#186)` and `fix(chat): defer silent recovery until timeout (#186)` only if the owner authorizes rewriting pushed `fork/develop` history and the required force-push destination. |
| `97b6180`, `f479106`, `8a13e07`, `cd738cb` | Long-transcript page-size/render/scroll performance follow-ups | Do not retroactively claim #163. Create one bounded performance issue before upstream publication, then rewrite the app commit subjects to reference it. |
| `c628df9`, `5cf00e6`, `1e93dd7` on `fork/master` | Goal continuation, New Chat memory handoff, Kanban/Cron decoding, SSE close handling, and upstream-watch fixes | No upstream issue. Split into capability-specific retrospective issues and revalidate against current `origin/master`; the exact final head lacks recorded full-suite and live-contract closure. |
| `348e687`, `5fe972f`, `a0b8f49`, `543df7d`, `6d39059` | Repository-agent, PR-readiness, UI-acceptance, and device-delivery documentation | Operational documentation; reference the resulting app issue/PR when published, but do not invent a product bug. |

## Commit-message rule for new fixes

Every new app commit must state the issue and the affected user scenario in its body:

```text
fix(area): concise root-cause fix (#123)

For #123: users who <affected scenario>.
<Why the shared/root layer was wrong and what invariant now holds.>
```

Changing a commit message that is already on a fork branch rewrites history. Do not
force-push it without separate approval for the exact owner/repository and branch.
