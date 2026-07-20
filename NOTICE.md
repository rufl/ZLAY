# Upstream attribution

ZLAY is an independent, altered native Zig rewrite of **Clay**, the C UI layout
library by Nic Barker. It is not the original Clay distribution and is not an
official Nic Barker project.

The behavioral reference is the header-declared 0.14 snapshot at commit
`e6cc36941ab2af5d81107617039d6f527a1c660b` (2026-05-20):
<https://github.com/nicbarker/clay>.

The full commit and pinned `clay.h` digest, rather than the version comment,
identify the source baseline. See `docs/UPSTREAM.md`.

Clay and this altered port are distributed under the zlib/libpng license in
`LICENSE.md`. No C source is compiled, linked, or loaded by the production ZLAY
module; the pinned header is compiled only by opt-in verification fixtures.
