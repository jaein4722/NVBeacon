# NVBeacon Repository Guide

## Development Strategy

This repository follows GitHub Flow.

- `master` is the release-ready default branch.
- Create a short-lived, descriptive branch from the latest `master` for each change.
- Push the branch and open a pull request targeting `master`.
- Run the relevant checks and review the change before merging the pull request.
- Delete the feature branch after it has been merged and is no longer needed.
- Tag releases from the verified commit on `master`.
- Do not introduce long-lived `develop`, `release/*`, or `hotfix/*` branches. Urgent fixes use the same branch-and-pull-request flow.

Recommended branch naming:

- `feat/<topic>` for new user-facing features
- `fix/<topic>` for bug fixes
- `chore/<topic>` for tooling, build, or cleanup work
- `docs/<topic>` for README or documentation-only changes

Keep unrelated work on separate branches and use separate worktrees when another branch has uncommitted changes. References fetched from contributor forks are review inputs; integrate accepted changes through a feature branch and pull request.

When integrating contributor code, preserve the original commits and authorship where practical. Put adaptations and fixes in follow-up commits, and identify the original contribution in the pull request. If commits must be cherry-picked, use `-x` to record their source; if squashing, retain contributor credit with `Co-authored-by` trailers.

## Release Strategy

Use lightweight semantic versioning:

- Patch: `0.2.1 -> 0.2.2` for bug fixes, packaging fixes, UI polish, workflow updates
- Minor: `0.2.x -> 0.3.0` for backward-compatible features
- Major: `0.x -> 1.0` only when the project stabilizes and intentionally breaks compatibility

Release flow:

1. Merge the final release candidate, including its `CHANGELOG.md` entry, into `master` through a pull request.
2. Verify `swift test` passes.
3. Create a tag in the form `vX.Y.Z`.
4. Push the tag.
5. GitHub Actions builds a DMG and publishes a GitHub Release from that tag with an SEO-friendly title and opening summary.

Tags are the source of truth for GitHub Releases.

Release page guidance:

- Keep release titles in the form `NVBeacon X.Y.Z: macOS menu bar app for remote NVIDIA GPU monitoring over SSH`.
- Keep the opening release summary keyword-rich and factual. Mention `macOS`, `remote NVIDIA GPU`, `SSH`, `nvidia-smi`, and major alerting capabilities when relevant.
- Use the matching `CHANGELOG.md` entry for the version-specific details.

## Day-to-Day Workflow

Before starting work:

1. Check the current branch and working tree. Preserve any existing uncommitted work.
2. From a clean `master` worktree, update it with `git pull --ff-only origin master`.
3. Create a short-lived branch from the updated `master`. If another worktree has in-progress changes, fetch `origin/master` and create a separate branch/worktree from it instead.
4. Commit focused changes on that branch and open a pull request targeting `master`.

Before merging or tagging:

1. Run `swift test`.
2. Run `./scripts/package_app.sh` if packaging changed.
3. Update `README.md` when user-facing behavior, setup, or release steps changed.
4. Confirm the pull request checks pass and review is complete before merging.

## Test App Rule

- During normal feature work, build a fresh test app after each commit when the user is actively testing the app.
- When the user explicitly asks for a release, do not build or open a test app as part of the release flow unless they ask for it separately.
- Assume a release request means the user has already finished validation and wants the release path to stay minimal.

## Commit Guidance

Keep commits focused and reviewable.

- Prefer one topic per commit.
- Use direct messages such as `Fix settings opening` or `Release 0.2.2`.
- Squash noisy intermediate commits before merging when practical.

## Packaging Rules

- `scripts/package_app.sh` is the canonical packaging entrypoint.
- Release artifacts should be DMG-based: `NVBeacon-<version>.dmg`.
- Local builds are ad-hoc signed by default.
- Public distribution without Gatekeeper warnings requires Developer ID signing and notarization.

## Repository Safety

Never commit:

- `dist/`
- `.build/`
- `.env` or `.env.*`
- signing certificates, provisioning profiles, or keychain exports
- real SSH passwords, private keys, or Apple credentials

Avoid committing real hostnames, usernames, or internal IP addresses in docs or tests unless they are explicitly meant to be public examples.

## Automation Notes

- Tag pushes create GitHub Releases automatically.
- The release workflow should upload the generated DMG asset for the matching tag.
- The release workflow should keep release titles and opening summaries aligned with the repository SEO positioning.
- If signing or notarization is enabled in CI later, keep secrets in GitHub Actions secrets, never in the repository.
