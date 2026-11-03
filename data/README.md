Put `all_stocks_5yr.csv` here (not committed).

Download: https://www.kaggle.com/datasets/camnugent/sandp500 (CC0 1.0).
Expected: 619,040 rows, 505 tickers, 2013-02-08 to 2018-02-07.

`data/backtest/` holds the generated backtest sample (strategies, trades, results).
It is not committed either; run `python etl/make_sample_backtest.py` to regenerate it.
See `data/backtest/README.md` for the rules and the result formulas.
