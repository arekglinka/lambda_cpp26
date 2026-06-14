# Task: s3-roundtrip-stretch
Created: 2026-06-14
Status: pending (STRETCH GOAL)
Depends on: 003

## Intent
The long-term vision: Python Lambda handler reads a Parquet file FROM S3
(via PyArrow/boto3), passes it to the C++ extension for computation, and
writes the result Parquet TO S3. This task extends the local-parquet
milestone (task 003) to full S3 round-trip — entirely on the Python side
(C++ stays pure compute).

## Context
- All S3 I/O is Python's job: `pyarrow.parquet.read_table("s3://...")`
  and `pyarrow.parquet.write_table(table, "s3://...")`. The C++ extension
  never touches the network.
- Needs AWS credentials in the Lambda execution role + boto3/botocore
  for S3 endpoint resolution (PyArrow uses boto3 under the hood for S3).
- Local testing via localstack or minio as an S3 stand-in.

## Scope IN
- Extend `handler.py` to accept an S3 URI in the Lambda event, read the
  parquet from S3, call the C++ ext, write result parquet to S3.
- localstack/minio integration test (networked — NOT the cleanroom test).
- IAM role / Lambda config notes in docs.

## Scope OUT
- Arrow S3 in the C++ build (Python handles S3 — no change to the .so).
- Cross-account / cross-region S3 edge cases.

## Acceptance
- Handler reads `s3://test-bucket/input.parquet`, processes, writes
  `s3://test-bucket/output.parquet`, returns success.
- localstack integration test passes in CI (separate from cleanroom test).
- C++ extension unchanged from task 003 (proves the pure-compute boundary).
