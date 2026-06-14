"""Download historical stock prices via yfinance and save as parquet fixture."""
import os

import pyarrow as pa
import pyarrow.parquet as pq

try:
    import yfinance as yf
except ImportError:
    raise SystemExit("pip install yfinance pyarrow")

def main():
    ticker = yf.Ticker("AAPL")
    hist = ticker.history(period="1y").reset_index()
    table = pa.table({
        "date": pa.array(hist["Date"].dt.strftime("%Y-%m-%d").tolist(), pa.string()),
        "close": pa.array(hist["Close"].values, pa.float64()),
        "volume": pa.array(hist["Volume"].values, pa.int64()),
    })
    os.makedirs("data", exist_ok=True)
    pq.write_table(table, "data/stock_prices.parquet")
    print(f"Wrote {table.num_rows} rows to data/stock_prices.parquet")
    print(f"Last close: {hist['Close'].iloc[-1]:.2f}")

if __name__ == "__main__":
    main()
