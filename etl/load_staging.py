"""
Load the Kaggle S&P 500 dataset (all_stocks_5yr.csv, CC0) into a
PostgreSQL staging table.

    pip install pandas psycopg2-binary
    python load_staging_minimal.py all_stocks_5yr.csv
"""
import io
import sys

import pandas as pd
import psycopg2

# Database connection: change these to match your Docker Postgres.
DB = dict(host="localhost", port=5433, dbname="trading_dw",
          user="dw_admin", password="dw_password")

CREATE_TABLE = """
CREATE SCHEMA IF NOT EXISTS staging;
CREATE TABLE IF NOT EXISTS staging.stg_market_ohlcv (
    ticker       VARCHAR(32)   NOT NULL,
    trade_date   DATE          NOT NULL,
    open_price   NUMERIC(18,6),
    high_price   NUMERIC(18,6),
    low_price    NUMERIC(18,6),
    close_price  NUMERIC(18,6) NOT NULL,
    volume       BIGINT,
    PRIMARY KEY (ticker, trade_date)
);
"""
COLUMNS = ["ticker", "trade_date", "open_price", "high_price",
           "low_price", "close_price", "volume"]

# 1. Extract: read the CSV and rename columns to the staging names.
df = pd.read_csv(sys.argv[1])
df = df.rename(columns={"Name": "ticker", "date": "trade_date", "open": "open_price",
                        "high": "high_price", "low": "low_price", "close": "close_price"})

# 2. Transform: convert types, then drop rows that the table would refuse.
df["trade_date"] = pd.to_datetime(df["trade_date"], errors="coerce").dt.date
for col in ["open_price", "high_price", "low_price", "close_price", "volume"]:
    df[col] = pd.to_numeric(df[col], errors="coerce")
rows_read = len(df)
df = df.dropna(subset=["ticker", "trade_date", "close_price"])
df = df.drop_duplicates(subset=["ticker", "trade_date"])
df["volume"] = df["volume"].round().astype("Int64")

# 3. Load: create the table, empty it, and bulk-copy the rows in.
buf = io.StringIO()
df[COLUMNS].to_csv(buf, index=False, header=False)
buf.seek(0)

conn = psycopg2.connect(**DB)
with conn, conn.cursor() as cur:
    cur.execute(CREATE_TABLE)
    cur.execute("TRUNCATE staging.stg_market_ohlcv")
    cur.copy_expert(f"COPY staging.stg_market_ohlcv ({', '.join(COLUMNS)}) "
                    "FROM STDIN WITH (FORMAT csv)", buf)
conn.close()

print(f"Read {rows_read:,} rows, loaded {len(df):,}, skipped {rows_read - len(df):,}.")
