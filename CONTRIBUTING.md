# Contributing

Thank you for improving OpenClaw on NAS. This project packages and operates
OpenClaw for LAN-only Docker deployments, with Synology compatibility as a
first-class requirement.

## Quick path

1. Search existing issues before starting work.
2. For non-trivial changes, open or comment on an issue and wait for the
   `status:approved` label.
3. Fork the repository and create a focused branch.
4. Make one coherent change, validate it, and open a pull request to `main`.

## Before you open a pull request

- Do not commit tokens, certificates, `.env` files, backups, or NAS-specific
  addresses.
- Use a conventional commit message, for example `fix: repair certificate path`.
- Update the README when installation, updates, security, or recovery behavior
  changes.
- Keep pull requests focused. Separate documentation-only changes from runtime
  behavior when practical.

### Shell validation

Run these checks from the repository root:

```bash
bash -n openclaw install.sh scripts/*.sh
docker run --rm -v "$PWD:/mnt" koalaman/shellcheck:stable \
  /mnt/openclaw /mnt/install.sh \
  /mnt/scripts/migrate-openclaw.sh \
  /mnt/scripts/update-openclaw-version.sh
docker compose config --quiet
```

If your change affects installation, migration, Nginx, permissions, or the
container image, describe the validation you performed in the PR. Synology
changes should be tested on a clean installation and, when relevant, on an
upgrade path.

## Pull request expectations

- Link the approved issue with `Closes #<number>` when applicable.
- Select exactly one `type:*` label.
- Explain the user-visible behavior and the rollback or recovery path.
- Include test output or concise manual validation steps.
- Never add AI or co-author attribution trailers unless a maintainer explicitly
  asks for them.

## Security reports

Do not report vulnerabilities in public issues. Follow
[SECURITY.md](SECURITY.md) instead.
