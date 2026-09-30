# Upgrading Python

One-time cost: full CI rebuild (~1h45m cold). Everything else is one token.

## Touch-points (exactly two files carry the version)
1. `Containerfile.base` — `ARG PYTHON_VERSION=<x.y>` (drives toolchain + all stages + dev image)
2. `Containerfile` — `ARG PYTHON_VERSION=<x.y>` (deploy test stage)

Everything else is version-agnostic: `pip3`/`python3` symlinks in the Lambda base,
`/var/lang/bin/python3` in devcontainer.json, `sys.version_info` floor in tests.

## Sequence
1. `make check-wheels PY=<x.y>` — MUST be all-PASS before anything else
2. Confirm the base exists: `podman manifest inspect public.ecr.aws/lambda/python:<x.y>`
3. Bump both ARG values; update the floor in tests/test_environment.py
4. Commit + push to main (devcontainer.yml auto-fires: 4 stages rebuild, verify job validates)
5. `gh workflow run ci.yml` — validates the deploy pipeline (cleanroom imports)
6. Update the wheel table in scripts/check-wheels.sh if pins moved

## Hash note
A PYTHON_VERSION change legitimately changes ALL stage hashes (the base image changes).
Expect: toolchain ~35m, python-stack ~10m, conan-deps ~40m, agents ~5m, dev+verify ~20m.
