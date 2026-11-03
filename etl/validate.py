"""
Validation checks from docs/schema_contract.md ("For John").

Each check computes an ACTUAL number and compares it with an EXPECTED number
(a constant, or another query). Every result is stored in etl.validation_result
with PASS / FAIL / ERROR, so the history of every run is kept.

Run on its own (after a load):   python etl/validate.py
run_etl.py runs it as its last step.
"""
import sys

from db import StepLog, connect, ensure_etl_schema, new_run_id

# Expected problems in the real Kaggle file (contract check 2). They are
# reported, never deleted, so these counts should stay exactly the same.
KNOWN_HIGH_BELOW_LOW = 1      # AOS 2014-05-19
KNOWN_NULL_OPENS = 11
KNOWN_NULL_HIGHS = 8
KNOWN_NULL_LOWS = 8

STG = "staging.stg_market_ohlcv"

# Trading days each trade holds a non-flat position: entry day up to (not
# including) the exit day, netting longs (+) and shorts (-). Only days on which the
# instrument has a price bar count: a position cannot be valued without a price
# (35 tickers have a few gaps), so 03_load_dw.sql leaves those days out.
_HELD_DAYS = """
    SELECT t.StrategyKey, t.TraderKey, t.InstrumentKey, d.DateKey
    FROM dw.FactTrades t
    JOIN dw.DimDate d ON d.DateKey >= t.EntryDateKey AND d.DateKey < t.ExitDateKey
                     AND d.IsTradingDay
    JOIN dw.FactMarketData m ON m.InstrumentKey = t.InstrumentKey AND m.DateKey = d.DateKey
    GROUP BY 1, 2, 3, 4
    HAVING SUM(CASE WHEN t.Side = 'BUY' THEN t.Quantity ELSE -t.Quantity END) <> 0
"""

CHECKS = [
    {"id": "1", "name": "Staging market rows = FactMarketData rows",
     "expected": f"SELECT COUNT(*) FROM {STG}",
     "actual": "SELECT COUNT(*) FROM dw.FactMarketData"},

    {"id": "2a", "name": "Source rows with high < low (known: AOS 2014-05-19)",
     "expected": KNOWN_HIGH_BELOW_LOW,
     "actual": f"SELECT COUNT(*) FROM {STG} WHERE high_price < low_price",
     "details": f"SELECT string_agg(ticker || ' ' || trade_date, ', ' ORDER BY ticker, trade_date) "
                f"FROM {STG} WHERE high_price < low_price"},

    {"id": "2b", "name": "Source rows with null open",
     "expected": KNOWN_NULL_OPENS,
     "actual": f"SELECT COUNT(*) FROM {STG} WHERE open_price IS NULL"},

    {"id": "2c", "name": "Source rows with null high",
     "expected": KNOWN_NULL_HIGHS,
     "actual": f"SELECT COUNT(*) FROM {STG} WHERE high_price IS NULL"},

    {"id": "2d", "name": "Source rows with null low",
     "expected": KNOWN_NULL_LOWS,
     "actual": f"SELECT COUNT(*) FROM {STG} WHERE low_price IS NULL"},

    {"id": "3", "name": "Trades whose entry or exit price differs from that day's Close",
     "expected": 0,
     "actual": """
        SELECT COUNT(*) FROM dw.FactTrades t
        LEFT JOIN dw.FactMarketData me ON me.InstrumentKey = t.InstrumentKey AND me.DateKey = t.EntryDateKey
        LEFT JOIN dw.FactMarketData mx ON mx.InstrumentKey = t.InstrumentKey AND mx.DateKey = t.ExitDateKey
        WHERE me.Close IS DISTINCT FROM t.EntryPrice OR mx.Close IS DISTINCT FROM t.ExitPrice""",
     "context": "SELECT COUNT(*) || ' trades checked' FROM dw.FactTrades"},

    {"id": "4", "name": "Trades entered or exited on a non-trading day",
     "expected": 0,
     "actual": """
        SELECT COUNT(*) FROM dw.FactTrades t
        JOIN dw.DimDate de ON de.DateKey = t.EntryDateKey
        JOIN dw.DimDate dx ON dx.DateKey = t.ExitDateKey
        WHERE NOT de.IsTradingDay OR NOT dx.IsTradingDay""",
     "context": "SELECT COUNT(*) || ' trades checked' FROM dw.FactTrades"},

    {"id": "5", "name": "FactPositions rows = held days recomputed from FactTrades",
     "expected": f"SELECT COUNT(*) FROM ({_HELD_DAYS}) h",
     "actual": "SELECT COUNT(*) FROM dw.FactPositions"},

    {"id": "6", "name": "Duplicate (ticker, date) pairs in staging",
     "expected": 0,
     "actual": f"SELECT COUNT(*) FROM (SELECT 1 FROM {STG} "
               f"GROUP BY ticker, trade_date HAVING COUNT(*) > 1) d"},
]


def _value(cur, sql_or_number):
    if isinstance(sql_or_number, (int, float)):
        return sql_or_number
    cur.execute(sql_or_number)
    return cur.fetchone()[0]


def run_checks(conn, run_id):
    """Run every check, store the results, and return them as a list of dicts."""
    results = []
    with conn.cursor() as cur:
        for chk in CHECKS:
            cur.execute("SAVEPOINT chk")      # one failing query must not stop the others
            try:
                expected = _value(cur, chk["expected"])
                actual = _value(cur, chk["actual"])
                details = None
                if chk.get("details") and actual:
                    details = _value(cur, chk["details"])
                elif chk.get("context"):
                    details = _value(cur, chk["context"])
                status = "PASS" if actual == expected else "FAIL"
                cur.execute("RELEASE SAVEPOINT chk")
            except Exception as e:
                cur.execute("ROLLBACK TO SAVEPOINT chk")
                expected = actual = None
                status, details = "ERROR", str(e).strip().splitlines()[0]
            cur.execute(
                "INSERT INTO etl.validation_result "
                "(run_id, check_id, check_name, expected, actual, status, details) "
                "VALUES (%s, %s, %s, %s, %s, %s, %s)",
                (run_id, chk["id"], chk["name"], expected, actual, status, details))
            results.append({"id": chk["id"], "name": chk["name"], "expected": expected,
                            "actual": actual, "status": status, "details": details})
    conn.commit()
    return results


def print_results(results):
    for r in results:
        exp = "-" if r["expected"] is None else f"{r['expected']:,}"
        act = "-" if r["actual"] is None else f"{r['actual']:,}"
        print(f"  [{r['status']:5}] {r['id']:>2}  {r['name']}  (expected {exp}, actual {act})")
        if r["details"] and (r["status"] != "PASS" or r["id"] == "2a"):
            print(f"           {r['details']}")


def run(conn, run_id, step_no):
    """Run the checks as one logged step. Returns True if every check passed."""
    log = StepLog(conn, run_id, step_no, "validate")
    try:
        results = run_checks(conn, run_id)
    except Exception as e:
        log.failed(str(e))
        raise
    bad = [r["id"] for r in results if r["status"] != "PASS"]
    message = (f"{len(results) - len(bad)} of {len(results)} checks passed"
               + (f"; not passed: {', '.join(bad)}" if bad else ""))
    if bad:
        log.finish("FAILED", message=message)
    else:
        log.success(message=message)
    print_results(results)
    print(f"  {message}")
    return not bad


def main():
    conn = connect()
    try:
        ensure_etl_schema(conn)
        ok = run(conn, new_run_id(conn), step_no=1)
    finally:
        conn.close()
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
