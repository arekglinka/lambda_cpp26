import sys
sys.path.insert(0, "/var/task")

import pyarrow as pa
import pyarrow.parquet as pq
import sum_columns as ext

# Test 1: column sums (basic Arrow C Data Interface)
table = pq.read_table("/var/task/data/sample.parquet")
batch = table.to_batches()[0]
sums = ext.sum_columns(batch)
print("Column sums:", sums)
assert float(sums["col_0"]) == 15.0, f"col_0: {sums['col_0']}"
assert float(sums["col_1"]) == 50.0, f"col_1: {sums['col_1']}"

# Test 2: QuantLib option pricing from historical stock data
prices_table = pq.read_table("/var/task/data/stock_prices.parquet")
prices_batch = prices_table.to_batches()[0]
print(f"Loaded {prices_table.num_rows} price rows")
result = ext.price_options(prices_batch, risk_free_rate=0.05, maturity_days=30)
print("Option pricing:", result)

assert result["spot"] > 0, "spot must be positive"
assert result["volatility"] > 0, "volatility must be positive"
assert result["call_price"] > 0, "call price must be positive"
assert result["put_price"] > 0, "put price must be positive"
assert abs(result["call_delta"] - 0.5) < 0.25, f"ATM call delta ~0.5, got {result['call_delta']}"
assert abs(result["put_delta"] + 0.5) < 0.25, f"ATM put delta ~-0.5, got {result['put_delta']}"
assert abs(result["call_delta"] - result["put_delta"] - 1.0) < 0.01, "put-call parity delta"

# Test 3: write results as parquet and verify
output_path = "/tmp/option_results.parquet"
results_table = pa.table({
    "spot":       [result["spot"]],
    "volatility": [result["volatility"]],
    "call_price": [result["call_price"]],
    "put_price":  [result["put_price"]],
    "call_delta": [result["call_delta"]],
    "put_delta":  [result["put_delta"]],
    "gamma":      [result["gamma"]],
    "theta":      [result["theta"]],
    "vega":       [result["vega"]],
    "rho":        [result["rho"]],
})
pq.write_table(results_table, output_path)

verify = pq.read_table(output_path)
assert verify.num_rows == 1
assert verify.num_columns == 10
print(f"Results parquet: {verify.num_rows} rows, {verify.num_columns} cols")
print("CLEANROOM TEST PASS")
