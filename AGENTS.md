# NVBeacon Repository Guide

This guide applies to everyone working in this repository, including coding agents. If `AGENTS.local.md` exists in the root of the main checkout (the first path in `git worktree list`), read it as well and follow it. It holds maintainer-only notes and is never committed.

## Development Strategy

This repository follows GitHub Flow.

- `master` is the release-ready default branch.
- Create a short-lived, descriptive branch from the latest `master` for each change.
- After explicit approval, push the branch and open a pull request targeting `master`.
- Run the relevant checks and review the change before merging the pull request.
- Delete the feature branch after it has been merged and is no longer needed.
- Do not introduce long-lived `develop`, `release/*`, or `hotfix/*` branches. Urgent fixes use the same branch-and-pull-request flow.
- Maintainers handle version numbers, tags, and releases.

Recommended branch naming:

- `feat/<topic>` for new user-facing features
- `fix/<topic>` for bug fixes
- `chore/<topic>` for tooling, build, or cleanup work
- `docs/<topic>` for README or documentation-only changes

Keep unrelated work on separate branches and use separate worktrees when another branch has uncommitted changes.

## Push and Pull Request Approval

Never push a branch or tag, or open, update, or merge a pull request, without explicit approval for that action from the person directing the work. Instructions to work on a change, commit it, follow this workflow, or prepare a release are not approval. This also applies to draft pull requests.

## Pull Request Format

Write pull requests in English and target `master`.

Use an imperative, sentence-case title with no type prefix or trailing period, such as `Add optional host metrics and collapsible server sections`.

```markdown
One or two sentences on what changes and why.

- Main change and its user-visible effect.
- Other notable change or behavior.

Tested with:

- `swift test --build-system native` - N app tests passed.
- `swift test --package-path Shared/NVBeaconCore --build-system native` - N core tests passed.
- Local test app build and the affected UI checked.

Closes #N.
```

- List only checks that were actually run, with their results, and state relevant checks that were not completed, such as live SSH collection.
- Include `Closes #N` only when the pull request fully resolves that issue.
- Do not add `Title`, `Body`, or changed-file sections; the pull request and its diff already show them.

## Day-to-Day Workflow

Before starting work:

1. Check the current branch and working tree. Preserve any existing uncommitted work.
2. From a clean `master` worktree, update it with `git pull --ff-only origin master`.
3. Create a short-lived branch from the updated `master`. If another worktree has in-progress changes, fetch `origin/master` and create a separate branch/worktree from it instead.
4. Commit focused changes on that branch. After explicit approval, push it and open a pull request targeting `master`.

Before merging:

1. Run `swift test --build-system native` and `swift test --package-path Shared/NVBeaconCore --build-system native`.
2. Run `./scripts/package_app.sh` if packaging changed.
3. Update `README.md` when user-facing behavior or setup changed.
4. Confirm the pull request checks pass and review is complete before merging.

## Test App Rule

During normal feature work, build a fresh test app with `OPEN_APP=1 ./scripts/build_test_app.sh` after each commit when the person directing the work is actively testing the app.

## Commit Guidance

Keep commits focused and reviewable. Commit often on your working branch; local commits do not need separate approval.

- Prefer one topic per commit.
- Use direct messages such as `Fix settings opening`.
- Squash noisy intermediate commits before merging when practical.

## Packaging Rules

- `scripts/package_app.sh` is the canonical packaging entrypoint.
- Release artifacts should be DMG-based: `NVBeacon-<version>.dmg`.
- Local builds are ad-hoc signed by default.

## Repository Safety

Never commit:

- `dist/`
- `.build/`
- `.env` or `.env.*`
- signing certificates, Sparkle private keys, provisioning profiles, or keychain exports
- real SSH passwords, private keys, or Apple credentials

Avoid committing real hostnames, usernames, or internal IP addresses in docs or tests unless they are explicitly meant to be public examples.
