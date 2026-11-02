# COSC436-BITool-Project

A Business Intelligence (BI) tool for data visualization on top of a designed and
implemented data warehouse for algorithmic-trading data.
COSC 436 (Data Warehousing), Okanagan College.

**Stack:** PostgreSQL 16 (warehouse) + Metabase (BI tool) in Docker; Python (pandas) for ETL.

## Status

- Market data (`FactMarketData`) is real: Kaggle S&P 500 daily OHLCV bars.
- Trades and positions (`FactTrades`, `FactPositions`) are **simulated**. They are currently
  generated randomly from real closing prices by `sql/dw_star_schema_postgres.sql`.
  Replacing this with a seeded backtest is in progress. Do not read strategy results as performance.
- Daily bars only, no ticks.

## Quick start (clean checkout to working dashboard)

**Requirements:** Docker Desktop, Python 3.10+, git.

1. **Clone and configure**
   ```
   git clone https://github.com/UtterEvergreen1/COSC436-BITool-Project.git
   cd COSC436-BITool-Project
   ```
   Copy `.env.example` to `.env` (`copy .env.example .env` on Windows, `cp .env.example .env` on macOS/Linux).

2. **Get the data.** Download `all_stocks_5yr.csv` from
   <https://www.kaggle.com/datasets/camnugent/sandp500> and put it in `data/`.

3. **Start the containers**
   ```
   docker compose up -d
   docker compose ps
   ```
   Wait until `dw-postgres` shows `healthy`.

4. **Install Python dependencies**
   ```
   python -m venv .venv
   .venv\Scripts\activate          # macOS/Linux: source .venv/bin/activate
   pip install -r requirements.txt
   ```

5. **Load the staging table**
   ```
   python etl/load_staging.py data/all_stocks_5yr.csv
   ```
   Expected output: `Read 619,040 rows, loaded 619,040, skipped 0.`

6. **Build the warehouse** (creates schema `dw`; safe to re-run, it drops and recreates `dw`)
   ```
   docker compose exec warehouse psql -U dw_admin -d trading_dw -f /sql/dw_star_schema_postgres.sql
   ```
   The last lines print table row counts and a staging-vs-fact row check.

7. **Open Metabase** at <http://localhost:3000> and finish the setup wizard.
   Add a PostgreSQL database with:

   | Field | Value |
   |---|---|
   | Host | `warehouse` |
   | Port | `5432` |
   | Database | `trading_dw` |
   | Username / password | `dw_admin` / `dw_password` |

   Host and port differ from the ones on your PC because Metabase reaches Postgres from inside Docker.

8. **Build the dashboard.** Create one SQL question per query in
   `metabase/sql_queries_dashboard_questions.sql`, then add them to a dashboard.
   After re-running step 6, use Admin > Databases > Sync database schema now.

## Connecting from your own tools (DBeaver, VS Code SQLTools, psql)

| Field | Value |
|---|---|
| Host | `localhost` |
| Port | `5433` (`POSTGRES_PORT` in `.env`) |
| Database | `trading_dw` |
| Username / password | `dw_admin` / `dw_password` |

## Reset everything

```
docker compose down -v
```
This deletes the warehouse and Metabase volumes (including saved dashboards).

## Repository layout

```
docker-compose.yml   Postgres + Metabase
.env.example         config template (copy to .env)
etl/                 load_staging.py: CSV -> staging.stg_market_ohlcv
sql/                 warehouse DDL and load (staging -> dw)
metabase/            dashboard queries and screenshots
docs/                diagrams and reports
data/                raw CSV goes here (not committed)
```

## Team

Caleb Carlson, Daniel Cuevas, Karisni Pillay, Daniel Losso-Kiss, John Cortez, Munkh-Och Zorigoo.
Market data: Cam Nugent, "S&P 500 stock data" (Kaggle, CC0 1.0).


Put `all_stocks_5yr.csv` here (not committed).

Download: https://www.kaggle.com/datasets/camnugent/sandp500 (CC0 1.0).
Expected: 619,040 rows, 505 tickers, 2013-02-08 to 2018-02-07.
