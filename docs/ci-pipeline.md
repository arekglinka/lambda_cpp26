# CI Pipeline — DevContainer Image Build

This doc captures the design, lessons, and operating procedures for the
`.github/workflows/devcontainer.yml` workflow. Required reading for anyone
modifying the workflow, the Containerfiles, or the per-library conanfiles.

For the high-level architecture diagram and Mermaid pipeline overview,
see [`architecture.md`](architecture.md) § "DevContainer Image Publishing".
This doc focuses on **why** the design is what it is, **how** to modify
it safely, and the **failure modes** that led to each decision.

---

## Pipeline overview

```
   gcc-base (cacheable, ~25 min cold)
        │
        ▼
   small-deps (cacheable, ~30 min cold)
        │
        ├──► arrow    (cacheable, ~25-30 min cold)  ──┐
        │                                              ├──► assemble-devcontainer
        └──► quantlib (cacheable, ~30 min cold)      ──┘     (always rebuilds, ~5 min)
              (PARALLEL with arrow)
```

| Scenario | Wall time |
|---|---|
| All cache hit | ~5 min (just assemble) |
| Dev-only tooling change (gdb, clangd version bump) | ~5 min (just assemble) |
| Single recipe change (e.g. arrow only) | ~35 min (arrow + assemble; rest cached) |
| Full cold cache | ~85 min total |

Each cacheable stage produces an OCI image on `ghcr.io/arekglinka/lambda_cpp26-*`,
tagged by content hash of its inputs (recipe files + profile + parent tag).
A cache hit at the start of a job skips the build entirely — pull before
build.

---

## Cache key design

| Image | Hash inputs |
|---|---|
| `gcc-base` | `Containerfile.gcc-base` |
| `small-deps` | `small-deps-conanfile.py` + `profiles/al2023` + gcc-base tag |
| `arrow` | `recipes/arrow/conanfile.py` + `recipes/arrow/conandata.yml` + `arrow-conanfile.py` + `profiles/al2023` + small-deps tag |
| `quantlib` | `recipes/quantlib/conanfile.py` + `recipes/quantlib/conandata.yml` + `quantlib-conanfile.py` + `profiles/al2023` + small-deps tag |

**Why include the parent tag in each child's hash?** Cascade rebuilds.
A gcc-base change must invalidate small-deps, which must invalidate arrow
and quantlib, which must invalidate assemble. Embedding the parent's tag
in the child's hash ensures a parent change produces a different child
hash → cache miss → rebuild. Without this, the child would cache-hit on
a stale parent.

**Why hash `*-conanfile.py` AND `recipes/*/conanfile.py` separately?**
The consumer conanfile (e.g. `arrow-conanfile.py`) determines the
consumer-side options applied to arrow's package_id. The arrow recipe
itself (`recipes/arrow/conanfile.py`) determines the source build.
Either can change independently — both must trigger an arrow rebuild.

---

## Per-library conanfiles (CRITICAL design element)

Three top-level consumer conanfiles exist alongside the project's main
`conanfile.py`:

| File | What it requires | Used by |
|---|---|---|
| `conanfile.py` | transitives + arrow + quantlib | Production build, full CI build (no longer used in workflow) |
| `small-deps-conanfile.py` | transitives only (boost, lz4, zstd, snappy, zlib, brotli, re2, utf8proc, rapidjson, thrift, openssl) | `Containerfile.small-deps` |
| `arrow-conanfile.py` | transitives + arrow with project options (`csv=False, json=False`) | `Containerfile.arrow` |
| `quantlib-conanfile.py` | transitives + quantlib | `Containerfile.quantlib` |

**Why these files exist**: Conan 2's CLI flag `--requires=arrow/18.0.0`
does **not** apply consumer-side options (csv/json overrides, boost
override=True). It produces a binary variant matching the recipe's
defaults (csv=True, json=True, boost/1.87.0). When the assemble stage
later tries to consume arrow with the project's options, the package_ids
don't match → cache miss → full rebuild, defeating the parallelism.

The per-library conanfiles are consumer-style files that mirror
`conanfile.py`'s requirements + options exactly, but each requires only
ONE of arrow/quantlib. This lets the parallel jobs build the SAME binary
variant the project would produce, just one library at a time.

**Maintenance**: when adding/changing an option in `conanfile.py`,
update the corresponding per-library conanfile to keep them in sync.
The drift will be caught at the assemble stage's `conan list` sanity
check (or at consume time when conan detects a missing package_id).

---

## Why small-deps as common ancestor

Both `Containerfile.arrow` and `Containerfile.quantlib` start
`FROM ghcr.io/.../lambda_cpp26-small-deps:<tag>`. This guarantees their
conan caches have **identical** transitive packages (same package_ids
because same source image, same profile, same options).

When the assemble stage does `cp -rn /tmp/arrow-conan/. /root/.conan2/`
followed by `cp -rn /tmp/ql-conan/. /root/.conan2/`, the second copy
is a no-op for the transitive portion (paths already exist, no-clobber).
Only the deltas (arrow's binary at one path, quantlib's at another) get
copied.

**The previous failed parallel design** (without small-deps as parent):
each parallel job built its OWN copy of boost, lz4, thrift, etc.
Slight differences in option resolution (e.g., arrow's recipe requires
`boost/1.87.0` but consumer overrides to 1.90.0; quantlib's recipe
requires boost without version pin) could produce DIFFERENT package_ids
for "the same" transitive. The merge was unsafe.

---

## BuildKit `--mount=type=bind` for cache merge

The assemble Dockerfile uses:

```dockerfile
# syntax=docker/dockerfile:1.6
RUN --mount=type=bind,from=arrow-cache,source=/root/.conan2,target=/tmp/arrow-conan \
    --mount=type=bind,from=quantlib-cache,source=/root/.conan2,target=/tmp/ql-conan \
    cp -rn /tmp/arrow-conan/. /root/.conan2/ && \
    cp -rn /tmp/ql-conan/.    /root/.conan2/
```

**Why this matters**: the naive alternative is two `COPY --from=arrow-cache`
+ `COPY --from=quantlib-cache` lines. Each COPY creates a new layer
containing the full source image's `/root/.conan2` (~3.8 GB each).
The intermediate layers bloat the final image by ~8 GB.

With `--mount=type=bind`, the source stages are mounted READ-ONLY during
the RUN command. The only new layer is the merged result (~4 GB for the
deltas — small-deps portion is already in the base layer, so cp -rn
skips it).

The `# syntax=docker/dockerfile:1.6` directive at the top of the
Dockerfile is REQUIRED to enable this BuildKit feature in podman.

---

## GH Actions runner disk space

Boost source extraction alone is ~5 GB (mostly HTML docs we don't read
but get extracted anyway). The default `ubuntu-latest` runner ships
~14 GB free. Cold `conan install` for the full graph needs ~10 GB.
Without intervention, the runner runs out of disk during boost source
extraction → `no space left on device` → build failure.

**Fix** (in workflow): clear preinstalled toolchains we don't use at the
start of each heavy job:

```yaml
- name: Free up runner disk space
  run: |
    sudo rm -rf /usr/share/dotnet                       \
                /usr/local/lib/android                  \
                /opt/ghc                                \
                /opt/hostedtoolcache/CodeQL             \
                /usr/local/.ghcup                       \
                /usr/local/share/boost                  \
                /opt/swift                              \
                /usr/local/julia*                       \
                /usr/lib/firefox                        \
                /opt/microsoft/powershell               \
                /usr/share/swift                        2>/dev/null || true
    sudo apt-get clean
    df -h /
```

This recovers ~6 GB. Well-known GH Actions pattern — ubuntu-latest image
is optimized for general use, not for C++ Conan builds. Same approach
used by V8, LLVM, and other large C++ projects on GH Actions.

---

## Timeout calibration

| Job | Local time | CI time | Timeout |
|---|---|---|---|
| gcc-base | ~25 min | ~25 min | 45 min |
| small-deps | ~20 min | ~30-35 min | 45 min |
| arrow | ~25 min | ~25-30 min | 45 min |
| quantlib | ~30 min | ~30 min | 45 min |
| assemble | ~3 min | ~5 min | 20 min |

**CI runners are ~1.5x slower than a local box** with the same nominal
core count, because of virtualization overhead and shared-tenant
contention. Always set timeouts ~1.5x local time + 25% margin.

---

## GHCR package ownership gotcha

A package on `ghcr.io/<owner>/<name>` is "owned" by whatever credential
created it first:
- **Created by `GITHUB_TOKEN` from a workflow** → the repo gets automatic
  write access for future workflow runs.
- **Created by a PAT via `podman push` from a local machine** → owned
  by the user account; the workflow's `GITHUB_TOKEN` will get HTTP 403
  on push.

If the workflow suddenly starts failing at `podman push` with HTTP 403
on a specific package (while other packages succeed), it's almost
certainly this. Fix options:

1. **Cleanest**: delete the package and let CI recreate it owned by
   `GITHUB_TOKEN`:
   ```bash
   gh api -X DELETE /user/packages/container/lambda_cpp26-<name>
   ```
2. **Preserve history**: in GitHub web UI → package settings →
   Manage Actions Access → Add Repository (`<owner>/<repo>`) →
   Role: Write.
3. **Rename in workflow**: change the image name to a fresh package
   (e.g. `lambda_cpp26-dev2`) — CI creates it owned by `GITHUB_TOKEN`.

The intermediate images (gcc-base, small-deps, arrow, quantlib) are all
created by the workflow's `GITHUB_TOKEN`, so they don't hit this issue.
Only `lambda_cpp26-dev` was historically created by local PAT pushes
and needed cleanup.

---

## Lessons learned (chronological)

These are the actual bugs that hit CI runs and what fixed them. Each
took a CI cycle (~30-90 min wall time) to discover. Documenting here
so future maintainers don't repeat the same paths.

### 1. `ENV CFLAGS` set before GCC bootstrap broke GCC's own compile

CI run: timed out / errored at GCC build step with
`error: unknown type name 'bool'` in `i386.h:1722`.

**Cause**: `ENV CFLAGS="-std=gnu11 -fgnu89-inline"` was placed BEFORE
the GCC build step. The bootstrap compiler (AL2023's system GCC 11)
picked up these flags when compiling GCC 16's own source. GCC 16's
`i386.h` uses `bool` without `#include <stdbool.h>`, expecting GNU C
mode. `-std=gnu11` disables the GNU extension that provides this as a
built-in → bootstrap fails 16 min into the build.

**Fix**: move `ENV CFLAGS` to AFTER the GCC build step, and use
`-std=gnu17` (matches the working `Containerfile.base` pattern). The
docs/session-timeline.md Q21 narrative about `-std=gnu11 -fgnu89-inline`
was aspirational/wrong — `Containerfile.base` used `-std=gnu17` all
along and it worked.

### 2. Conan 2 path-vs-reference auto-detection

CI run: arrow-deps failed at `conan install "arrow/18.0.0"` with
`ERROR: Conanfile not found at /tmp/arrow/18.0.0`.

**Cause**: Conan 2 preferentially treats `name/version` as a relative
path lookup before falling back to reference resolution. With cwd
`/tmp`, `arrow/18.0.0` is interpreted as `/tmp/arrow/18.0.0`.

**Fix**: install FROM a conanfile.py instead of by reference. The
per-library conanfiles (`arrow-conanfile.py`, `quantlib-conanfile.py`)
make this explicit and apply consumer options correctly.

### 3. Consumer-side options don't apply via CLI

CI run: assemble stage triggered a full rebuild of arrow even though
the arrow-deps image had arrow cached.

**Cause**: `conan install --requires=arrow/18.0.0` from CLI does not
apply consumer options (csv/json=False, boost override). The built
binary had csv=True, json=True (recipe defaults). When the project's
conanfile.py tried to consume it, package_ids didn't match → cache
miss → rebuild.

**Fix**: per-library conanfiles that mirror the project's
`conanfile.py` requirements + options, each requiring only ONE library.

### 4. Arrow recipe's `find` command matched thrift's tutorial

CI run: arrow cmake.configure() failed with
`include could not find requested file: BoostMacros`.

**Cause**: the arrow recipe's `build()` method used
`find /root/.conan2/p/b ... -path */cpp/CMakeLists.txt` to detect Conan
2.x's doubled-cpp nesting bug. This find searches ALL packages in the
conan cache. Thrift ships `tutorial/cpp/CMakeLists.txt` which sorts
before arrow's `cpp/cpp/CMakeLists.txt`. Conan builds thrift before
arrow, so by the time arrow's find runs, thrift's tutorial path matches
first. CMake then configures THRIFT's tutorial instead of arrow — that
tutorial's CMakeLists.txt has `include(BoostMacros)` at line 20, which
doesn't exist anywhere → error.

**Fix**: scope the source-folder detection to the recipe's own
`self.source_folder` only — never search the global conan cache.

### 5. Disk space exhaustion on runner

CI run: `no space left on device` during boost source extraction.

**Cause**: ubuntu-latest runners ship ~14 GB free; cold conan install
for arrow+boost+quantlib needs ~10 GB (boost source is ~5 GB of HTML
docs we don't read).

**Fix**: clear preinstalled toolchains we don't use at the start of
each heavy job (see "GH Actions runner disk space" above).

### 6. Per-job timeout calibration

CI runs: small-deps cancelled at 30 min, deps cancelled at 75 min.

**Cause**: my time estimates were based on local runs. CI runners are
~1.5x slower due to virtualization overhead and shared-tenant
contention.

**Fix**: bump every job's `timeout-minutes` to ~1.5x local time +
25% margin. Document the local vs CI delta in each job's comment so
future maintainers don't "optimize" the timeouts back down.

### 7. GHCR package ownership

CI run: assemble `podman push` failed with HTTP 403 on
`lambda_cpp26-dev` package.

**Cause**: the package was originally created by local `podman push`
using a PAT (during the snapshot workflow). It's "owned" by the user
account, not by the repo's workflow. `GITHUB_TOKEN` has no write access.

**Fix**: delete the package via `gh api -X DELETE` and let CI recreate
it owned by `GITHUB_TOKEN`. Intermediate images (gcc-base, small-deps,
arrow, quantlib) were all created by CI in the first run, so they never
hit this issue.

---

## How to add a new transitive dep

If you need to add a new conan dep (e.g. `bzip2/1.0.8`):

1. Add to `conanfile.py` (production consumer) — required
2. Add to `small-deps-conanfile.py` — required (so small-deps builds it)
3. Add to `arrow-conanfile.py` AND `quantlib-conanfile.py` — required
   (so they inherit cache compatibility with small-deps)

If you skip step 3, the arrow or quantlib job will rebuild that dep
locally (cache miss from small-deps), producing a different package_id
that may conflict at assemble time.

The four conanfiles MUST stay in sync for the transitives list. Arrow
and quantlib themselves appear only in their respective conanfiles
(arrow in arrow-conanfile.py + main conanfile.py; quantlib similarly).

---

## How to test changes locally before pushing

CI cycles are expensive (~30-90 min wall per run). Local testing
catches most issues in 5-10 min.

```bash
# 1. Validate Python syntax of all conanfiles
for f in conanfile.py small-deps-conanfile.py arrow-conanfile.py quantlib-conanfile.py; do
    python3 -c "import ast; ast.parse(open('$f').read())" && echo "  $f: OK"
done

# 2. Validate workflow YAML
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/devcontainer.yml'))"

# 3. Quick local build of small-deps (~20 min, exercises all conanfiles)
podman build -f Containerfile.small-deps \
    --build-arg REGISTRY_OWNER=arekglinka \
    --build-arg GCC_TAG=latest \
    -t localhost/lambda_cpp26-small-deps:test .

# 4. Arrow on top of small-deps (~25 min, exercises arrow-conanfile.py)
podman tag localhost/lambda_cpp26-small-deps:test ghcr.io/arekglinka/lambda_cpp26-small-deps:local
podman build -f Containerfile.arrow \
    --build-arg REGISTRY_OWNER=arekglinka \
    --build-arg SMALL_DEPS_TAG=local \
    -t localhost/lambda_cpp26-arrow:test .

# 5. Verify arrow built correctly
podman run --rm --entrypoint '[]' localhost/lambda_cpp26-arrow:test \
    conan list 'arrow/*' --cache
```

If steps 1-2 pass and step 3 produces an image with `conan list "*"`
showing all transitives, the CI run is highly likely to succeed. The
arrow build (step 4) is the next-most-likely failure point — if it
succeeds locally, CI will succeed (just slower).

---

## Conan 2 CLI gotchas (general)

These are Conan 2.x-specific quirks that bit us. Documented here for
future reference.

| What we tried | What works | Why |
|---|---|---|
| `conan install "arrow/18.0.0"` | `conan install <conanfile.py>` | Conan 2 preferentially treats `name/version` as relative path |
| `conan install --requires=arrow/18.0.0` | Per-library conanfile.py | CLI `--requires` skips consumer options |
| `conan list "arrow/*" --cached` | `conan list "arrow/*" --cache` | Long form is `--cache`, not `--cached` |
| `conan cache save -f out.tgz` | `conan cache save --file out.tgz` | `-f` is `--format`, not `--file` |
| `ENV CFLAGS="-std=gnu11 -fgnu89-inline"` before GCC build | `ENV CFLAGS="-std=gnu17"` AFTER GCC build | Bootstrap compiler chokes on C11 mode for GCC's own sources |

---

## References

- Workflow: [`.github/workflows/devcontainer.yml`](../.github/workflows/devcontainer.yml)
- Containerfiles: [`Containerfile.gcc-base`](../Containerfile.gcc-base),
  [`Containerfile.small-deps`](../Containerfile.small-deps),
  [`Containerfile.arrow`](../Containerfile.arrow),
  [`Containerfile.quantlib`](../Containerfile.quantlib),
  [`.devcontainer/Dockerfile`](../.devcontainer/Dockerfile)
- Consumer conanfiles: [`conanfile.py`](../conanfile.py),
  [`small-deps-conanfile.py`](../small-deps-conanfile.py),
  [`arrow-conanfile.py`](../arrow-conanfile.py),
  [`quantlib-conanfile.py`](../quantlib-conanfile.py)
- Architecture: [`architecture.md`](architecture.md) § "DevContainer Image Publishing"
- Snapshot workflow: [`devcontainer-snapshot.md`](devcontainer-snapshot.md)
- Past CI/Conan mistakes (pre-this-pipeline): [`session-timeline.md`](session-timeline.md)
