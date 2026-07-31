# Security Policy

## Supported Surface

Security fixes target the current `0.1.0-dev` branch. ZLAY is a local library:
it opens no sockets, performs no telemetry or update checks, and stores no
credentials. Applications remain responsible for validating external font,
image, and custom-renderer inputs before passing opaque handles to ZLAY.

## Reporting

Report suspected vulnerabilities privately to the repository owner before
public disclosure. Include the affected revision, a minimal reproducer, impact,
and whether malformed input crosses an application-to-ZLAY trust boundary.
Do not include real secrets or personal data.

## Maintainer Checks

- Run `gitleaks git --redact --no-banner` when available.
- Run `zig build verify-all` with the supported Zig 0.16.x toolchain.
- Review allocator failure, callback reentry, borrowed-pointer lifetime,
  command-union tagging, provider leases, integer bounds, and build scripts.
- Keep CI actions pinned and permissions read-only unless a release task
  explicitly requires more.

The pinned C header and C fixtures are test-only differential oracles. They are
not linked into production artifacts.