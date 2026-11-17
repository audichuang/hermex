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
- Every `Fork: upstreamable` commit is ready to open upstream as it stands, whether or not we ever do:
  it meets upstream's bar on its own (tests, docs, a translation for every locale upstream's catalog has).
  A gap found later is folded into the commit that owns it, not added as a follow-up commit; that rewrite
  is pushed like an upstream rebase.
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
as a self-hosted runner (label `hermex-mac`, a launchd service from `~/actions-runner-hermex`): 2-3 minutes,
against about 17 on upstream's hosted `xcode-27` image. It runs for pushes to `develop` and PRs from this
repository only; app changes from another fork fail the gate until pushed here. That `if:` lives in the PR's own
workflow file, which a fork PR can rewrite, so the repo requires approval before any outside contributor's
workflow runs (Settings → Actions → Fork pull request workflows: all external contributors); keep it there and
never approve, push to, reopen or re-run a fork PR that touches `.github/`: a run you trigger needs no approval. Upstream's TestFlight workflow stays disabled. The PR body also
carries:

- the focused `scripts/test-sim <udid>` selection `AGENTS.md` § Verifying asks for, with its result;
- `scripts/fork/check-locales` when the catalog changed: a new or changed string has every upstream locale;
- for UI, evidence of how it looks (simulator or device screenshot, or a rendered view).

## Simulators on this Mac

Upstream's `DEVELOPMENT.md` assumes an `iPhone 17e` device pool managed by `hermex-flow`; neither exists on
this Mac (the fork owner's), so use these instead. The global rule is in `~/.agents/AGENTS.md` (iOS simulator
bullet); only the Hermex specifics are here.

- Prefix `HERMEX`. Resident device: `HERMEX iPhone 18 Pro Max` (iOS 27.2). Check
  `xcrun simctl list devices | grep HERMEX`. When it is idle the resident is parked on the NAS with
  `sim-vault` (the `modern-ios-guidance` skill, VER7), so a missing resident is normal. Restore it first,
  under the build lock; it comes back with the app and its login, under a new UDID:

  ```zsh
  lockf -k /tmp/hermex-build.lock sim-vault restore "HERMEX iPhone 18 Pro Max"
  ```

  A non-zero exit is handled as `~/.aghub/modern-ios-guidance/references/verification.md` VER7 says
  (which exits recreate the device, which wait or stop, when `--replace` applies); this file only adds the
  Hermex names. When VER7 says to recreate, this is the command (it does not boot the device):

  ```zsh
  xcrun simctl create "HERMEX iPhone 18 Pro Max" com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro-Max com.apple.CoreSimulator.SimRuntime.iOS-27-2
  ```

  When a batch of work is done, park it again under the same lock (VER7 says when it is safe to):

  ```zsh
  lockf -k /tmp/hermex-build.lock sim-vault park "HERMEX iPhone 18 Pro Max" --shutdown
  ```

- Temporary parallel devices: `HERMEX tmp <task>`.
- Agents working in parallel on the resident device take turns through one lock: wrap every
  `scripts/test-sim` and `xcodebuild` call in `lockf -k /tmp/hermex-build.lock …`. Writing code can overlap;
  builds and simulator runs wait in line.
- `scripts/test-sim` has no default device: run `scripts/test-sim <udid>` with the assigned device's UDID,
  never its name or `booted`. Look up the resident's UDID by name each time; do not hard-code it:

  ```zsh
  xcrun simctl list devices available | grep -F 'HERMEX iPhone 18 Pro Max'
  ```

- XcodeBuildMCP (`build_run_sim`) is not installed on this Mac. For UI verification, use the raw build
  fallback from `DEVELOPMENT.md` with the assigned UDID and serial execution. Set `udid` to the UDID
  looked up above (or the temporary device assigned to the task):

  ```zsh
  xcodebuild -project HermesMobile.xcodeproj -scheme HermesMobile -configuration Debug \
    -destination "id=${udid}" -parallel-testing-enabled NO \
    -derivedDataPath .build/DerivedData build
  ```

  Then, with that device booted for the UI check:

  ```zsh
  app=.build/DerivedData/Build/Products/Debug-iphonesimulator/HermesMobile.app
  xcrun simctl install "$udid" "$app"
  bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")
  xcrun simctl launch "$udid" "$bundle_id"
  ```

  Keep the normal Debug simulator signing; do not hand-sign. As `AGENTS.md` requires,
  `CODE_SIGNING_ALLOWED=NO` is only for compile-only checks, never a build installed on a simulator.
- Simulator window: `/Applications/Xcode.app/Contents/Applications/DeviceHub.app` (Xcode 27.2 has no Simulator.app).
  It lists other projects' devices; only touch `HERMEX` ones.
- Hermex build products are in the checkout's `.build/DerivedData/`. `scripts/test-sim` separately keeps
  logs and result bundles in `~/Library/Developer/Xcode/DerivedData/hermex-tests-<hash>/runs/`, where
  `<hash>` is the first 16 hex characters of SHA-256 of the resolved absolute checkout path. Removing
  a checkout leaves those external logs behind. To identify an orphan, read `-project` in its
  `runs/*/command.json`: it must name `HermesMobile.xcodeproj`, its parent checkout must no longer
  exist, and that path's hash must match the directory suffix. Keep it if ownership cannot be established.
  For `HermesMobile-*` caches, use `info.plist`'s `WorkspacePath` to establish Hermex ownership and
  confirm the checkout no longer exists; without that plist, list the directory but do not delete it.
  Before deleting any confirmed orphan, check `pgrep -fl xcodebuild`; defer cleanup while a Hermex
  build is running. Measure available space with `df -h /System/Volumes/Data` before and after.

## Release

`scripts/fork/testflight-release` from a clean checkout of a `develop` commit: archives, uploads with team
`37HFR5V2JJ`, tags `testflight/<build>`, and moves `main`. `ALLOW_UNMERGED=1` uploads a feature branch for a
quick phone test; its tag still records the commit. `DRY_RUN=1` prints the steps. It refuses a build that
lacks changes the current `main` has, judged by merging `main` into it, so squash-renamed commits pass (a
release from a `develop` that misses an unmerged PR would silently drop features); `ALLOW_DROP=1` only after checking `git diff fork/main HEAD`. If the upload succeeds
but recording fails, it prints the commands to push the tag and `main`; never re-upload to fix a record.
It then waits until App Store Connect lists the build `VALID` and `IN_BETA_TESTING` and prints `Ready`; tell the
owner a build is out only after that line (exit 2: uploaded but still processing, check again with the printed
command).

## Upstream rebase

Put the fork's commits back on top of the newest upstream `master`. Work from one freshly fetched
`fork/develop` SHA (never the local `develop`, which drifts) for the backup, the rebase, and the push lease:

```zsh
git fetch --multiple origin fork
base=$(git rev-parse fork/develop)
git push fork "${base}:refs/heads/backup/develop-$(date +%Y%m%d)"   # rollback point
git worktree add --detach ../hermex-wt/rebase "$base" && cd ../hermex-wt/rebase   # never the main checkout
git rebase --onto origin/master $(git merge-base "$base" origin/master)
# resolve conflicts commit by commit; a fork commit upstream already took comes out empty: drop it.
# If upstream merged it reworked, it conflicts instead: git checkout --ours <files>, then git rebase --skip
# recheck every upstreamable commit against the new upstream (a locale it added, an API it renamed)
# (scripts/fork/check-locales) and fold fixes in: git commit --fixup=<owner>, then
# GIT_SEQUENCE_EDITOR=true git rebase -i --autosquash origin/master
# run the merge gate, then:
git push --force-with-lease=develop:${base} fork HEAD:refs/heads/develop
```

Rebase open PR branches afterwards with `git rebase --onto fork/develop <their old base>`. Released commits
stay reachable through their `testflight/*` tags.

The first release after a rebase always stops at the `main` check: the old `main` is on the old history.
Run `git range-diff <old base>..<backup> origin/master..HEAD`; use `ALLOW_DROP=1` only when the missing
commits are ones upstream merged and the only changed ones are those whose conflicts you resolved.

## Upstream PRs

1. Cut `upstream/<topic>` from `origin/master` and cherry-pick the `Fork: upstreamable` commit(s)
   (`git log fork/develop --grep '^Fork: upstreamable'`), dropping the trailer.
2. Follow upstream's `CONTRIBUTING.md` and PR template: English, linked issue, how it was tested. The
   owner approves the full text before it is sent, and edits leave a public revision history that only
   the web UI can delete (no API), so get it right the first time:
   - No line says who did the work: no "Built with …", no author, model or reviewer names, even though
     upstream asks for an AI-use line.
   - Screenshots never show the owner's real sessions, titles, folders or chat text, and are not reused
     from fork PRs or cropped from private ones. Capture a test session with a neutral title, or describe
     the check in text.
   - `gh --attach` needs write access to the target repo, so it fails upstream. Upload with `--attach` on a
     fork PR or issue and paste the resulting `user-attachments` URL.
3. `gh pr create -R uzairansaruzi/hermex --head audichuang:upstream/<topic>`. Once upstream merges it, the
   next rebase drops the fork's copy (see Upstream rebase). Then check `upstream/<topic>` still points at
   the PR's merged head (`gh pr view <n> --json headRefOid`) and delete it on `fork` and locally.
4. Upstream CI runs on fresh hosted runners. Some ship a broken `iPhone 17` simulator and fail before
   building (`Unable to find a device matching the provided destination specifier`), and an unrelated test
   can fail once. Rerun a failing test locally on the branch before blaming the runner. We can't rerun
   upstream jobs, so close and reopen the PR, then wait on the new run with `gh-wait run <id>`:
   `gh-wait pr` can still report the previous run's failure.
