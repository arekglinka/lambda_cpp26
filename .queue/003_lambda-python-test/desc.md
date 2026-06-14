# Task: lambda-python-test
Created: 2026-06-14 (revised — replaces "fully-static-executable" + "cleanroom-test")
Status: pending
Depends on: 002

## Intent
Prove the extension + Python handler work end-to-end in the ACTUAL Lambda
Python runtime: `FROM public.ecr.aws/lambda/python:3.12`, COPY the .so +
`handler.py` + a local parquet fixture, invoke the handler, verify the
output table is printed with correct summed values. This is the pipeline
acceptance gate.

## Context
- The "fully static executable" concern is GONE — a Python extension is a
  .so loaded by CPython; glibc/libpython come from the runtime image.
  The old bg_e5db6064 (static glibc DNS) research is fully mooted.
- The libstdc++ gotcha: build stage uses GCC 16 (new libstdc++); the
  Lambda Python 3.12 image may ship an older libstdc++. Mitigation:
  `-static-libstdc++` into the .so, OR COPY libstdc++.so.6 from the
  builder. Research bg_7afee6a9 determines the right approach.
- RIE (Runtime Interface Emulator) is bundled in the lambda/python base
  image — local testing via `podman run -p 9000:8080 ...` + curl.

## Scope IN
- New Containerfile stage `FROM public.ecr.aws/lambda/python:3.12 AS test`:
  - COPY the .so to the right import path (research bg_7afee6a9: likely
    `/var/task/` or `${LAMBDA_TASK_ROOT}`).
  - COPY `handler.py` + `data/sample.parquet`.
  - `pip install pyarrow` (or bundle it) — needed for parquet read.
  - Set `CMD [ "handler.lambda_handler" ]`.
- A `make test` target that builds the test stage and invokes via RIE:
  `curl -X POST localhost:9000/2015-03-31/functions/function/invocations`.
- Assert the response/printed output contains the correct column sums.
- Verify `ldd` on the .so inside the container shows only libpython +
  glibc (no missing shared libs, no GLIBCXX version errors).

## Scope OUT
- S3 read/write (task 005).
- Size optimization (task 004).
- Provisioned concurrency / cold-start tuning.

## Acceptance
- `podman build --target test` exits 0.
- `podman run` + curl invocation returns the summed table with correct values.
- `ldd` in-container on the .so resolves all libs (no "not found").
- `python3.12 -c "import sum_columns; print(dir(sum_columns))"` works
  in-container.
