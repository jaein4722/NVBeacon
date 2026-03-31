# GPUUsage Repository Guide

## Development Strategy

This repository should stay simple. Prefer trunk-based development over GitFlow.

- `master` is the release-ready trunk branch.
- Keep feature branches short-lived.
- Do not add a long-lived `develop` branch unless the project grows substantially.
- Tag releases from `master`.

Recommended branch naming:

- `feat/<topic>` for new user-facing features
- `fix/<topic>` for bug fixes
- `chore/<topic>` for tooling, build, or cleanup work
- `docs/<topic>` for README or documentation-only changes

Use `release/<version>` or `hotfix/<version>` only if an already-published version must be maintained separately. For this project, avoid those branches by default.

## Release Strategy

Use lightweight semantic versioning:

- Patch: `0.2.1 -> 0.2.2` for bug fixes, packaging fixes, UI polish, workflow updates
- Minor: `0.2.x -> 0.3.0` for backward-compatible features
- Major: `0.x -> 1.0` only when the project stabilizes and intentionally breaks compatibility

Release flow:

1. Merge or commit the final release candidate into `master`.
2. Verify `swift test` passes.
3. Create a tag in the form `vX.Y.Z`.
4. Push the tag.
5. GitHub Actions builds a DMG and publishes a GitHub Release from that tag.

Tags are the source of truth for GitHub Releases.

## Day-to-Day Workflow

Before starting work:

1. Update local trunk with `git pull --ff-only origin master`.
2. Create a short-lived branch if the change is larger than a tiny fix.

Before merging or tagging:

1. Run `swift test`.
2. Run `./scripts/package_app.sh` if packaging changed.
3. Update `README.md` when user-facing behavior, setup, or release steps changed.

## Commit Guidance

Keep commits focused and reviewable.

- Prefer one topic per commit.
- Use direct messages such as `Fix settings opening` or `Release 0.2.2`.
- Squash noisy intermediate commits before merging when practical.

## Packaging Rules

- `scripts/package_app.sh` is the canonical packaging entrypoint.
- Release artifacts should be DMG-based: `GPUUsage-<version>.dmg`.
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
- If signing or notarization is enabled in CI later, keep secrets in GitHub Actions secrets, never in the repository.
