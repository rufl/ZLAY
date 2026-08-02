# ZLAY consumer smoke

This directory is a tiny external-consumer fixture for the parent ZLAY release
and package gates. It proves that a downstream Zig application can import the
public module and consume renderer commands without reaching into `src/`.

Run it directly with Zig 0.16.x:

```sh
zig build run
```

The parent repository's `zig build check` and `zig build verify-all` are the
normative proof gates. This fixture has no independent product backlog or
release claims; its only purpose is downstream compatibility coverage.
