# Reference ports

The pinned `clay.h` remains ZLAY's only behavioral authority. Three independent
ports were reviewed for implementation ideas and failure modes; no source from
them is compiled, vendored, or treated as an oracle.

| Port | License | Useful direction | Why it is not normative |
| --- | --- | --- | --- |
| [soypat/glay](https://github.com/soypat/glay) | BSD-3-Clause | Readable Go-shaped data structures and a compact view of the sizing pipeline | Targets a smaller feature set and does not provide equivalent debug, transition, scroll, pointer, or differential coverage |
| [totallygamerjet/clay](https://github.com/totallygamerjet/clay) | MIT | Demonstrates how generated translations expose hidden global/context and libc assumptions | The cxgo-derived implementation retains C-shaped unsafe/runtime machinery and is not a native-language behavioral rewrite |
| [igadmg/goclay](https://github.com/igadmg/goclay) | zlib/libpng | The strongest of the three test layouts and a useful cross-check for Go ownership choices | It is incomplete relative to the pinned 2026 header and its own test/dependency surface is not a substitute for the C oracle |

The review influenced ZLAY in three concrete ways:

- the public model uses native Zig values, slices, optionals, and callbacks
  instead of translated C wrappers;
- the mutable engine lives in an explicit `Context`, so independent contexts do
  not share a translated global current-context pointer; and
- parity claims require compiled output from the exact pinned C header rather
  than agreement with another port.

When a reference port and `clay.h` disagree, `docs/UPSTREAM.md` defines the
authority order. License texts from these ports are not included because ZLAY
does not copy their code; Clay's original zlib notice and ZLAY's altered-source
notice remain in `LICENSE.md` and `NOTICE.md`.
