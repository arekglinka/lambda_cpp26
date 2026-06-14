"""AWS Lambda handler — load parquet, sum columns via C++ extension, return JSON."""

import json
import os

import pyarrow.parquet as pq

import sum_columns as ext


def lambda_handler(event, context):
    """Load a local parquet, sum columns via the C++ extension, print result."""
    data_path = os.environ.get("DATA_PATH", "/var/task/data/sample.parquet")
    table = pq.read_table(data_path)
    print(f"Loaded table with {table.num_rows} rows, {table.num_columns} columns")
    result = ext.sum_columns(table)
    print("Column sums:", json.dumps(result))
    return {"statusCode": 200, "body": json.dumps(result)}
