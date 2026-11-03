@echo off
REM Set up the whole project on Windows: containers, the `dw` schema, the staging
REM tables, the simulated backtest data, and finally the loaded warehouse.
REM
REM Usage: setup_windows.bat
REM
REM This script does not modify any existing ETL/SQL script. It just runs them in the
REM right order, with the right arguments.

setlocal enabledelayedexpansion

REM 1. Set up the Python environment (venv + dependencies)
echo.
echo === Setting up the Python environment ===
if not exist .venv (
    python -m venv .venv
)
call .venv\Scripts\activate
pip install -q -r requirements.txt

REM 2. Bring the containers up (postgres + metabase)
echo.
echo === Starting docker compose ===
docker compose up -d

REM 3. Create the `dw` schema (DimDate, DimInstrument, DimStrategy, DimTrader, Fact*)
echo.
echo === Creating the warehouse schema ===
docker compose exec warehouse psql -U dw_admin -d trading_dw -v ON_ERROR_STOP=1 -f /sql/01_schema.sql

REM 4. Load the real market data into staging
echo.
echo === Loading staging market data ===
python etl/load_staging.py data/all_stocks_5yr.csv

REM 5. Generate the simulated backtest data
echo.
echo === Generating backtest sample data ===
python etl/make_sample_backtest.py

REM 6. Create the empty backtest staging tables
echo.
echo === Creating backtest staging tables ===
docker compose exec warehouse psql -U dw_admin -d trading_dw -v ON_ERROR_STOP=1 -f /sql/02_staging_backtest.sql

REM 7. Load the backtest CSVs into staging and then into `dw`
echo.
echo === Loading backtest data into the warehouse ===
docker compose exec warehouse psql -U dw_admin -d trading_dw -v ON_ERROR_STOP=1 -f /sql/03_load_dw.sql

REM 8. Validate everything
echo.
echo === Validating the load ===
python etl/run_etl.py

echo.
echo Done. The dashboard is at http://localhost:3000
