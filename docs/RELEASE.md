# Release procedure

ZLAY `0.1.0` is locally finalized. The first release is scoped to verified native
x86-64 Linux plus the maintained `wasm32-freestanding` compile and Node runtime
smoke. Physical AArch64 certification remains separate ZL-202 work and does not
block this scoped release. Publication still requires an owner-selected
canonical source URL.

## Release candidate

1. Start from a reviewed, clean commit with Zig 0.17.x.
2. Run `/usr/bin/zig build verify-all --summary all`. This includes the basic,
   renderer, consumer, and mock paragraph-provider examples.
   When a canonical remote exists, also run the read-only `verify-all` workflow
   from the candidate commit and retain its hosted result.
3. Run `gitleaks dir --redact --no-banner .` and validate the read-only CI file
   with `actionlint .github/workflows/check.yml`.
4. Confirm `build.zig.zon`, `src/root.zig`, and `CHANGELOG.md` all identify
   `0.1.0`.
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
ZLAY through a local path. The latest current-source local `file://` archive
smoke is recorded in `.overzeer/release-smoke.md`; the canonical hosted URL
must still repeat that proof.

## Publication

1. Confirm the hosted archive bytes produce the reviewed package hash.
2. Confirm both the push/PR `check` job and manual `verify-all` workflow pass
   from the release commit.
3. Create the signed release tag and publish the changelog/release notes.
4. Re-run the URL consumer against the immutable tag archive.
5. Record the tag, archive URL, package hash, and CI run in `BACKLOG_ARCHIVE.md`,
   then close ZL-218.

## 0.1.0 release notes

- Supported: native x86-64 Linux and the maintained `wasm32-freestanding`
  compile plus Node runtime smoke.
- Included: dependency-free layout, interaction, scrolling, transitions,
  renderer commands, checked renderer dispatch, advanced paragraph-provider
  transport, fixed-buffer profiling, and the opt-in accessible inspector.
- Application-owned: fonts, shaping/rasterization, graphics APIs, assets,
  platform accessibility semantics, and final pixels.
- Not certified by this release: physical AArch64 execution, other operating
  systems, browsers, or concrete graphics/font backends.

Physical AArch64 certification remains ZL-202. State the x86-64 Linux and
freestanding-WebAssembly boundary in the release notes rather than implying
AArch64 or broader operating-system certification.
