# Backtest sample data

`make_sample_backtest.py` writes `strategies.csv`, `trades.csv` and `results.csv` into this
folder from `data/all_stocks_5yr.csv` (Kaggle S&P 500 daily OHLCV). Run:

```
python etl/make_sample_backtest.py                     # 8 trades per strategy = 24 total
python etl/make_sample_backtest.py --max-trades 20     # smaller sample
```

## Rules (docs/schema_contract.md)

- Entry and exit happen at that day's **Close**; `entry_price`/`exit_price` equal the real Close.
- `side` is `BUY` (long) or `SELL` (short); `quantity > 0`.
- Every trade is closed by the last bar (2018-02-07); no open trades in `trades.csv`.
- Skip tickers with fewer bars than the longest lookback (50); they are printed on stderr.
- Fixed seed / fixed parameters, so a re-run gives the same files.
- No profit/loss or positions in the CSVs; the database computes both.

## Strategies

| Strategy | Logic | Parameters |
|---|---|---|
| SMA Crossover 20/50 | Long when the 20-day SMA crosses above the 50-day SMA; exit when it crosses back below | fast=20, slow=50, qty=100 |
| RSI 14 Mean Reversion | Long when RSI(14) < 30 and crosses back above; exit at RSI > 70 | rsi=14, oversold=30, overbought=70, qty=100 |
| 20-Day Breakout | Long when the close breaks above the highest close of the previous 20 days; exit 10 days later | channel=20, hold=10, qty=100 |

## results.csv formulas

Capital base: **$100,000** per strategy.

- **total_pnl** = Σ quantity × (exit_price − entry_price) × sign, where sign = +1 for BUY, −1 for SELL.
- **total_return** = total_pnl / capital.
- **max_drawdown** from equity = capital + cumulative realised P&L by exit date:
  (equity / equity.cummax() − 1).min(). Negative value.
- **sharpe** = mean(daily realised P&L / capital) / std(daily realised P&L / capital) × √252,
  risk-free rate 0. Daily P&L is spread over all trading days between the first entry and the
  last exit (zero on days with no exit).
- **win_rate** = fraction of trades with positive P&L.

The numbers here are test data, not performance.
