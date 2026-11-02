"""
Load the Kaggle S&P 500 dataset (all_stocks_5yr.csv, CC0) into the staging
table staging.stg_market_ohlcv.

    python etl/load_staging.py data/all_stocks_5yr.csv

Rows that cannot be loaded (missing ticker, date or close; non-numeric values;
duplicate ticker/date) are written to etl.etl_reject with the reason, and the
run is recorded in etl.etl_run_log. Known source problems such as blank opens
or high < low are NOT rejected: they are loaded as-is and reported by the
validation checks (etl/validate.py).

Database settings come from the environment / .env (see etl/db.py).
run_etl.py imports the extract/transform/load functions from this file.
"""
import io
import json
import sys
from pathlib import Path

import pandas as pd

from db import StepLog, connect, ensure_etl_schema, new_run_id

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
NUMERIC = ["open_price", "high_price", "low_price", "close_price", "volume"]


# 1. Extract: read every value as text so validation sees exactly what the file had.
def extract(path):
    raw = pd.read_csv(path, dtype=str, keep_default_na=False)
    raw = raw.rename(columns={"Name": "ticker", "date": "trade_date", "open": "open_price",
                              "high": "high_price", "low": "low_price", "close": "close_price"})
    missing = [c for c in COLUMNS if c not in raw.columns]
    if missing:
        raise ValueError(f"{path} is missing columns: {missing}")
    raw = raw[COLUMNS]
    raw.insert(0, "source_line", raw.index + 2)      # line 1 is the header
    return raw


# 2. Transform: convert types; split into rows to load and rows to reject.
def transform(raw):
    df = raw.copy()
    df["ticker"] = df["ticker"].str.strip()
    blank = {c: df[c].str.strip() == "" for c in COLUMNS}

    df["trade_date"] = pd.to_datetime(df["trade_date"], format="%Y-%m-%d", errors="coerce").dt.date
    for c in NUMERIC:
        df[c] = pd.to_numeric(df[c], errors="coerce")

    # The first problem found is the reason recorded for a row.
    reason = pd.Series("", index=df.index)
    rules = [(blank["ticker"], "missing ticker"),
             (blank["trade_date"], "missing trade_date"),
             (df["trade_date"].isna(), "invalid trade_date"),
             (blank["close_price"], "missing close_price")]
    rules += [(~blank[c] & df[c].isna(), f"non-numeric {c}") for c in NUMERIC]
    for mask, text in rules:
        reason = reason.mask(mask & (reason == ""), text)

    ok = reason == ""
    dup = df[ok].duplicated(subset=["ticker", "trade_date"], keep="first")
    reason[dup[dup].index] = "duplicate ticker/trade_date"
    ok = reason == ""

    clean = df[ok].copy()
    clean["volume"] = clean["volume"].round().astype("Int64")
    rejects = raw[~ok].copy()
    rejects["reason"] = reason[~ok]
    return clean, rejects


def _copy(cur, df, table, columns):
    buf = io.StringIO()
    df[columns].to_csv(buf, index=False, header=False)
    buf.seek(0)
    cur.copy_expert(f"COPY {table} ({', '.join(columns)}) FROM STDIN WITH (FORMAT csv)", buf)
    return cur.rowcount


# 3. Load: replace the staging rows and record the rejects. Runs in the caller's
#    transaction; the caller commits.
def load(conn, clean, rejects, run_id, source):
    with conn.cursor() as cur:
        cur.execute(CREATE_TABLE)
        cur.execute("TRUNCATE staging.stg_market_ohlcv")
        loaded = _copy(cur, clean, "staging.stg_market_ohlcv", COLUMNS)
        if len(rejects):
            rj = pd.DataFrame({
                "run_id": run_id,
                "source": source,
                "source_line": rejects["source_line"],
                "raw_row": [json.dumps(r) for r in rejects[COLUMNS].to_dict("records")],
                "reason": rejects["reason"]})
            _copy(cur, rj, "etl.etl_reject", list(rj.columns))
    return loaded


def run(conn, csv_path, run_id, step_no=1):
    """Extract, transform and load one CSV, logged as one step. Returns the counts."""
    log = StepLog(conn, run_id, step_no, "load_staging")
    rows_read = loaded = rejected = None
    try:
        raw = extract(csv_path)
        rows_read = len(raw)
        clean, rejects = transform(raw)
        rejected = len(rejects)
        loaded = load(conn, clean, rejects, run_id, Path(csv_path).name)
        conn.commit()
    except Exception as e:
        log.failed(str(e), rows_read, None, rejected)
        raise
    log.success(rows_read, loaded, rejected,
                f"{Path(csv_path).name} -> staging.stg_market_ohlcv")
    return rows_read, loaded, rejected


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: python etl/load_staging.py data/all_stocks_5yr.csv")
    conn = connect()
    try:
        ensure_etl_schema(conn)
        run_id = new_run_id(conn)
        rows_read, loaded, rejected = run(conn, sys.argv[1], run_id)
    finally:
        conn.close()
    print(f"Read {rows_read:,} rows, loaded {loaded:,}, skipped {rejected:,}.")
    if rejected:
        print(f"Skipped rows and reasons: SELECT * FROM etl.etl_reject WHERE run_id = {run_id};")


if __name__ == "__main__":
    main()
