# ZLAY Roadmap

## Now

- Keep `zig build verify-all` green across Debug, ReleaseSafe, ReleaseFast,
  ReleaseSmall, native, and freestanding WebAssembly lanes.
- Keep renderer and paragraph-provider contracts allocation-safe, bounded, and
  independent of any concrete graphics or font dependency.

## Next

- Select the canonical release URL, remove the development version suffix,
  verify a clean hosted-URL consumer, and tag the x86-64 Linux plus
  freestanding-WebAssembly release using `docs/RELEASE.md`.
- Integrate a concrete shaping/raster backend only when an application selects
  one and can supply runtime fixtures for fallback, bidirectional text,
  variations, color glyphs, and atlas lifetime.
- Add focused performance work only after the existing profile or a bounded
  benchmark identifies a regression.

## Externally Blocked

- Close ZL-202 only after current-source execution on qualifying physical
  AArch64 hardware produces the required imported evidence and human review
  receipt. Emulation and cross-compilation remain non-closing evidence.

## Non-Goals

- ZLAY will not become a graphics API, font loader, rasterizer, image decoder,
  application framework, or dependency wrapper.