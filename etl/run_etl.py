"""
Run the whole warehouse load in the contract's order, logging every step to
etl.etl_run_log:

  1. schema_dw          sql/01_schema.sql            (drops and recreates schema dw)
  2. load_staging       etl/load_staging.py          (CSV -> staging.stg_market_ohlcv)
  3. staging_backtest   sql/02_staging_backtest.sql  (recreates staging.stg_bt_*)
  4. copy_backtest      strategies.csv, trades.csv, results.csv -> staging.stg_bt_*
  5. load_dw            sql/03_load_dw.sql           (staging -> dw)
  6. validate           etl/validate.py              (stored in etl.validation_result)

Usage (from the repo root, with Docker running):
    python etl/run_etl.py
    python etl/run_etl.py --csv data/all_stocks_5yr.csv --backtest-dir data/backtest

The pipeline stops at the first failed step; that step is logged as FAILED with
the error. Exit code: 0 if every step and check passed, 1 otherwise.
History:  SELECT * FROM etl.v_last_run;   SELECT * FROM etl.v_last_validation;
"""
import argparse
import csv
import io
import sys
from pathlib import Path

import load_staging
import validate
from db import ROOT, SQL_DIR, StepLog, connect, ensure_etl_schema, new_run_id, run_sql_file

BACKTEST_FILES = [  # (file, staging table, columns allowed by the contract)
    ("strategies.csv", "staging.stg_bt_strategies",
     ["strategy_name", "strategy_type", "description", "parameters", "trader_name", "trader_type"]),
    ("trades.csv", "staging.stg_bt_trades",
     ["strategy_name", "symbol", "side", "entry_date", "exit_date",
      "quantity", "entry_price", "exit_price"]),
    ("results.csv", "staging.stg_bt_results",
     ["strategy_name", "start_date", "end_date", "num_trades", "win_rate",
      "total_pnl", "total_return", "max_drawdown", "sharpe"]),
]


class StepFailed(Exception):
    pass


def sql_step(conn, run_id, step_no, name, sql_file, before=None):
    """Run one .sql file as a logged step. Returns the rows of its last SELECT, if any."""
    log = StepLog(conn, run_id, step_no, name)
    try:
        with conn.cursor() as cur:
            if before:
                cur.execute(before)
            run_sql_file(cur, sql_file)
            rows = cur.fetchall() if cur.description else []
        conn.commit()
    except Exception as e:
        log.failed(f"{sql_file.name}: {e}".strip())
        raise StepFailed(f"{sql_file.name} failed: {e}".strip()) from e
    log.success(message=sql_file.name)
    return rows


def copy_backtest(conn, run_id, step_no, backtest_dir):
    """COPY Dan's three CSVs into the staging tables created by 02."""
    log = StepLog(conn, run_id, step_no, "copy_backtest")
    total_read = total_loaded = 0
    parts = []
    try:
        for file_name, table, allowed in BACKTEST_FILES:
            path = backtest_dir / file_name
            if not path.exists():
                raise FileNotFoundError(f"missing {path}")
            text = path.read_text(encoding="utf-8-sig")          # tolerate an Excel BOM
            rows = list(csv.reader(io.StringIO(text)))
            header = [h.strip() for h in rows[0]] if rows else []
            unknown = [h for h in header if h not in allowed]
            if not header or unknown:
                raise ValueError(f"{file_name}: unexpected columns {unknown or '(empty file)'}; "
                                 f"the contract allows {allowed}")
            n_read = sum(1 for r in rows[1:] if any(v.strip() for v in r))
            with conn.cursor() as cur:
                cur.copy_expert(f"COPY {table} ({', '.join(header)}) "
                                "FROM STDIN WITH (FORMAT csv, HEADER true)", io.StringIO(text))
                n_loaded = cur.rowcount
            total_read += n_read
            total_loaded += n_loaded
            parts.append(f"{file_name}={n_loaded}")
        conn.commit()
    except Exception as e:
        log.failed(str(e).strip(), total_read, None, None)
        raise StepFailed(f"copy_backtest failed: {e}".strip()) from e
    log.success(total_read, total_loaded, total_read - total_loaded, ", ".join(parts))
    return parts


def main():
    p = argparse.ArgumentParser(description="Run the full ETL into the trading warehouse.")
    p.add_argument("--csv", type=Path, default=ROOT / "data" / "all_stocks_5yr.csv",
                   help="market data CSV (default: data/all_stocks_5yr.csv)")
    p.add_argument("--backtest-dir", type=Path, default=ROOT / "data" / "backtest",
                   help="folder with strategies.csv, trades.csv, results.csv (default: data/backtest)")
    args = p.parse_args()

    conn = connect()
    ensure_etl_schema(conn)
    run_id = new_run_id(conn)
    print(f"ETL run {run_id}")
    ok = False
    try:
        print("1/6 schema_dw ...")
        sql_step(conn, run_id, 1, "schema_dw", SQL_DIR / "01_schema.sql")

        print("2/6 load_staging ...")
        try:
            read, loaded, rejected = load_staging.run(conn, args.csv, run_id, step_no=2)
        except Exception as e:
            raise StepFailed(f"load_staging failed: {e}") from e
        print(f"    read {read:,}, loaded {loaded:,}, rejected {rejected:,}")

        print("3/6 staging_backtest ...")
        sql_step(conn, run_id, 3, "staging_backtest", SQL_DIR / "02_staging_backtest.sql")

        print("4/6 copy_backtest ...")
        print("    " + ", ".join(copy_backtest(conn, run_id, 4, args.backtest_dir)))

        print("5/6 load_dw ...")
        # 03 refers to dw tables without the "dw." prefix, so set the path first.
        counts = sql_step(conn, run_id, 5, "load_dw", SQL_DIR / "03_load_dw.sql",
                          before="SET search_path TO dw, public")
        for table, n in counts:
            print(f"    {table:<20} {n:>10,}")

        print("6/6 validate ...")
        ok = validate.run(conn, run_id, step_no=6)
    except StepFailed as e:
        print(f"\nSTOPPED: {e}")
    finally:
        conn.close()

    print(f"\nRun {run_id} {'PASSED' if ok else 'DID NOT PASS'}. "
          "Details: SELECT * FROM etl.v_last_run;  SELECT * FROM etl.v_last_validation;")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
