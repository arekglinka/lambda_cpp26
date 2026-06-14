"""Generate data/sample.parquet — a tiny 2-column Int64 fixture for testing."""

import os

import pyarrow as pa
import pyarrow.parquet as pq


def main():
    col_0 = pa.array([1, 2, 3, 4, 5], type=pa.int64())
    col_1 = pa.array([10, 10, 10, 10, 10], type=pa.int64())
    table = pa.table({"col_0": col_0, "col_1": col_1})
    os.makedirs("data", exist_ok=True)
    pq.write_table(table, "data/sample.parquet")
    print("Wrote data/sample.parquet: col_0 sum=15, col_1 sum=50")


if __name__ == "__main__":
    main()
