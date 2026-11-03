#!/usr/bin/env bash
# Set up the whole project: docker (warehouse + Metabase), the `dw` schema, the staging
# tables, the simulated backtest data, and finally the loaded warehouse.
#
# Usage: ./setup.sh
#
# This script does not modify any existing ETL/SQL script. It just runs them in the
# right order, with the right arguments.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

log() { printf '\n=== %s ===\n' "$*"; }

# 1. Set up the Python environment (venv + dependencies)
log "Setting up the Python environment"
if [ ! -d .venv ]; then
  python -m venv .venv
fi
# shellcheck disable=SC1091
source .venv/bin/activate
pip install -q -r requirements.txt

# 2. Bring the containers up (postgres + metabase)
log "Starting docker compose"
docker compose up -d

# 3. Create the `dw` schema (DimDate, DimInstrument, DimStrategy, DimTrader, Fact*)
log "Creating the warehouse schema"
docker compose exec warehouse psql -U dw_admin -d trading_dw \
  -v ON_ERROR_STOP=1 -f /sql/01_schema.sql

# 4. Load the real market data into staging
log "Loading staging market data"
python etl/load_staging.py data/all_stocks_5yr.csv

# 5. Generate the simulated backtest data
log "Generating backtest sample data"
python etl/make_sample_backtest.py

# 6. Create the empty backtest staging tables
log "Creating backtest staging tables"
docker compose exec warehouse psql -U dw_admin -d trading_dw \
  -v ON_ERROR_STOP=1 -f /sql/02_staging_backtest.sql

# 7. Load the backtest CSVs into staging and then into `dw`
log "Loading backtest data into the warehouse"
docker compose exec warehouse psql -U dw_admin -d trading_dw \
  -v ON_ERROR_STOP=1 -f /sql/03_load_dw.sql

# 8. Validate everything
log "Validating the load"
python etl/run_etl.py

echo ""
echo "Done. The dashboard is at http://localhost:3000"
