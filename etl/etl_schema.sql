-- ETL bookkeeping tables.
--
-- These live in their own schema, "etl", so that sql/01_schema.sql (which drops
-- and recreates schema dw) never touches them: the run history survives every
-- warehouse rebuild. Safe to run any number of times.

CREATE SCHEMA IF NOT EXISTS etl;

-- One run_id per pipeline run; every log, reject and check row carries it.
CREATE SEQUENCE IF NOT EXISTS etl.run_id_seq;

-- One row per step of a run (schema, load_staging, copy_backtest, ...).
CREATE TABLE IF NOT EXISTS etl.etl_run_log (
    log_id        BIGSERIAL    PRIMARY KEY,
    run_id        INT          NOT NULL,
    step_no       SMALLINT     NOT NULL,
    step          VARCHAR(64)  NOT NULL,
    started_at    TIMESTAMPTZ  NOT NULL DEFAULT now(),
    finished_at   TIMESTAMPTZ,
    rows_read     BIGINT,
    rows_loaded   BIGINT,
    rows_rejected BIGINT,
    status        VARCHAR(16)  NOT NULL DEFAULT 'RUNNING'
                  CHECK (status IN ('RUNNING', 'SUCCESS', 'FAILED')),
    message       TEXT
);

-- Source rows that could not be loaded, with the reason. Nothing is dropped
-- without a row here.
CREATE TABLE IF NOT EXISTS etl.etl_reject (
    reject_id    BIGSERIAL    PRIMARY KEY,
    run_id       INT          NOT NULL,
    source       VARCHAR(128) NOT NULL,   -- file name, e.g. all_stocks_5yr.csv
    source_line  BIGINT,                  -- line in the file (header is line 1)
    raw_row      TEXT         NOT NULL,   -- the original values, as JSON
    reason       TEXT         NOT NULL,
    rejected_at  TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- One row per validation check per run (see docs/schema_contract.md).
CREATE TABLE IF NOT EXISTS etl.validation_result (
    result_id   BIGSERIAL    PRIMARY KEY,
    run_id      INT          NOT NULL,
    check_id    VARCHAR(8)   NOT NULL,    -- contract check number, e.g. '2b'
    check_name  VARCHAR(128) NOT NULL,
    expected    NUMERIC,
    actual      NUMERIC,
    status      VARCHAR(8)   NOT NULL CHECK (status IN ('PASS', 'FAIL', 'ERROR')),
    details     TEXT,
    checked_at  TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- Convenience views for Metabase and quick checks.
CREATE OR REPLACE VIEW etl.v_last_run AS
SELECT * FROM etl.etl_run_log
WHERE run_id = (SELECT MAX(run_id) FROM etl.etl_run_log)
ORDER BY step_no;

CREATE OR REPLACE VIEW etl.v_last_validation AS
SELECT * FROM etl.validation_result
WHERE run_id = (SELECT MAX(run_id) FROM etl.validation_result)
ORDER BY result_id;
