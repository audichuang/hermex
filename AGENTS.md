# AGENTS.md — working agreement for Hermex

Hermex is a native SwiftUI iPhone app (Xcode target/scheme `HermesMobile`, App Store
name `Hermex`) for a self-hosted `hermes-webui` server. `PROJECT_SPEC.md` is the
product/API source of truth. If a request conflicts with it, stop and ask.

## Session start and wrap-up

- If `CURRENT.md` exists, read it first and follow its listed spec sections. Otherwise,
  read only the `PROJECT_SPEC.md` headings relevant to the selected issue.
- Implement only the issue selected by the human, labeled `ready-for-agent`, or named
  in `CURRENT.md`; do not treat every open issue as active work.
- On "wrap up", verify the repo/build/test state, overwrite gitignored `CURRENT.md`,
  then commit only when the human requested a commit. History belongs in Git, not an
  append-only context log.

## Workflow and authorization

- Follow `docs/agents/issue-tracker.md` for issue, branch, PR, and triage conventions.
  Keep protected `master` buildable; it is the internal TestFlight candidate branch.
- Before preparing, reviewing, updating, or handing off a PR, read and apply
  `docs/agents/pr-readiness.md`.
- Git/GitHub approval is operation- and destination-specific: pushing, opening,
  updating/commenting on a PR, and merging are separate approvals.
- Before any push, verify and report the destination owner/repository and branch.
  Never infer from a remote name such as `origin` that it is the contributor's fork.

## Hard rules

1. **Never invent API endpoints or payloads.** Follow `PROJECT_SPEC.md` section 4 and
   `CONTRACT_TESTS.md`: live wire data is authoritative for the tested deployment;
   upstream source at a recorded SHA defines the intended shape; docs are supplementary
   intent and never override wire/source. `.codex-tmp/hermes-webui` is a read-only local
   upstream checkout, not the validated pin. Record its status and HEAD before relying
   on it; `UPSTREAM_TESTED_SHA` is the compatibility pin.
2. **No new third-party dependencies** beyond the locked list in `PROJECT_SPEC.md`
   without approval.
3. **Tolerant upstream decoding:** response/wire models must tolerate missing, renamed,
   unknown, and observed type-drifted fields. Decode optional/raw values first, then
   semantically validate fields required by the capability. Request and local persisted
   models may keep required invariants.
4. **No destructive commands** (`rm -rf`, `git push --force`, anything touching
   `~/Library/LaunchAgents/`, or restarting Mac services). Suggest them; let the human run them.
5. Do not commit while relevant builds/tests introduced by the change fail. Record
   pre-existing failures separately.

## Validation

- Prefer terminal validation. Use XcodeBuildMCP when available; otherwise use the raw
  `xcodebuild`/`xcrun simctl` commands in `DEVELOPMENT.md`. Shared defaults live in
  `.xcodebuildmcp/config.yaml`.
- Manual Simulator installs must use a normally signed Debug build. Do not install a
  `CODE_SIGNING_ALLOWED=NO` build; it lacks the entitlements needed by login/Keychain.
- Physical-device artifacts must come from the exact commit under review. If the main
  worktree is dirty, build from an isolated worktree; copy the gitignored
  `Config/Local.xcconfig` into that worktree, verify it remains ignored, and never
  commit it. Hooks may sync the file, but are not versioned.
- Before terminal `devicectl` install/launch, stop any Xcode Run session using that device;
  concurrent GUI and CLI CoreDevice sessions can stall. Follow `DEVELOPMENT.md`.
- Run focused tests while iterating. Rerun the full XCTest suite after rebasing app code
  and before review/PR handoff. For UI/runtime changes, also build and launch the app
  and give the human a short manual test plan.

## Special command meaning

- "push to branch testflight" means the maintainer-only side-by-side **Hermex Branch**
  TestFlight upload—not a Git push, merge, or production-app upload. Follow
  `DEVELOPMENT.md` exactly.

## Working with the human

- Surface tradeoffs before non-obvious choices; ask before touching anything under the
  spec's "Open questions."
- After each slice, report files changed, validation commands/results, and the next step.
- If this file contradicts the project, tell the developer and propose the smallest edit.
