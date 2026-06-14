# Plan: s3-roundtrip-stretch
Updated: 2026-06-14
Research: bg_c31a410b (capsule boundary unchanged), bg_7afee6a9

## Approach
Extend the local-parquet milestone (task 003) to full S3 round-trip.
ALL S3 I/O stays on the Python side (PyArrow + boto3) — the C++ extension
is UNCHANGED (pure compute, no network). This is the user's long-term
vision: read parquet from S3 → C++ computes → write result parquet to S3.

## Why C++ stays untouched
The capsule boundary (task 001) means C++ only sees Arrow C structs.
Whether Python sourced those structs from a local file or from S3 is
invisible to C++. The extension cannot tell the difference. This proves
the pure-compute architecture decouples I/O from computation.

## Scope IN
- handler.py extended: accept an event with `input_s3_uri` + `output_s3_uri`:
  ```python
  def lambda_handler(event, context):
      in_uri  = event["input_s3_uri"]   # e.g. "s3://bucket/input.parquet"
      out_uri = event["output_s3_uri"]  # e.g. "s3://bucket/output.parquet"
      table = pq.read_table(in_uri)             # PyArrow reads from S3 (boto3 creds)
      result = ext.sum_columns(table)           # C++ computes (unchanged)
      out_table = pa.table(result)              # build result table in Python
      pq.write_table(out_table, out_uri)        # PyArrow writes to S3
      return {"statusCode": 200, "body": json.dumps({"wrote": out_uri})}
  ```
- requirements.txt: `pyarrow>=15.0`, `boto3` (PyArrow uses boto3 for S3).
- IAM: Lambda execution role needs `s3:GetObject` on input bucket +
  `s3:PutObject` on output bucket. Document in docs/s3-setup.md.
- Integration test: localstack (or minio) as an S3 stand-in:
  - docker-compose with localstack service.
  - test fixture: upload sample.parquet to localstack S3, invoke handler,
    assert output parquet appears + contains correct sums.
  - This is a NETWORKED test — separate from the cleanroom test (task 003).

## Scope OUT
- Arrow S3 in the C++ build (Python handles S3 — confirmed by design).
- Cross-account / KMS-encrypted bucket edge cases (document, don't solve).
- S3 Select / pushdown (PyArrow reads whole objects).

## Steps
- [ ] Add boto3 to the py-builder stage (task 003's py-builder).
- [ ] Extend handler.py with the S3 path (event-driven URIs).
- [ ] docker-compose.yml: localstack service + a test runner that uploads
      sample.parquet, invokes the handler (via RIE curl), asserts output.
- [ ] docs/s3-setup.md: IAM role policy snippet + bucket config.
- [ ] `.github/workflows/ci.yml` (task 004): add a separate `s3-test` job
      that runs the localstack integration (gated, doesn't block the
      cleanroom test).

## Notes
- PyArrow's S3 support uses boto3 for credentials/endpoint resolution;
  set `AWS_REGION` + `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` env vars
  (or rely on the Lambda execution role in production).
- For localstack: set `S3_ENDPOINT_URL=http://localstack:4566` and
  `AWS_ENDPOINT_URL` so PyArrow/boto3 target localstack not real AWS.
- The output parquet is written by Python (PyArrow) — C++ never produces
  parquet in this flow. If C++ must produce parquet directly (e.g. for a
  local /tmp workflow), the Arrow parquet module (linked in task 002)
  supports it via `parquet::arrow::FileWriter`.
- This task is STRETCH — complete tasks 001-004 first. The cleanroom test
  (task 003) with local parquet is the real milestone gate.
