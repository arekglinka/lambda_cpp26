import sys
sys.path.insert(0, "/var/task")

import pyarrow.parquet as pq
import sum_columns

t = pq.read_table("/var/task/data/sample.parquet")
batch = t.to_batches()[0]
r = sum_columns.sum_columns(batch)
print("Column sums:", r)
assert float(r["col_0"]) == 15.0, f"col_0 mismatch: {r['col_0']}"
assert float(r["col_1"]) == 50.0, f"col_1 mismatch: {r['col_1']}"
print("CLEANROOM TEST PASS")
