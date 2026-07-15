#!/usr/bin/env python3
"""Batch entrypoint for the standalone MicroVM image (Containerfile.microvm).

That image has no Lambda Runtime API to poll, so this runs the handler once:
reads the bundled parquet, computes option prices, writes /tmp, prints JSON.
Override the container command for a REPL or custom code.
"""
import json
import os
import sys

sys.path.insert(0, "/opt/lambda_cpp26")

from handler import lambda_handler  # noqa: E402

os.environ.setdefault("PRICES_PATH", "/opt/lambda_cpp26/data/stock_prices.parquet")
os.environ.setdefault("OUTPUT_PATH", "/tmp/option_prices.parquet")

if __name__ == "__main__":
    print(json.dumps(lambda_handler({}, None), indent=2, default=float))
