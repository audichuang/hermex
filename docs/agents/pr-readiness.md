# Pull Request Readiness

Read this before preparing, reviewing, updating, or handing off a Hermex pull
request. `CONTRIBUTING.md`, `PROJECT_SPEC.md`, and
`docs/agents/issue-tracker.md` remain authoritative; this document is the final
completion gate.

## Ready gate

A PR is ready for maintainer review only when every applicable item below passes.
Report unmet items as `Need to verify`; do not hide them behind a green unit-test run.

### Scope and root cause

- The work traces to the selected issue and contains one logical change.
- Every changed line belongs to that change; unrelated cleanup and generated noise are
  excluded.
- The fix lives at the shared root-cause boundary after checking all callers and sibling
  paths, rather than guarding only the reported UI action.
- API behavior is reconciled with live wire data and upstream source at a recorded SHA;
  documentation alone does not establish the contract.

### Behavior completion

- Exercise normal, empty, loading, error, retry, and cancellation states that the
  change can reach.
- A retry repeats the failed user intent, including the original path or selection; it
  must not silently reset to a convenient default.
- For UI changes, tap the complete expected control or row area, not only its visible
  label. Preserve accessibility labels, traits, and Reduce Motion behavior where
  applicable.
- Verify success behavior as well as failure handling. A test proving that two paths
  fail the same way is not acceptance evidence.

### Evidence

- Add the smallest regression test that fails without the fix, then run focused tests.
- Run the full XCTest suite after the final rebase and record passed, failed, and
  skipped counts.
- For UI/runtime changes, use a normally signed Debug build, launch it, and record the
  manual path, device/Simulator, OS, and result.
- Record unavailable live-server, wire, or UI proof as a verification gap.
- Run `git diff --check` and inspect staged, unstaged, and untracked files so local WIP
  and generated artifacts do not enter the PR.

### Review and PR description

- Triage every automated finding against the full caller and client/server contract.
  Fix valid findings minimally; reject unsupported findings with source or test
  evidence.
- The PR body links the issue, explains the behavior and root-cause boundary, lists
  exact validation results and known gaps, and discloses AI assistance.
- All review threads are resolved and required CI is green. A fork workflow marked
  `action_required` is awaiting maintainer approval, not a passing or failing test run.

## Observed maintainer completion signal

PR [#188](https://github.com/uzairansaruzi/hermex/pull/188) preserved the
contributor's centralized race/cancellation fix and tests. Before squash-merging it,
maintainer `uzairansaruzi` added two one-line completion commits:

- [`f2336f6`](https://github.com/uzairansaruzi/hermex/commit/f2336f6e85e975679debf6e72d57912be6f12c16)
  changed the empty-state action from loading root to retrying the failed path.
- [`255d473`](https://github.com/uzairansaruzi/hermex/commit/255d473f2ec8873dbaf478f9e09743e3d544c470)
  used native SwiftUI `.contentShape(Rectangle())` so the full folder row is tappable.

Treat this as evidence from one accepted PR, not a universal personal rule. The useful
review standard is stable: finish edge-state semantics and native interaction details
without broadening the architecture.

Before declaring a UI PR ready, ask:

> If the first request fails, the list is empty, or the user taps the blank part of the
> row, does the feature still do exactly what the PR claims?
