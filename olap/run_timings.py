"""
Time the OLAP queries in sql/olap_queries.sql before and after tuning
(sql/04_indexes_aggregates.sql) and write a results table.

    python olap/run_timings.py            # from the repo root

Needs the warehouse loaded (01, 03 run) and psycopg2 (pip install -r requirements.txt).
It DROPS and re-creates the tuning (indexes + materialized view), so it is safe
to re-run. Connection settings come from PG* environment variables; defaults
match .env.example (localhost:5433, dw_admin / dw_password / trading_dw).

Method: each query is run once to warm the cache (discarded), then RUNS times
with EXPLAIN (ANALYZE, FORMAT JSON). Reported time = median Execution Time.
Output: docs/olap_timings.md and docs/olap_timings.csv
"""
import csv
import json
import os
import re
import statistics
import sys
from pathlib import Path

import psycopg2

RUNS = 7
ROOT = Path(__file__).resolve().parent.parent
SQL = ROOT / "sql"
OUT = ROOT / "docs"

for k, v in {"PGHOST": "localhost", "PGPORT": "5433", "PGUSER": "dw_admin",
             "PGPASSWORD": "dw_password", "PGDATABASE": "trading_dw"}.items():
    os.environ.setdefault(k, v)


def load_queries():
    text = (SQL / "olap_queries.sql").read_text()
    out = []
    for block in re.split(r"^-- name: ", text, flags=re.M)[1:]:
        header, _, body = block.partition("\n")
        qid, op, desc = [p.strip() for p in header.split("|", 2)]
        out.append((qid, op, desc, body.strip().rstrip(";")))
    return out


def run_file(cur, name):
    # strip psql meta-commands (\set ...) which are not SQL
    sql = "\n".join(l for l in (SQL / name).read_text().splitlines() if not l.lstrip().startswith("\\"))
    cur.execute(sql)


def scans(plan):
    found = []

    def walk(n):
        t = n.get("Node Type", "")
        if "Scan" in t:
            idx = n.get("Index Name")
            found.append(f"{t} {idx}" if idx else f"{t} {n.get('Relation Name', '')}".strip())
        for c in n.get("Plans", []):
            walk(c)
    walk(plan)
    return found


def measure(cur, sql):
    cur.execute(sql)  # warm-up, discarded
    cur.fetchall()
    times, plan = [], None
    for _ in range(RUNS):
        cur.execute("EXPLAIN (ANALYZE, FORMAT JSON) " + sql)
        res = cur.fetchone()[0]
        res = res if isinstance(res, list) else json.loads(res)
        times.append(res[0]["Execution Time"])
        plan = res[0]["Plan"]
    return statistics.median(times), scans(plan)


def phase(cur, tuned):
    run_file(cur, "04_indexes_aggregates.sql" if tuned else "04_drop_tuning.sql")
    cur.execute("ANALYZE")
    results = {}
    for qid, op, desc, sql in load_queries():
        if qid.endswith("_mv") and not tuned:
            continue
        results[qid] = measure(cur, sql)
        print(f"  {'after ' if tuned else 'before'} {qid}: {results[qid][0]:.1f} ms")
    return results


def main():
    conn = psycopg2.connect()
    conn.autocommit = True
    cur = conn.cursor()
    cur.execute("SET search_path TO dw, public")
    cur.execute("SELECT version()")
    version = cur.fetchone()[0].split(",")[0]
    counts = {}
    for t in ["FactMarketData", "FactTrades", "FactPositions"]:
        cur.execute(f"SELECT COUNT(*) FROM {t}")
        counts[t] = cur.fetchone()[0]
    if counts["FactTrades"] == 0:
        sys.exit("FactTrades is empty: load the backtest data (03_load_dw.sql) before timing.")

    print("Before tuning...")
    before = phase(cur, tuned=False)
    print("After tuning...")
    after = phase(cur, tuned=True)

    queries = load_queries()
    rows = []
    for qid, op, desc, _ in queries:
        b = before.get(qid)
        a = after.get(qid)
        rows.append({
            "query": qid, "operation": op, "description": desc,
            "before_ms": round(b[0], 2) if b else "",
            "after_ms": round(a[0], 2) if a else "",
            "before_plan": "; ".join(b[1]) if b else "",
            "after_plan": "; ".join(a[1]) if a else "",
        })

    OUT.mkdir(exist_ok=True)
    with open(OUT / "olap_timings.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0]))
        w.writeheader()
        w.writerows(rows)

    lines = [
        f"Measured on {version}; FactMarketData {counts['FactMarketData']:,} rows, "
        f"FactTrades {counts['FactTrades']:,}, FactPositions {counts['FactPositions']:,}. "
        f"Median Execution Time of {RUNS} runs after one warm-up run (EXPLAIN ANALYZE).",
        "",
        "| Query | Operation | Before (ms) | After (ms) | Speed-up | Scans before | Scans after |",
        "|---|---|---:|---:|---:|---|---|",
    ]
    for r in rows:
        if r["query"].endswith("_mv"):
            base = next(x for x in rows if x["query"] == r["query"][:-3])
            speed = f"{base['before_ms'] / r['after_ms']:.1f}x vs untuned {base['query']}" if r["after_ms"] else ""
        else:
            speed = f"{r['before_ms'] / r['after_ms']:.1f}x" if r["after_ms"] else ""
        lines.append(f"| {r['query']} | {r['operation']} | {r['before_ms']} | {r['after_ms']} | {speed} | "
                     f"{r['before_plan']} | {r['after_plan']} |")
    (OUT / "olap_timings.md").write_text("\n".join(lines) + "\n")
    print("\n".join(lines))
    print(f"\nWrote {OUT / 'olap_timings.md'} and olap_timings.csv")


if __name__ == "__main__":
    main()
