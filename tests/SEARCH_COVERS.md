# Cover tests

Run from the plugin directory with LuaJIT 2.1 on macOS or Linux:

```sh
luajit tests/test_cover_progress.lua .
```

The 27 tests cover HTML parsing, exact-file metadata, cache reuse, invalid and oversized responses, background loading, two-worker concurrency, per-cover timeouts, progress reporting, page changes and closing the menu. They use real OS processes, a fake HTTP transport and a headless UI scheduler.

`upstream/subprocess.lua` contains the POSIX subprocess functions from koreader-base `ffi/util.lua` at commit `ab0d8e2a2cfbbd3b57f7975077b0b124eac8dcd2`, with minimal FFI declarations for macOS and Linux. It is used by tests only; the plugin uses KOReader's installed module.

These tests do not check device rendering or live mirrors.
