# Plan: lambda-python-test
Updated: 2026-06-14
Research: bg_7afee6a9 (Lambda Python ext deployment — DEFINITIVE)

## Approach
4-stage Containerfile culminating in a test stage `FROM
public.ecr.aws/lambda/python:3.12` that COPYs the .so + handler.py + a
local parquet fixture, installs PyArrow, and invokes the handler via the
bundled RIE. Asserts the output table has correct summed values. This is
the pipeline acceptance gate. The "fully static executable" + "glibc DNS"
concerns from the old plan are entirely gone — the .so is loaded by
CPython, glibc/libpython come from the base image.

## Containerfile stage structure (from research bg_7afee6a9 §6)
1. **builder** — `FROM public.ecr.aws/lambda/python:3.12`, GCC16 from source,
   Conan builds Arrow+QuantLib+CMake builds the .so (task 002).
2. **py-builder** — `FROM public.ecr.aws/lambda/python:3.12`,
   `pip3.12 install --target /install pyarrow` (+ boto3 for stretch task 005).
3. **test** — `FROM public.ecr.aws/lambda/python:3.12`:
   - COPY --from=py-builder /install ${LAMBDA_TASK_ROOT}
   - COPY --from=builder .../sum_columns*.so ${LAMBDA_TASK_ROOT}/
   - COPY handler.py data/sample.parquet ${LAMBDA_TASK_ROOT}/
   - RUN: import smoke + parquet load + ext call + assert sums.
4. **final** (deployable) — same as test but CMD ["handler.lambda_handler"],
   no test RUNs.

## Steps
- [ ] Add the py-builder stage (trivial — pip install pyarrow to /install).
- [ ] Add the test stage:
      ```dockerfile
      FROM public.ecr.aws/lambda/python:3.12 AS test
      COPY --from=py-builder /install ${LAMBDA_TASK_ROOT}/
      COPY --from=builder /src/build/Release/sum_columns*.so ${LAMBDA_TASK_ROOT}/
      COPY handler.py ${LAMBDA_TASK_ROOT}/
      COPY data/sample.parquet ${LAMBDA_TASK_ROOT}/data/
      RUN python3.12 -c "import sum_columns; print('import OK')"
      RUN python3.12 -c "import pyarrow.parquet as pq; \
          t=pq.read_table('${LAMBDA_TASK_ROOT}/data/sample.parquet'); \
          import sum_columns; r=sum_columns.sum_columns(t); print(r); \
          assert r.column(0)[0].as_py()==<EXPECTED_0>; \
          assert r.column(1)[0].as_py()==<EXPECTED_1>; print('TEST PASS')"
      ```
      (Expected values set by the sample.parquet fixture from task 001.)
- [ ] `ldd` audit inside the test stage:
      `RUN ldd ${LAMBDA_TASK_ROOT}/sum_columns*.so` — must show ONLY
      libpython + glibc components (no libstdc++/libarrow/libssl).
- [ ] Add a runtime/RIE smoke for the full Lambda path:
      `RUN`-free final stage with `CMD ["handler.lambda_handler"]`;
      `make test` does `podman build --target test` + `podman run -d -p9000:8080`
      + `curl -X POST localhost:9000/2015-03-31/functions/function/invocations`
      + assert the response payload contains the summed table.
- [ ] Verify NO `dnf install` in the test/final stages — pure base image +
      copied artifacts (the "pure AL2023 + just the binary/.so" requirement).
- [ ] Refactor Makefile: `build` (builder stage) → `test` (test stage +
      RIE invoke) → `ci` (build+test) → `clean`.

## Notes
- `LAMBDA_TASK_ROOT=/var/task` is set by the base image; `LD_LIBRARY_PATH`
  includes `/var/task:/var/task/lib` — the .so is importable from /var/task.
- RIE is bundled in the lambda/python base image — `podman run -p 9000:8080`
  exposes it; no separate RIE install needed.
- If `GLIBCXX_3.4.xx not found` appears at runtime → task 002's
  `-static-libstdc++` didn't take effect; re-audit the link line.
- PyArrow adds ~30-40MB to the image; total image ~100-150MB (well under
  the 10GB container limit).
- `--provenance=false` needed if pushing via `docker buildx` to ECR.
