# SMAP Refinement Plan for ubturbo

Source repo: `/Users/ray/Documents/Repo/ubturbo`  
Reviewed areas: `src/smap`, `plugins/smap`, `plugins/rmrs/src/ubturbo_plugin/common/smap`, and related tests.

## Summary

`ubturbo` contains two SMAP layers:

- `src/smap`: UBTurbo-facing IPC/client/server bridge. It encodes SMAP requests, sends them through UBTurbo IPC, dynamically loads `libsmap.so`, and dispatches to SMAP APIs.
- `plugins/smap`: the actual SMAP package. It contains user-space management, kernel/tiering code, migration wrappers, config handling, unit tests, and design documentation.

SMAP is a multi-tier memory manager. It identifies hot and cold pages, migrates hot data toward local or fast memory, migrates cold data toward remote or slower memory, and adjusts per-process memory allocation. The existing design documentation already describes the major policy ideas: hot/cold sorting, adaptive migration parameters, multi-process scheduling, and hardware HIST sliding-window scanning.

## Current Architecture

At a high level:

1. Applications or higher-level components call the UBTurbo SMAP client API in `src/smap/client/smap_client.cpp`.
2. The client serializes requests through codec classes in `src/smap/smap_handler_msg.cpp`.
3. UBTurbo IPC forwards the request to server handlers in `src/smap/server/turbo_module_smap.cpp`.
4. The server loads `/usr/lib64/libsmap.so` with `dlopen`, resolves function pointers with `dlsym`, and invokes the real SMAP implementation.
5. The `plugins/smap` implementation handles process management, NUMA accounting, page hotness scanning, memory migration, and shared config state.

This separation is useful: UBTurbo owns service lifecycle and IPC, while `libsmap.so` owns the actual memory-tiering logic.

## Main Findings

### 1. IPC codec validation should be hardened

Several decode paths read a `len` field from an incoming IPC buffer, then use it in payload-size arithmetic before validating that the value is positive and within the expected maximum.

Example area:

- `src/smap/smap_handler_msg.cpp`
- `SmapAddProcessTrackingCodec::DecodeRequest`
- `SmapRemoveProcessTrackingCodec::DecodeRequest`
- `SmapEnableProcessMigrateCodec::DecodeRequest`

Risk:

- malformed IPC can provide negative or oversized lengths;
- signed `int` can be promoted into large `size_t` arithmetic;
- copies into fixed arrays depend on later `memcpy_s` protection rather than clear precondition checks.

Recommended refinement:

Add shared helpers:

```cpp
static bool IsCountInRange(int count, int max)
{
    return count > 0 && count <= max;
}

static bool CheckedAdd(size_t a, size_t b, size_t *out)
{
    if (SIZE_MAX - a < b) {
        return false;
    }
    *out = a + b;
    return true;
}

static bool CheckedMul(size_t a, size_t b, size_t *out)
{
    if (a != 0 && b > SIZE_MAX / a) {
        return false;
    }
    *out = a * b;
    return true;
}
```

Then validate `len` before computing `sizeof(pid_t) * len`, `sizeof(uint32_t) * len`, or similar payload sizes.

### 2. Codec implementation has heavy duplication

The codec file repeats the same patterns:

- allocate `TurboByteBuffer`;
- copy one or more fields;
- encode an `int` response;
- decode an `int` response;
- reset buffers on error.

This increases the chance of inconsistent behavior across APIs.

Recommended refinement:

Introduce small reusable helpers:

```cpp
int EncodePlain(TurboByteBuffer &buffer, const void *src, size_t size);
int DecodePlain(const TurboByteBuffer &buffer, void *dst, size_t size);
int EncodeIntResponse(TurboByteBuffer &buffer, int value);
int DecodeIntResponse(const TurboByteBuffer &buffer, int &value);
```

For compound requests, use a small append writer:

```cpp
class BufferWriter {
public:
    explicit BufferWriter(TurboByteBuffer &buffer, size_t size);
    int Append(const void *src, size_t size);
};
```

This makes future SMAP API additions easier and lowers bug density.

### 3. Client buffers should use RAII

The client code manually deletes `send.data` and `recv.data` in every function. Example area:

- `src/smap/client/smap_client.cpp`

Risk:

- future edits can leak memory on early returns;
- ownership is implicit;
- repeated cleanup code obscures the API logic.

Recommended refinement:

Add a tiny C++ guard:

```cpp
class ByteBufferGuard {
public:
    TurboByteBuffer buffer{};

    ~ByteBufferGuard()
    {
        delete[] buffer.data;
    }

    TurboByteBuffer *operator->()
    {
        return &buffer;
    }
};
```

Then client APIs can use:

```cpp
ByteBufferGuard send;
ByteBufferGuard recv;
```

This removes most manual `delete[]` calls in the client.

### 4. Hardcoded paths should become configuration

Current hardcoded paths:

- `/dev/shm/ubturbo_page_type.dat`
- `/usr/lib64/libsmap.so`
- `/dev/shm/smap_config`

Risk:

- brittle packaging;
- difficult container or test deployment;
- hard to run multiple instances;
- hard to point UBTurbo at a staged `libsmap.so`.

Recommended refinement:

Read these paths from `ubturbo.conf`, with current values as defaults:

```ini
smap.libsmap_path = /usr/lib64/libsmap.so
smap.page_type_path = /dev/shm/ubturbo_page_type.dat
smap.config_path = /dev/shm/smap_config
```

### 5. Dynamic symbol loading diagnostics should be explicit

`turbo_module_smap.cpp` resolves many SMAP symbols with `dlsym` and then checks an aggregate `flag`.

Risk:

- when deployment has an old or mismatched `libsmap.so`, logs do not immediately show exactly which symbol is missing.

Recommended refinement:

Use a symbol-loading table:

```cpp
struct SmapSymbol {
    const char *name;
    void **target;
};
```

Load each symbol in a loop and log the exact missing symbol name. This also reduces repeated `dlsym` boilerplate.

### 6. Build script has a path-check bug

In `plugins/smap/build.sh`, the bounds-check library test includes a trailing space inside the quoted variable:

```bash
if [[ ! -f "$LIB_BOUNDS_CHECK_FILE " ]]
```

This checks for `/usr/lib64/libboundscheck.so ` instead of `/usr/lib64/libboundscheck.so`.

Fix:

```bash
if [[ ! -f "$LIB_BOUNDS_CHECK_FILE" ]]
```

Also quote paths consistently:

```bash
rm -rf "$PROJ_DIR/build" "$PROJ_DIR/output"
mkdir -p "$BUILD_DIR"
```

### 7. Unit test script mutates source files

`test/run_ut.sh` removes `static` from production source files before building tests:

```bash
find ${dir} -type f -name "*.cpp" | xargs -i sed -i "s/\bstatic\b//g" {}
```

Risk:

- running tests dirties production files;
- tests can unintentionally change runtime behavior;
- changes can be accidentally committed;
- the script is not portable across macOS/Linux `sed` behavior.

Recommended refinement:

Do not rewrite source files in-place. Prefer one of:

- compile test-only copies under `test/build/generated`;
- expose narrow test hooks behind `#ifdef UNIT_TEST`;
- move private helpers into small internal translation units with test-visible headers;
- use linker wrapping or mocks where feasible.

### 8. NUMA probing should avoid shell commands

`plugins/smap/src/user/smap_interface.c` uses:

```c
popen("numastat -cvm", "r")
```

Risk:

- slower than direct system APIs;
- depends on command availability and output format;
- harder to secure and test;
- vulnerable to environment differences.

Recommended refinement:

Use one of:

- `/sys/devices/system/node/nodeN`;
- libnuma APIs;
- topology cached during SMAP initialization;
- kernel-provided node masks already visible to the module.

## Algorithm-Level Refinements

### Add migration hysteresis

Hot/cold migration decisions should avoid oscillation. Add separate promote and demote thresholds:

- promote remote page if hotness >= `hot_threshold`;
- demote local page if hotness <= `cold_threshold`;
- require `hot_threshold > cold_threshold`.

This reduces ping-pong migration between local and remote memory.

### Add migration ROI scoring

Not every hot/cold mismatch is worth migrating. Add a score such as:

```text
benefit = expected_latency_saving * expected_future_accesses
cost = migration_bytes / migration_bandwidth + CPU_overhead
score = benefit - cost
```

Only migrate when `score > 0` and budget allows it.

### Add per-process migration budgets

Each process should have configurable limits:

- max pages per migration cycle;
- max migration bytes per second;
- max CPU time spent scanning;
- max concurrent migration tasks.

This prevents SMAP from protecting one workload while harming neighbors.

### Add anti-thrashing detection

Track page or region migration history. If the same page/region migrates repeatedly in a short window:

- temporarily pin it;
- reduce its migration priority;
- increase hysteresis for that region;
- mark it as unstable.

### Add runtime observability

Expose:

- scan period;
- migration period;
- pages scanned;
- pages promoted;
- pages demoted;
- failed migrations;
- migration bytes;
- remote hit rate;
- local hot-page hit rate;
- per-process budget usage.

Useful outputs:

- debugfs;
- UBTurbo query API;
- structured logs;
- optional JSON stats.

### Add dry-run mode

Dry-run mode should compute candidate migrations but not execute them. It helps tune policies safely:

```text
smap.run_mode = dry_run
```

Report:

- selected local cold pages;
- selected remote hot pages;
- expected migration volume;
- expected benefit score;
- budget limits that clipped migration.

## Testing Recommendations

### IPC and ABI tests

Add malformed IPC tests for:

- negative `len`;
- zero `len`;
- `len > MAX_NR_TRACKING`;
- truncated payload;
- null `buffer.data`;
- payload length overflow;
- invalid response length.

Add ABI compatibility tests for public structs in `smap_interface.h`:

- `sizeof`;
- `alignof`;
- `offsetof`;
- expected enum values.

This matters because `src/smap` and `libsmap.so` communicate through binary structs.

### Dynamic loading tests

Add tests for:

- missing `libsmap.so`;
- missing individual symbols;
- old library version;
- symbol resolved but function returns error;
- unload/reload lifecycle.

### Policy simulation tests

Build tests that feed synthetic histograms into the migration policy:

- all-local hot;
- all-remote hot;
- steady hot set;
- shifting hot set;
- noisy access pattern;
- mixed heavy/light workloads.

Expected output should be deterministic migration candidates and budgets.

### Build/test hygiene tests

Add CI checks that:

- `test/run_ut.sh` does not modify tracked files;
- build scripts are shellcheck-clean where practical;
- generated files stay under build/output directories;
- scripts quote paths.

## Suggested Implementation Order

1. Fix `plugins/smap/build.sh` path check and quoting.
2. Stop `test/run_ut.sh` from mutating source files.
3. Add codec length/range validation helpers.
4. Add RAII buffer guards in `src/smap/client`.
5. Refactor repeated codec response helpers.
6. Make SMAP paths configurable.
7. Improve `dlsym` diagnostics with a symbol table.
8. Add malformed IPC and ABI tests.
9. Replace `numastat` shell probing with sysfs/libnuma/cached topology.
10. Add runtime observability and dry-run mode.
11. Add migration hysteresis, ROI scoring, and anti-thrashing.

## First Patch Candidate

A low-risk first patch can include:

- fix `"$LIB_BOUNDS_CHECK_FILE "` typo;
- add `IsCountInRange`;
- validate IPC lengths before payload-size arithmetic;
- add negative and oversized length unit tests;
- add a simple `ByteBufferGuard` for client cleanup.

This improves safety without changing SMAP policy behavior.

