"""
Shared helpers for the ETL scripts: database settings, connecting, running
SQL files and writing to the etl.etl_run_log table.

Database settings are read, in order of priority, from:
  1. environment variables (POSTGRES_HOST, POSTGRES_PORT, POSTGRES_DB,
     POSTGRES_USER, POSTGRES_PASSWORD)
  2. the repo's .env file (the same file docker compose uses)
  3. the defaults below, which match .env.example
So a normal checkout needs no extra setup: copy .env.example to .env once.
"""
import os
from pathlib import Path

import psycopg2

ETL_DIR = Path(__file__).resolve().parent
ROOT = ETL_DIR.parent
SQL_DIR = ROOT / "sql"
ETL_SCHEMA_SQL = ETL_DIR / "etl_schema.sql"

DEFAULTS = {
    "POSTGRES_HOST": "localhost",
    "POSTGRES_PORT": "5433",
    "POSTGRES_DB": "trading_dw",
    "POSTGRES_USER": "dw_admin",
    "POSTGRES_PASSWORD": "dw_password",
}


def _read_env_file(path):
    values = {}
    if path.exists():
        for line in path.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, value = line.split("=", 1)
                values[key.strip()] = value.strip().strip("'\"")
    return values


def db_settings():
    env_file = _read_env_file(ROOT / ".env")

    def get(key):
        return os.environ.get(key) or env_file.get(key) or DEFAULTS[key]

    return {
        "host": get("POSTGRES_HOST"),
        "port": int(get("POSTGRES_PORT")),
        "dbname": get("POSTGRES_DB"),
        "user": get("POSTGRES_USER"),
        "password": get("POSTGRES_PASSWORD"),
    }


def connect():
    s = db_settings()
    try:
        return psycopg2.connect(**s)
    except psycopg2.OperationalError as e:
        raise SystemExit(
            f"Could not connect to Postgres at {s['host']}:{s['port']} "
            f"(database {s['dbname']}, user {s['user']}).\n"
            "Is Docker running? 'docker compose ps' should show dw-postgres as healthy.\n"
            f"Details: {e}")


def run_sql_file(cur, path):
    """Run a whole .sql file (several statements) in the current transaction."""
    cur.execute(Path(path).read_text(encoding="utf-8"))


def ensure_etl_schema(conn):
    with conn.cursor() as cur:
        run_sql_file(cur, ETL_SCHEMA_SQL)
    conn.commit()


def new_run_id(conn):
    with conn.cursor() as cur:
        cur.execute("SELECT nextval('etl.run_id_seq')")
        run_id = cur.fetchone()[0]
    conn.commit()
    return run_id


class StepLog:
    """One row in etl.etl_run_log. The RUNNING row is committed straight away,
    so even a crash leaves a trace of which step was running."""

    def __init__(self, conn, run_id, step_no, step):
        self.conn = conn
        with conn.cursor() as cur:
            cur.execute(
                "INSERT INTO etl.etl_run_log (run_id, step_no, step) "
                "VALUES (%s, %s, %s) RETURNING log_id", (run_id, step_no, step))
            self.log_id = cur.fetchone()[0]
        conn.commit()

    def finish(self, status, rows_read=None, rows_loaded=None, rows_rejected=None,
               message=None):
        with self.conn.cursor() as cur:
            cur.execute(
                "UPDATE etl.etl_run_log SET finished_at = now(), status = %s, "
                "rows_read = %s, rows_loaded = %s, rows_rejected = %s, message = %s "
                "WHERE log_id = %s",
                (status, rows_read, rows_loaded, rows_rejected, message, self.log_id))
        self.conn.commit()

    def success(self, rows_read=None, rows_loaded=None, rows_rejected=None, message=None):
        self.finish("SUCCESS", rows_read, rows_loaded, rows_rejected, message)

    def failed(self, message, rows_read=None, rows_loaded=None, rows_rejected=None):
        self.conn.rollback()          # undo the step's partial work first
        self.finish("FAILED", rows_read, rows_loaded, rows_rejected, message)
