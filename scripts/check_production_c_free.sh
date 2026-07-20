#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd -- "$repo_root"

if ! command -v rg >/dev/null; then
    echo 'production C-free audit requires ripgrep (rg)' >&2
    exit 1
fi

if rg -n --glob '*.zig' '@cImport|\bextern\b|callconv\(\.c\)|addCSource|linkLibC' src; then
    echo 'production Zig sources must remain free of C imports, C ABI declarations, and C build hooks' >&2
    exit 1
fi

if [[ -z "$(rg --files src --glob '*.zig')" ]]; then
    echo 'production C-free audit found no Zig sources under src/' >&2
    exit 1
fi
