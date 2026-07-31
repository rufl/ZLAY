# Release procedure

ZLAY is still `0.1.0-dev`. The first release is scoped to verified native
x86-64 Linux plus the maintained `wasm32-freestanding` compile and Node runtime
smoke. Physical AArch64 certification remains separate ZL-202 work and does not
block this scoped release. Publication still requires an owner-selected
canonical source URL.

## Release candidate

1. Start from a reviewed, clean commit with `/usr/bin/zig` 0.16.x.
2. Run `/usr/bin/zig build verify-all --summary all`.
3. Run `gitleaks dir --redact --no-banner .` and validate the read-only CI file
   with `actionlint .github/workflows/check.yml`.
4. Change `build.zig.zon` from `0.1.0-dev` to the selected release version and
   finalize the matching changelog section.
5. Publish a source archive containing the paths listed by `build.zig.zon`.

## URL consumer proof

Fetch the exact candidate URL and retain the emitted Zig package hash:

```sh
/usr/bin/zig fetch <source-archive-url>
```

Copy `tests/consumer` to an empty directory, replace its `.zlay` dependency with
that exact URL and hash, then run:

```sh
/usr/bin/zig build
```

This must compile and execute the external-backend consumer without referring to
ZLAY through a local path. A current-source local `file://` archive smoke passed
before this procedure was recorded; the canonical hosted URL must still repeat
the proof.

## Publication

1. Confirm the hosted archive bytes produce the reviewed package hash.
2. Confirm the repository CI run passes from the release commit.
3. Create the signed release tag and publish the changelog/release notes.
4. Re-run the URL consumer against the immutable tag archive.
5. Record the tag, archive URL, package hash, and CI run in `BACKLOG_ARCHIVE.md`,
   then close ZL-218.

Physical AArch64 certification remains ZL-202. State the x86-64 Linux and
freestanding-WebAssembly boundary in the release notes rather than implying
AArch64 or broader operating-system certification.
