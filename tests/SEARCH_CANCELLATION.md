# Search cancellation tests

Run from the plugin directory with LuaJIT 2.1 on macOS or Linux:

```sh
luajit tests/test_async.lua .
```

The 10 tests use real OS processes and a headless UI scheduler. They cover UI responsiveness, cancellation, process-group termination, timeouts, errors, downloaded files, failed forks and repeated searches.

`upstream/trapper.lua` is KOReader v2026.07.2's `frontend/ui/trapper.lua`, copied as a test fixture. `upstream/subprocess.lua` contains the POSIX subprocess functions from koreader-base `ffi/util.lua` at commit `ab0d8e2a2cfbbd3b57f7975077b0b124eac8dcd2`, with minimal FFI declarations for macOS and Linux. These fixtures are used by tests only; the plugin uses KOReader's installed modules.

These tests do not check device rendering or live mirrors.
