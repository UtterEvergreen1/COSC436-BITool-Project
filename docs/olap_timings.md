Measured on PostgreSQL 16.15 (Debian 16.15-1.pgdg13+2) on x86_64-pc-linux-gnu; FactMarketData 619,040 rows, FactTrades 36,205, FactPositions 766,129. Median Execution Time of 7 runs after one warm-up run (EXPLAIN ANALYZE).

| Query | Operation | Before (ms) | After (ms) | Speed-up | Scans before | Scans after |
|---|---|---:|---:|---:|---|---|
| q1_rollup | Roll-up | 77.69 | 82.75 | 0.9x | Seq Scan facttrades; Seq Scan dimdate; Seq Scan dimstrategy | Seq Scan facttrades; Seq Scan dimdate; Seq Scan dimstrategy |
| q1_rollup_mv | Roll-up (materialized view) |  | 0.8 | 97.1x vs untuned q1_rollup |  | Seq Scan mv_monthly_pnl |
| q2_drilldown | Drill-down | 9.12 | 1.86 | 4.9x | Seq Scan dimstrategy; Seq Scan facttrades; Seq Scan dimdate | Seq Scan dimstrategy; Seq Scan dimdate; Index Scan ix_ft_exit_date |
| q3_slice | Slice | 2.59 | 1.2 | 2.2x | Seq Scan diminstrument; Index Scan factmarketdata_instrumentkey_datekey_key | Bitmap Heap Scan factmarketdata; Bitmap Index Scan ix_fmd_date; Seq Scan diminstrument |
| q4_dice | Dice | 88.84 | 89.53 | 1.0x | Seq Scan factmarketdata; Seq Scan dimdate; Seq Scan diminstrument | Seq Scan factmarketdata; Seq Scan dimdate; Seq Scan diminstrument |
| q5_pivot | Pivot | 45.13 | 54.37 | 0.8x | Seq Scan facttrades; Seq Scan dimdate; Seq Scan dimstrategy | Seq Scan facttrades; Seq Scan dimdate; Seq Scan dimstrategy |
| q6_exposure | Slice (dashboard query) | 112.76 | 115.34 | 1.0x | Seq Scan factpositions; Seq Scan dimdate; Seq Scan dimstrategy | Seq Scan factpositions; Seq Scan dimdate; Seq Scan dimstrategy |
