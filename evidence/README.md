# AArch64 hash evidence

This directory defines the raw execution-record and human provenance-review
contracts for backlog row `ZL-202`. No placeholder or synthetic raw record,
runner record, completed certification log, or review receipt is checked in.
Python 3.10 or newer is required by the evidence and review tools. ZL-202 is
externally blocked in this checkout by the absence of a qualifying physical
AArch64 runner and resulting artifact set, not by a known workflow failure.

[`aarch64-hash-evidence.schema.json`](aarch64-hash-evidence.schema.json)
documents the raw `zlay.aarch64-hash-execution.v1` shape, and
[`aarch64-hash-runner-preflight.schema.json`](aarch64-hash-runner-preflight.schema.json)
documents the cache-managed `zlay.aarch64-runner-preflight.v1` binding consumed
by certification. Likewise,
[`aarch64-hash-review.schema.json`](aarch64-hash-review.schema.json) documents
the `zlay.aarch64-hash-review-receipt.v1` shape. The fail-closed Python
validators are normative because they also recompute current source-contract
digests, validate the pre-gate certification-input snapshot, recompute canonical
payload digests, strictly re-parse and bind the exact native test-run logs, and
check exact trace contracts and local artifact bindings.

## Supplemental QEMU execution is outside this workflow

`qemu-aarch64` is optional contributor tooling. When it is available on
`PATH`, the supplemental AArch64 user-mode lane can be run with:

```sh
zig build aarch64-hash-qemu
```

The lane internally pins static Debug `aarch64-linux-musl` root tests,
ordinary-manifest tests, and C/Zig target-default hash fixtures. It runs each
target artifact through `qemu-aarch64 -cpu max`, compares the exact trace on the
host, and emits runtime QEMU/Zig, target/source, artifact, and trace identities.
Both its oracle marker and runtime report state
`certification=false physical_machine_proof=false backlog_closed=false`.

The lane's mutation contract is host-only and can be checked without QEMU:

```sh
zig build aarch64-hash-qemu-audit
```

These commands do not read, create, validate, import, or review raw-v1 evidence
or runner provenance, and they do not enter the certification DAG. The QEMU
report is not a runner record, certification log, review attachment, or closure
artifact. It proves only execution under the identified emulator; ZL-202 stays
open for physical non-emulated AArch64 execution and the complete evidence,
import, review, and maintainer-closure sequence below.

## 1. Audit the workflows

Run the host comparison, cross-compile prerequisite, and all three focused
mutation audits before collecting evidence:

```sh
zig build hash-default-parity
zig build aarch64-hash-compile -Dtarget=aarch64-linux
zig build aarch64-hash-evidence-audit
zig build aarch64-hash-build-contract-audit
zig build aarch64-hash-review-audit
```

These gates prove the local contracts and build wiring, including mutation
coverage for the runner preflight, preflight-only capture input, pre-gate source
snapshot, and both dependency DAGs. They are not AArch64 execution evidence.

## 2. Prepare the runner identity record

Before certification, create an immutable identity/inventory record for the
runner. Its exact bytes may use a locally appropriate durable format, but the
record should independently identify the runner and machine being claimed. For
example, store it at `/durable/path/runner-record.json`, then create provenance
from those actual bytes:

```sh
python3 -B scripts/aarch64_hash_evidence.py runner-provenance-create \
  --runner-record=/durable/path/runner-record.json \
  --runner-record-uri=file:///durable/path/runner-record.json \
  --runner-id='<stable runner identity>' \
  --hardware-model='<physical machine model>' \
  --recorded-by='<operator or CI identity>' \
  --claim-physical-non-emulated \
  --output=/durable/path/runner-provenance.json
```

The command reads the bounded runner-record bytes, computes their SHA-256,
writes a new non-overwriting provenance record at the durable output path, and
prints its digest and the runner-record digest and byte count. The required
`--claim-physical-non-emulated` flag records this explicit operator claim; it is
not machine proof of physical hardware or non-emulation. The generated file has
this shape:

```json
{
  "attachment": {
    "sha256": "<lowercase SHA-256 of the exact runner-record bytes>",
    "uri": "file:///durable/path/runner-record.json"
  },
  "hardware_model": "<physical machine model>",
  "operator_claim": "physical-non-emulated",
  "recorded_by": "<operator or CI identity>",
  "runner_id": "<stable runner identity>",
  "schema": "zlay.aarch64-runner-provenance.v1"
}
```

The attachment is a pre-run identity/inventory record. It must not be the
certification log: the attachment digest is embedded in the raw record before
the final capture marker exists, so using the completed log would be circular.
Validate the provenance against the exact record bytes locally before the run:

```sh
zig build aarch64-hash-runner-preflight \
  -Daarch64-provenance=/durable/path/runner-provenance.json \
  -Daarch64-runner-record=/durable/path/runner-record.json
```

Success prints an exact `runner-provenance-valid ...
physical_machine_proof=false backlog_closed=false` marker. This local check
does not fetch the URI, authenticate the operator claim, prove physical
hardware, or close `ZL-202`.

## 3. Capture on the AArch64 runner

Run in Debug on the recorded AArch64 machine with no target override. Capture
both standard output and standard error, and preserve the pipeline failure
status:

```sh
set -o pipefail
zig build aarch64-hash-certify -Doptimize=Debug \
  -Daarch64-evidence-out=/durable/path/zlay-aarch64-hash-evidence.json \
  -Daarch64-provenance=/durable/path/runner-provenance.json \
  -Daarch64-runner-record=/durable/path/runner-record.json 2>&1 \
  | tee /durable/path/zlay-aarch64-hash-certification.log
```

Certification v1 is Debug-only and requires Zig's native target query. Before
any certification artifact compiles, certification generates a cache-managed
`zlay.aarch64-runner-preflight.v1` from the exact runner-record bytes and
provenance. It binds the canonical provenance digest and the runner-record URI,
SHA-256, and byte count under its own canonical `preflight_sha256`. Every
certification artifact compile depends on that immutable run binding. Final
capture consumes only the preflight, not the two mutable original paths. The
raw record binds `runner_provenance`, `runner_provenance_sha256`,
`runner_record`, `runner_preflight_sha256`, and
`execution.gates.runner_record_preflight="passed"` from it.

The other internal fresh pre-gate step snapshots every certification input. It
refuses to proceed unless live `build.zig` matches the SHA-256 embedded when the
Zig build runner was compiled. The snapshot recursively includes every
`src/**/*.zig` production and native-test source in addition to the pinned
build, oracle, schema, checker, and contract-test inputs. Every certification
artifact compile also depends on that snapshot, and final capture requires the current input file
list, byte counts, and SHA-256 values to equal it exactly. The raw record binds
the canonical snapshot digest as
`execution.source.pre_gate_snapshot_sha256` and records
`execution.gates.pre_gate_source_snapshot="passed"`.

A PATH-independent Zig host guard then runs before the pinned-header, manifest,
native-test, and exact C/Zig gates. The raw record stores the freshly emitted
guard trace, including its final newline, and its digest. Its shape is:

```text
native-host sysname=<sysname> release=<release> machine=<aarch64|arm64> word_bits=64
```

The fresh native and ordinary-manifest Zig test processes have their exact
stderr bytes captured as certification inputs. Final capture accepts only
canonical UTF-8, newline-terminated, contiguously numbered successful Zig logs
whose summaries match their records and contain at least one passing test. The
native suite may skip only
`hash.test.textWithConfig matches pinned x86_64 default C oracle vectors`; the
ordinary-manifest suite may skip nothing. Raw `execution.test_runs` embeds both
complete logs with their pass/skip counts, exact skip names, byte counts, and
SHA-256 digests, and raw validation re-parses the embedded bytes instead of
trusting the recorded metadata.

Certification-only executions are marked side-effecting, and
`aarch64-hash-build-contract-audit` mutation-tests the Debug/native guards,
required three options, runner-preflight and source-snapshot creation,
dependency from every certification artifact compile to both, final
preflight-only capture input and live-source equality, build-embedded/live
`build.zig` binding, guard/header ordering, fresh-run flags, command-line
bindings, test-log capture and exact final-writer bindings, complete final
dependency set, and sole-writer boundary. Only the final capture step writes. It
refuses overwrite and paths beneath Zig cache/output or system temporary
directories, atomically creates the raw file, and fsyncs both the file and its
parent directory. The pretty-printed JSON bytes are bounded by the same 16 MiB
limit used by raw reload/validation, so an accepted pair of bounded test logs
cannot create an artifact that the validator is unable to reopen.

A successful completed log contains all three exact run bindings. The runner
preflight marker is:

```text
runner-provenance-valid preflight_sha256=<lowercase SHA-256> provenance_sha256=<lowercase SHA-256> runner_record_sha256=<lowercase SHA-256> runner_record_byte_count=<positive decimal> physical_machine_proof=false backlog_closed=false
```

The native-host marker is the exact line shown above. The exact final capture
marker line is:

```text
evidence-captured sha256=<SHA-256 of the exact raw file bytes> provenance_review=pending backlog_closed=false
```

Final capture emits each of the three markers as its own exact newline-
terminated line, followed by separate path metadata. The earlier cache-managed
preflight step may also print its marker with file/path metadata, but review
requires the raw record's exact standalone runner-preflight line. Keep the
complete log unchanged: review validates its digest and requires exact marker
lines, not substrings embedded in error or diagnostic text.

## 4. Validate and import the raw bytes

On any review host using the same source-contract inputs, validate the raw
record:

```sh
zig build aarch64-hash-evidence-validate \
  -Daarch64-evidence=/durable/path/zlay-aarch64-hash-evidence.json
```

For ZL-202 closure, validate and copy the source bytes exactly into the
repository without overwriting an existing record. This import is required for
closure, not an optional substitute for durable review artifacts:

```sh
zig build aarch64-hash-evidence-import \
  -Daarch64-evidence=/durable/path/zlay-aarch64-hash-evidence.json \
  -Daarch64-import-out=evidence/zl-202-aarch64-hash-evidence.json
```

Raw validation checks current-source binding, reconstructs and verifies the
bound runner preflight plus pre-gate source-snapshot digests and passed gates,
and checks Debug mode, exact native and manifest test logs, exact traces, captured native-host trace/digest,
executable/toolchain/target/runner facts, the pre-run provenance object, and
pending proof fields. It does not replay the execution, fetch the runner-record
URI, or prove the physical-machine claim.
Raw validation and import enforce `review.status=pending`,
`physical_hardware_machine_verified=false`, and `backlog_closed=false`.

## 5. Prepare the human review statement

After the raw record and completed log exist, the reviewer inspects the exact
runner record, raw evidence, and complete log. Create a separate
`/durable/path/review-statement.json` with this exact shape:

```json
{
  "schema": "zlay.aarch64-hash-review-statement.v1",
  "raw_evidence_uri": "file:///durable/path/zlay-aarch64-hash-evidence.json",
  "certification_log_uri": "file:///durable/path/zlay-aarch64-hash-certification.log",
  "reviewer": "<reviewer identity>",
  "reviewed_at_utc": "2020-07-14T13:00:00Z",
  "notes": "<non-empty review notes>",
  "attestations": {
    "runner_record_identifies_raw_runner": true,
    "hardware_model_matches_raw_claim": true,
    "certification_log_is_complete": true,
    "certification_log_matches_raw_execution": true,
    "physical_non_emulation_claim_reviewed": true
  }
}
```

Set every attestation to true only after the corresponding human review. The
review timestamp uses RFC3339 UTC seconds, must not precede the raw record's
`execution.generated_at_utc`, and cannot be more than five minutes ahead of the
validation host's clock. The raw-evidence, runner-record, and
certification-log URIs must be distinct absolute URIs with explicit schemes.
The tooling validates these fields but does not authenticate the reviewer.

## 6. Create and validate the receipt

First validate that the supplied runner-record bytes match the pre-run digest
embedded in the raw evidence:

```sh
zig build aarch64-hash-runner-record-validate \
  -Daarch64-evidence=/durable/path/zlay-aarch64-hash-evidence.json \
  -Daarch64-runner-record=/durable/path/runner-record.json
```

Create a new, non-overwriting receipt:

```sh
zig build aarch64-hash-review-receipt \
  -Daarch64-evidence=/durable/path/zlay-aarch64-hash-evidence.json \
  -Daarch64-runner-record=/durable/path/runner-record.json \
  -Daarch64-certification-log=/durable/path/zlay-aarch64-hash-certification.log \
  -Daarch64-review-statement=/durable/path/review-statement.json \
  -Daarch64-review-out=/durable/path/zlay-aarch64-hash-review-receipt.json
```

Then validate the receipt and every supplied local byte binding:

```sh
zig build aarch64-hash-review-validate \
  -Daarch64-evidence=/durable/path/zlay-aarch64-hash-evidence.json \
  -Daarch64-runner-record=/durable/path/runner-record.json \
  -Daarch64-certification-log=/durable/path/zlay-aarch64-hash-certification.log \
  -Daarch64-review-receipt=/durable/path/zlay-aarch64-hash-review-receipt.json
```

Receipt creation validates the raw contract; current raw and review source
digests; exact raw-file, runner-record, and log bytes; the raw execution and
provenance/preflight digests; the exact runner-preflight, native-host, and
capture markers in the completed log; and the human statement. It writes the
receipt atomically without overwrite and records these conservative proof
fields:

```text
artifact_kind=human-provenance-review-receipt
machine_validation=contract-digest-and-log-binding-only
physical_hardware_verified_by_machine=false
reviewer_identity_authenticated_by_machine=false
human_provenance_review_status=accepted
automatic_backlog_closure=false
backlog_closed=false
```

An accepted receipt is a durable record of human attestation, not machine proof
of physical hardware or authenticated reviewer identity. It deliberately does
not close `ZL-202`; maintainers must separately review the real artifact set and
record an explicit closure decision.

All JSON, review attachment, runner-record, and individual source-contract
inputs are bounded to 16 MiB; each certification/review source-contract set is
also capped at 64 MiB. Durable raw, import, and receipt outputs reject standard
temporary/runtime roots such as `/tmp`, `/var/tmp`, `/dev/shm`, and `/run/user`.
The cache-managed runner preflight and pre-gate source snapshot may be replaced
between invocations; within one certification DAG their generated bytes are
immutable inputs, and every certification compilation consumes those per-DAG
gates. The compiler still reads the live checkout rather than an immutable
staged source tree. Pre-gate and final equality therefore detect persistent
drift, but do not independently exclude an adversarial change-and-restore or
prove exact source-to-binary causality.
