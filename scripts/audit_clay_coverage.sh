#!/usr/bin/env bash
set -euo pipefail

certify=false
keep_artifacts=false
for argument in "$@"; do
    case "$argument" in
        --certify) certify=true ;;
        --keep-artifacts) keep_artifacts=true ;;
        *)
            echo "usage: $0 [--certify] [--keep-artifacts]" >&2
            exit 2
            ;;
    esac
done
if [[ "$certify" == false ]]; then
    keep_artifacts=true
fi

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd -- "$repo_root"

required_tools=(clang llvm-profdata llvm-cov)
if [[ "$certify" == true ]]; then
    required_tools+=(python3)
fi
for tool in "${required_tools[@]}"; do
    command -v "$tool" >/dev/null || {
        echo "missing required coverage tool: $tool" >&2
        exit 1
    }
done

output_dir="$(mktemp -d "${TMPDIR:-/tmp}/zlay-clay-coverage.XXXXXX")"
cleanup_output() {
    status=$?
    if [[ "$keep_artifacts" == false ]]; then
        rm -rf -- "$output_dir"
    elif (( status != 0 )); then
        echo "coverage artifacts retained after failure: $output_dir" >&2
    fi
}
trap cleanup_output EXIT

emit_coverage_artifacts() {
    local profile_dir="$1"
    shift
    local -a profile_binaries=("$@")
    local -a object_args=()
    local binary

    llvm-profdata merge -sparse "$profile_dir"/*.profraw \
        -o "$profile_dir/merged.profdata"
    for binary in "${profile_binaries[@]:1}"; do
        object_args+=(-object "$binary")
    done

    llvm-cov report "${profile_binaries[0]}" "${object_args[@]}" \
        -instr-profile="$profile_dir/merged.profdata" \
        -sources tests/oracle/clay.h | tee "$profile_dir/report.txt"
    llvm-cov show "${profile_binaries[0]}" "${object_args[@]}" \
        -instr-profile="$profile_dir/merged.profdata" \
        -sources tests/oracle/clay.h \
        -show-line-counts-or-regions \
        -show-branches=count >"$profile_dir/clay.show.txt"
    llvm-cov show "${profile_binaries[0]}" "${object_args[@]}" \
        -instr-profile="$profile_dir/merged.profdata" \
        -sources tests/oracle/clay.h \
        -show-line-counts >"$profile_dir/clay.lines.txt"
    llvm-cov export "${profile_binaries[0]}" "${object_args[@]}" \
        -instr-profile="$profile_dir/merged.profdata" \
        -sources tests/oracle/clay.h >"$profile_dir/export.json"
}

scalar_dir="$output_dir/scalar"
simd_dir="$output_dir/x86_64-simd"
mkdir -p -- "$scalar_dir" "$simd_dir"

scalar_binaries=()
for source in tests/oracle/*_fixture.c; do
    name="$(basename "$source" .c)"
    binary="$scalar_dir/$name"
    profile="$scalar_dir/$name.profraw"
    clang -std=c99 -I tests/oracle -DCLAY_DISABLE_SIMD= \
        -fprofile-instr-generate -fcoverage-mapping \
        "$source" -o "$binary"
    LLVM_PROFILE_FILE="$profile" "$binary" >"$scalar_dir/$name.stdout"
    if [[ ! -s "$profile" ]]; then
        echo "coverage fixture did not emit a nonempty scalar profile: $source" >&2
        exit 1
    fi
    scalar_binaries+=("$binary")
done

case "$(uname -m)" in
    x86_64 | amd64) ;;
    *)
        echo "x86_64 SIMD coverage supplement requires an x86_64 host" >&2
        exit 1
        ;;
esac
simd_source="tests/oracle/hash_default_fixture.c"
simd_binary="$simd_dir/hash_default_fixture"
simd_profile="$simd_dir/hash_default_fixture.profraw"
clang -std=c99 -I tests/oracle \
    -fprofile-instr-generate -fcoverage-mapping \
    "$simd_source" -o "$simd_binary"
LLVM_PROFILE_FILE="$simd_profile" "$simd_binary" >"$simd_dir/hash_default_fixture.stdout"
if [[ ! -s "$simd_profile" ]]; then
    echo "coverage fixture did not emit a nonempty x86_64 SIMD profile: $simd_source" >&2
    exit 1
fi

echo "Clay coverage profile: scalar/common"
emit_coverage_artifacts "$scalar_dir" "${scalar_binaries[@]}"
echo "Clay coverage profile: x86_64 SIMD supplement (whole-header raw report; certification scopes the active x86_64 bodies)"
emit_coverage_artifacts "$simd_dir" "$simd_binary"

if [[ "$certify" == true ]]; then
    python3 -B scripts/check_clay_coverage.py \
        --repo-root "$repo_root" \
        --manifest tests/oracle/clay_coverage_manifest.json \
        --export "$scalar_dir/export.json" \
        --report "$scalar_dir/report.txt" \
        --line-view "$scalar_dir/clay.lines.txt" \
        --simd-export "$simd_dir/export.json" \
        --simd-report "$simd_dir/report.txt" \
        --simd-line-view "$simd_dir/clay.lines.txt"
fi

if [[ "$keep_artifacts" == true ]]; then
    echo "coverage artifacts: $output_dir"
else
    echo "coverage certification scratch artifacts cleaned on exit"
fi
