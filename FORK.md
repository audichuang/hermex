# audichuang/hermex fork

This fork ships its own TestFlight build (**Hermex Audi**, bundle `com.audi.hermex.37hfr5v2jj`, team `37HFR5V2JJ`)
and sends the parts upstream would want back to `uzairansaruzi/hermex` as separate PRs. These rules override
upstream's guidance in `AGENTS.md` wherever the two disagree.

## Terms

- **`fork`** is `https://github.com/audichuang/hermex.git`. **`origin`** is upstream `uzairansaruzi/hermex`.
- **`develop`** (the default branch) is the integration branch: an upstream `master` commit plus the fork's work,
  merged in by PR.
- **`main`** points at the commit of the last build uploaded to TestFlight. It moves only at release time.
- **Fork-only** changes stay here (signing, bundle ids, the self-hosted push relay). **Upstreamable** changes
  are features or fixes upstream could take as they are. Every PR into `develop` is labelled one or the other.

## GitHub rules

Because upstream is merged in rather than rebased onto, history is never rewritten, so GitHub enforces the
model (repository rulesets):

- **`develop: PR only`**: changes only through a PR, merged with a merge commit; no force-push, no deletion.
- **`main: release pointer`**: no force-push, no deletion. A release moves it by fast-forward to a `develop`
  commit, so `main` is always an ancestor of `develop`.

## Red lines

- Every change, docs included, goes on a branch cut from `fork/develop` and a PR into `develop`, merged with a
  merge commit. Nobody pushes `develop` directly (upstream syncs are PRs too); only a release pushes `main`.
- Pass `-R audichuang/hermex` to every `gh pr` and `gh issue` that targets the fork.
- Keep one topic per PR. Never mix fork-only and upstreamable commits in one PR: the upstream PR is built by
  cherry-picking that PR's commits.
- An agent merges a PR, releases, or opens an upstream PR only when the owner asked for that piece of work.
- Never commit `Config/Local.xcconfig`, `.p8` keys, App Store Connect or Cloudflare credentials.

## Merge gate

Upstream's `PR CI` runs on upstream's own `xcode-27` runner, so it is disabled on this fork (along with the
upstream TestFlight workflow). Until the fork has its own CI, the gate is local and recorded in the PR body:

- the focused `scripts/test-sim <udid>` selection `AGENTS.md` § Verifying asks for, with its result;
- `python3 ci/check_string_catalog.py --derived-data .build/DerivedData --configuration Debug-iphonesimulator`;
- for UI changes, evidence of how it looks (simulator or device screenshot, or a rendered view).

## Release

A release is one TestFlight upload of a `develop` commit.

1. Archive that exact commit with `CURRENT_PROJECT_VERSION=$(date +%Y%m%d%H%M%S)` and upload it with team
   `37HFR5V2JJ` export options (the commands live in the owner's notes, not here).
2. Tag it and move `main` in one push:
   `git tag -a v<marketing>-fork.<N> <sha> -m "<build number>: <what changed>"` then
   `git push --atomic fork <sha>:refs/heads/main v<marketing>-fork.<N>`.
   `<marketing>` is the app's `MARKETING_VERSION`; `<N>` counts up per marketing version.

## Upstream sync

Merge upstream `master` into `develop` through a PR (`sync/upstream-<date>`), so fork history is never
rewritten and `main` only fast-forwards. Resolve conflicts on that branch, run the merge gate, then merge.

## Upstream PRs

1. Cut `upstream/<topic>` from `origin/master`.
2. Cherry-pick the commits of the upstreamable fork PR (`git cherry-pick <first>^..<last>`), never `develop`
   itself, and rerun upstream's checks for that change.
3. Follow upstream's `CONTRIBUTING.md` and PR template: English, linked issue, how it was tested, AI-use
   disclosure. The owner (or the reviewing agent) approves the full text before it is sent.
4. Open it with `gh pr create -R uzairansaruzi/hermex --head audichuang:upstream/<topic>`. Whether upstream
   merges it does not block the fork; the fork keeps shipping from `develop`.
