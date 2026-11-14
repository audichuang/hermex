# audichuang/hermex fork

This fork ships its own TestFlight app, **Hermex Audi** (bundle `com.audi.hermex.37hfr5v2jj`, team `37HFR5V2JJ`),
as a thin stack of small changes on top of upstream `uzairansaruzi/hermex`. These rules override upstream's
guidance in `AGENTS.md` wherever the two disagree.

## How the pieces fit

```text
Hermex Audi (this repo, TestFlight) ──HTTPS + Cloudflare Access──► Hermes host (Mac mini, ~/.hermes)
        ▲                                                            └ hermex-push plugin (audichuang/hermex-push)
        └── APNs ◄── hermex-relay-audi (Cloudflare Worker, relay/ in hermex-push) ◄──┘ HERMEX_PUSH_RELAY_URL
```

- The app talks only to the owner's Hermes host. Push goes host plugin → self-hosted relay → APNs; upstream's
  relay accepts only upstream's bundle ids and signs with upstream's APNs key, so this app needs the fork relay.
- The App Store **Hermex** (upstream bundle) still works as a client but gets no push while the host points
  at the fork relay. Switching back is a host setting, not an app change.
- Changes that alter what `groups.state`, `member_activity` or the pairing route send belong in Hermes or the
  plugin, not here; read the host's installed Hermes (`~/.hermes/hermes-agent`), not an upstream checkout.

## Terms

- **`fork`** is `https://github.com/audichuang/hermex.git`; **`origin`** is upstream (read only).
- **`develop`** (default branch) = upstream `master` tip + the fork's commits, kept as a linear stack on top.
- **`main`** = the commit of the build on TestFlight now. Every upload is also tagged `testflight/<build>`.
- Every fork commit carries a trailer, `Fork: upstreamable` or `Fork: fork-only` (signing, bundle ids, relay).
  The trailer survives rebases; PR labels do not.

## Red lines

- Work on a branch cut from `fork/develop`, open a PR into `develop` (`-R audichuang/hermex`), and merge it
  with `scripts/fork/merge-pr <pr> <upstreamable|fork-only> "<English subject>"`: one squash commit with one
  `Fork:` trailer, checked after the merge. Only an upstream rebase and a release push `develop`/`main`.
- One topic per PR; never mix upstreamable and fork-only changes in one commit.
- Keep changes small. Anything that rewrites shared upstream code broadly makes every rebase a conflict:
  prefer a new small file or an extension over editing large upstream files.
- An agent merges, releases, rebases, or opens an upstream PR only when the owner asked for that piece of work.
- Never commit `Config/Local.xcconfig`, `.p8` keys, App Store Connect or Cloudflare credentials.

## GitHub rules

Rulesets: **`develop: linear stack on upstream`** (no deletion, linear history) and **`main: release
pointer`** (no deletion). Force-push stays allowed because a rebase needs it. The repo allows squash merges
only, with a blank default message, so the `Fork:` trailer comes from `merge-pr`.

## Merge gate

`PR CI`'s **CI Gate** must pass. Its macOS job (full suite and String Catalog check) runs on the owner's Mac mini
as a self-hosted runner (label `hermex-mac`, a launchd service from `~/actions-runner-hermex`): hosted macOS
images have no Xcode 27. It runs for pushes to `develop` and PRs from this repository only; app changes from
another fork fail the gate until pushed here. Upstream's TestFlight workflow stays disabled. The PR body also
carries:

- the focused `scripts/test-sim <udid>` selection `AGENTS.md` § Verifying asks for, with its result;
- for UI, evidence of how it looks (simulator or device screenshot, or a rendered view).

## Release

`scripts/fork/testflight-release` from a clean checkout of a `develop` commit: archives, uploads with team
`37HFR5V2JJ`, tags `testflight/<build>`, and moves `main`. `ALLOW_UNMERGED=1` uploads a feature branch for a
quick phone test; its tag still records the commit. `DRY_RUN=1` prints the steps. It refuses a build that
lacks changes the current `main` has, judged by merging `main` into it, so squash-renamed commits pass (a
release from a `develop` that misses an unmerged PR would silently drop features); `ALLOW_DROP=1` only after checking `git diff fork/main HEAD`. If the upload succeeds
but recording fails, it prints the commands to push the tag and `main`; never re-upload to fix a record.

## Upstream rebase

Put the fork's commits back on top of the newest upstream `master`. Work from one freshly fetched
`fork/develop` SHA (never the local `develop`, which drifts) for the backup, the rebase, and the push lease:

```zsh
git fetch --multiple origin fork
base=$(git rev-parse fork/develop)
git push fork "${base}:refs/heads/backup/develop-$(date +%Y%m%d)"   # rollback point
git switch --detach "$base"
git rebase --onto origin/master $(git merge-base "$base" origin/master)
# resolve conflicts commit by commit; a fork commit upstream already took comes out empty: drop it
# run the merge gate, then:
git push --force-with-lease=develop:${base} fork HEAD:refs/heads/develop
```

Rebase open PR branches afterwards with `git rebase --onto fork/develop <their old base>`. Released commits
stay reachable through their `testflight/*` tags.

## Upstream PRs

1. Cut `upstream/<topic>` from `origin/master` and cherry-pick the `Fork: upstreamable` commit(s)
   (`git log fork/develop --grep '^Fork: upstreamable'`), dropping the trailer.
2. Follow upstream's `CONTRIBUTING.md` and PR template: English, linked issue, how it was tested, AI-use
   disclosure. The owner approves the full text before it is sent.
3. `gh pr create -R uzairansaruzi/hermex --head audichuang:upstream/<topic>`. Once upstream merges it, the
   next rebase drops the fork's copy as empty.
