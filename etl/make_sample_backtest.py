"""
THROWAWAY TEST DATA: writes strategies.csv, trades.csv and results.csv in the
format of docs/schema_contract.md, so run_etl.py can be tested before the real
backtest exists. Replace with Dan's files when they are ready.

    python etl/make_sample_backtest.py                      # -> data/backtest/
    python etl/make_sample_backtest.py --out data/backtest_sample

Follows the contract rules: deterministic (same input -> same files), trades
enter and exit at that day's real Close, every trade is closed by the
symbol's last bar, side is BUY/SELL, quantity > 0, no profit/loss column,
at most one open trade per strategy per symbol, and symbols with fewer bars
than the longest lookback (50) are skipped.

results.csv formulas (simple, for testing only): capital base 100,000 per
strategy; total_return = total_pnl / capital; max_drawdown from equity =
capital + cumulative realised P&L by exit date; sharpe = mean / std of daily
realised P&L as a fraction of capital, x sqrt(252), risk-free rate 0.
"""
import argparse
from pathlib import Path

import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parent.parent
SYMBOLS = ["AAPL"]
LOOKBACK = 50
QUANTITY = 100
CAPITAL = 100_000

STRATEGIES = [
    {"strategy_name": "SMA Crossover 20/50", "strategy_type": "Trend following",
     "description": "Long when the 20-day SMA crosses above the 50-day SMA; exit when it crosses back below.",
     "parameters": "fast=20, slow=50, qty=100", "trader_name": "TrendBot", "trader_type": "System"},
    {"strategy_name": "RSI 14 Mean Reversion", "strategy_type": "Mean reversion",
     "description": "Long when RSI(14) falls below 30 and crosses back above; exit at RSI 70.",
     "parameters": "rsi=14, oversold=30, overbought=70, qty=100", "trader_name": "ReversionBot", "trader_type": "System"},
    {"strategy_name": "20-Day Breakout", "strategy_type": "Breakout",
     "description": "Long when the close breaks above the highest close of the previous 20 days; exit 10 days later.",
     "parameters": "channel=20, hold=10, qty=100", "trader_name": "BreakoutBot", "trader_type": "System"},
]


def sma_crossover(bars):
    fast = bars.close.rolling(20).mean()
    slow = bars.close.rolling(50).mean()
    above = (fast > slow) & slow.notna()
    trades, entry = [], None
    for i in range(1, len(bars)):
        if entry is None and above.iloc[i] and not above.iloc[i - 1]:
            entry = i
        elif entry is not None and not above.iloc[i]:
            trades.append(("BUY", entry, i)); entry = None
    if entry is not None:
        trades.append(("BUY", entry, len(bars) - 1))          # force-close on the last bar
    return trades


def rsi_mean_reversion(bars):
    """Long on RSI(14) < 30 crossing back above 30; exit at RSI > 70. One trade at a time."""
    delta = bars.close.diff()
    gain = delta.where(delta > 0, 0.0).rolling(14).mean()
    loss = (-delta.where(delta < 0, 0.0)).rolling(14).mean()
    rs = gain / loss
    rsi = 100 - (100 / (1 + rs))
    rsi = rsi.dropna()
    trades, entry = [], None
    for i in range(len(rsi)):
        if entry is None and rsi.iloc[i] < 30 and (i == 0 or rsi.iloc[i] > rsi.iloc[i - 1]):
            entry = i
        elif entry is not None and rsi.iloc[i] > 70:
            trades.append(("BUY", entry, i)); entry = None
    if entry is not None:
        trades.append(("BUY", entry, len(bars) - 1))          # force-close on the last bar
    return trades


def twenty_day_breakout(bars):
    """Long on a close above the highest close of the previous 20 days; exit 10 days later."""
    high20 = bars.close.shift(1).rolling(20).max()
    trades, i = [], 20
    while i < len(bars) - 1:
        if bars.close.iloc[i] > high20.iloc[i]:
            exit_i = min(i + 10, len(bars) - 1)
            trades.append(("BUY", i, exit_i))
            i = exit_i + 1                                       # one open trade at a time
        else:
            i += 1
    return trades


RULES = {"SMA Crossover 20/50": sma_crossover, "RSI 14 Mean Reversion": rsi_mean_reversion,
         "20-Day Breakout": twenty_day_breakout}


def results_for(name, t, trading_days):
    sign = np.where(t.side == "BUY", 1, -1)
    pnl = t.quantity * (t.exit_price - t.entry_price) * sign
    daily = pnl.groupby(t.exit_date).sum().reindex(trading_days, fill_value=0.0) / CAPITAL
    equity = CAPITAL + (daily * CAPITAL).cumsum()
    drawdown = (equity / equity.cummax() - 1).min()
    sharpe = daily.mean() / daily.std() * np.sqrt(252) if daily.std() > 0 else 0.0
    return {"strategy_name": name, "start_date": t.entry_date.min(), "end_date": t.exit_date.max(),
            "num_trades": len(t), "win_rate": round(float((pnl > 0).mean()), 4),
            "total_pnl": round(float(pnl.sum()), 6), "total_return": round(float(pnl.sum() / CAPITAL), 6),
            "max_drawdown": round(float(drawdown), 6), "sharpe": round(float(sharpe), 6)}


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--csv", type=Path, default=ROOT / "data" / "all_stocks_5yr.csv")
    p.add_argument("--out", type=Path, default=ROOT / "data" / "backtest")
    p.add_argument("--max-trades", type=int, default=8,
                   help="trades per strategy; 8 x 3 strategies = 24")
    args = p.parse_args()

    df = pd.read_csv(args.csv, usecols=["date", "close", "Name"])
    df = df.dropna(subset=["close"]).drop_duplicates(["Name", "date"]).sort_values(["Name", "date"])
    trading_days = sorted(df.date.unique())

    rows, skipped = [], []
    for sym in SYMBOLS:
        bars = df[df.Name == sym].reset_index(drop=True)
        if len(bars) < LOOKBACK:
            skipped.append(f"{sym} ({len(bars)} bars)")
            continue
        for s in STRATEGIES:
            for side, i, j in RULES[s["strategy_name"]](bars):
                if len([r for r in rows if r["strategy_name"] == s["strategy_name"]]) >= args.max_trades:
                    break
                rows.append({"strategy_name": s["strategy_name"], "symbol": sym, "side": side,
                             "entry_date": bars.date[i], "exit_date": bars.date[j], "quantity": QUANTITY,
                             "entry_price": bars.close[i], "exit_price": bars.close[j]})
    trades = pd.DataFrame(rows).sort_values(["strategy_name", "symbol", "entry_date"])
    results = pd.DataFrame([results_for(n, g, trading_days) for n, g in trades.groupby("strategy_name")])

    args.out.mkdir(parents=True, exist_ok=True)
    pd.DataFrame(STRATEGIES).to_csv(args.out / "strategies.csv", index=False)
    trades.to_csv(args.out / "trades.csv", index=False)
    results.to_csv(args.out / "results.csv", index=False)
    print(f"Wrote {len(STRATEGIES)} strategies, {len(trades):,} trades, {len(results)} results to {args.out}")
    if skipped:
        print("Skipped (fewer than", LOOKBACK, "bars or missing):", ", ".join(skipped))


if __name__ == "__main__":
    main()
