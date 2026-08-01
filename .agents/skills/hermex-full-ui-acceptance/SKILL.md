---
name: hermex-full-ui-acceptance
description: Run release-grade Hermex UI acceptance on a real iOS Simulator and the configured live server, covering every reachable enabled control, PR-affected flows, build and XCTest, persistence, server health, and crash logs. Use when asked for exhaustive end-to-end testing, to click every button, to approve a release, or to ensure the app has no problems.
---

# Hermex Full UI Acceptance

Run a **flight check** against the exact commit under review. A flight check requires separate build, XCTest, Simulator UI, live-server, persistence, and log evidence.

## 1. Fix the target and safety boundary

1. Read the repository `AGENTS.md`, `CURRENT.md` when present, relevant `PROJECT_SPEC.md` sections, and `DEVELOPMENT.md` validation commands.
2. Record the repository, exact commit SHA, diff/base, scheme, Simulator device and OS, server identity, and whether the server is a disposable test environment.
3. Inspect staged, unstaged, and untracked files. Preserve user-owned work; use an isolated worktree when the current tree is dirty or points at another commit.
4. Classify each mutation:
   - Use disposable sessions, cards, goals, and no-op cron jobs for reversible checks.
   - Open destructive actions through their confirmation UI, then cancel, unless the user explicitly authorizes execution against the named target.
   - Treat production jobs, external integrations, account deletion, logout, and irreversible settings as unavailable unless a safe fixture exists.
5. Start a run ledger with columns: `surface`, `control or flow`, `precondition`, `action`, `expected`, `actual`, `evidence`, `status`.

Complete this step only when the exact target and every mutation boundary are recorded.

## 2. Build an exhaustive UI inventory

1. Derive affected screens and states from the diff and call paths.
2. Add every top-level destination and every visible, enabled app control reachable from them.
3. Recursively inspect controls exposed by menus, sheets, popovers, detail screens, empty states, loading states, error states, and post-action states.
4. Record disabled controls with the precondition needed to enable them. Satisfy that precondition with disposable data when safe.
5. Exclude Simulator chrome and test-tool controls from the app inventory.

Complete this step only when every reachable in-scope screen has no unaccounted enabled app control.

## 3. Establish automated evidence

1. Run focused tests for the changed behavior while investigating failures.
2. Run the full XCTest suite against the exact target commit.
3. Build a normally signed Debug app, install it on the selected Simulator, and launch it normally.
4. Record commands, exit codes, test counts, warnings, and the installed app path. Inspect output rather than relying on exit code alone.

Complete this step only when the build and full suite pass, or report `NO-GO` with the exact failure.

## 4. Perform the UI flight check

Interact through the visible UI and accessibility tree. Use coordinates only when accessibility cannot reach a visible control. Treat direct API calls as server verification or cleanup evidence, never as proof that a UI action worked.

For every inventory row:

1. Put the app into the required state.
2. Tap the control.
3. Verify the visible result and relevant accessibility state.
4. Return without leaving unintended mutations.
5. Capture a screenshot or tree excerpt for PR-affected and failed paths.

Always exercise these Hermex flows:

### Sessions and chat

- Open search, filters, profile and project controls, project action menus, and every top-level destination; cancel destructive actions.
- Open an existing chat and exercise attachment, model, reasoning, workspace, profile, context-usage, voice, and composer controls.
- From an existing chat, create New Chat and verify the empty state.
- Enter a unique canary message through normal input or clipboard paste, send it, observe streaming completion, and verify the expected response.
- Verify the new title/session in the list, terminate and relaunch the app, reopen it, and verify the persisted transcript has exactly the expected messages.
- When the change concerns session chaining, verify `prev_session_id` from live request/server evidence; UI success alone is insufficient.

### Goal continuation

- Use a disposable two-turn goal whose second turn is safe and deterministic.
- Verify kickoff, the automatic `goal_continue` turn without a manual prompt, turn-count progression, completion state, and Clear cleanup.
- A missing automatic turn is a live integration failure even when unit tests pass.

### Cron

- Use a disposable no-op cron job.
- Exercise detail, run, overlapping-run rejection (`already_running`), pause, resume, edit, and delete/cleanup through UI.
- If no safe disposable job or server is available, mark this required flow `BLOCKED`; inspecting menus alone does not complete it.

### Kanban

- Exercise every status tab, board picker, search, filters, assignee grouping, card actions, add-card form, and card detail sections.
- Verify both supported statistics payload shapes through live servers or deterministic debug fixtures.
- Verify event history, run status/result, start and end timestamps, worker ID, run ID, and operational metadata.
- Perform mutations only on a disposable board/card and clean them up.

### Remaining destinations

- Open Tasks, Skills, Memory, Analytics, Settings, and any newly added top-level route.
- Exercise every enabled non-destructive control and every safe confirmation/cancel path found by the inventory.

Complete this step only when every ledger row is `PASS`. Tool failures, missing fixtures, and unsafe required mutations remain `BLOCKED`; they are not app passes.

## 5. Verify recovery and cleanup

1. Cold-launch the app once more and recheck the persisted canary session and navigation.
2. Query server health and require zero unintended active streams and runs.
3. Inspect Simulator logs for crashes, fatal errors, uncaught exceptions, and new repeated errors during the run.
4. Clear the test goal and remove disposable data when removal is safe and authorized. Report any retained test artifact by exact name/ID.
5. Recheck Git status and confirm the flight check did not alter user-owned source files.

Complete this step only when runtime state and workspace state are accounted for.

## 6. Issue the verdict

Use `Full UI acceptance: PASS` only when:

- the exact commit builds and the full XCTest suite passes;
- every inventory row and every mandatory flow passes through UI;
- every PR-affected client/server branch has live or deterministic fixture evidence;
- cold-relaunch persistence, health, logs, and cleanup pass; and
- no required row is blocked or inferred from a different evidence layer.

Otherwise issue `Full UI acceptance: INCOMPLETE/NO-GO`. Separate confirmed product failures from automation/environment blockers, but treat both as preventing the claim that the app is completely verified.

Report the verdict first, followed by a compact evidence matrix for `Build`, `XCTest`, `Simulator UI`, `Live server`, `Persistence`, `Logs`, and `Cleanup`. Include exact untested controls and the smallest next action needed to close each gap. Simulator evidence never implies physical-device proof.
