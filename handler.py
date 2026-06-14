import json
import os

import pyarrow as pa
import pyarrow.parquet as pq

import sum_columns as ext


def lambda_handler(event, context):
    prices_path = os.environ.get("PRICES_PATH", "/var/task/data/stock_prices.parquet")
    output_path = os.environ.get("OUTPUT_PATH", "/tmp/option_prices.parquet")

    table = pq.read_table(prices_path)
    batch = table.to_batches()[0]
    print(f"Loaded {table.num_rows} price records from {prices_path}")

    sums = ext.sum_columns(batch)
    print("Column sums:", json.dumps(sums))

    result = ext.price_options(batch, risk_free_rate=0.05, maturity_days=30)
    print("Option pricing:", json.dumps(result))

    results_table = pa.table({
        "spot":           [result["spot"]],
        "volatility":     [result["volatility"]],
        "risk_free_rate": [result["risk_free_rate"]],
        "maturity_days":  [result["maturity_days"]],
        "strike":         [result["strike"]],
        "call_price":     [result["call_price"]],
        "put_price":      [result["put_price"]],
        "call_delta":     [result["call_delta"]],
        "put_delta":      [result["put_delta"]],
        "gamma":          [result["gamma"]],
        "theta":          [result["theta"]],
        "vega":           [result["vega"]],
        "rho":            [result["rho"]],
    })
    pq.write_table(results_table, output_path)
    print(f"Wrote option pricing results to {output_path}")

    return {
        "statusCode": 200,
        "body": json.dumps({
            "rows_loaded": table.num_rows,
            "option_prices": result,
            "output_path": output_path,
        }),
    }
