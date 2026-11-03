Measured on PostgreSQL 16.15 (Debian 16.15-1.pgdg13+2) on x86_64-pc-linux-gnu; FactMarketData 619,040 rows, FactTrades 36,205, FactPositions 766,129. Median Execution Time of 7 runs after one warm-up run (EXPLAIN ANALYZE).

| Query | Operation | Before (ms) | After (ms) | Speed-up | Scans before | Scans after |
|---|---|---:|---:|---:|---|---|
| q1_rollup | Roll-up | 25.39 | 25.34 | 1.0x | Seq Scan facttrades; Seq Scan dimdate; Seq Scan dimstrategy | Seq Scan facttrades; Seq Scan dimdate; Seq Scan dimstrategy |
| q1_rollup_mv | Roll-up (materialized view) |  | 0.24 | 105.8x vs untuned q1_rollup |  | Seq Scan mv_monthly_pnl |
| q2_drilldown | Drill-down | 2.83 | 0.58 | 4.9x | Seq Scan dimstrategy; Seq Scan facttrades; Seq Scan dimdate | Seq Scan dimstrategy; Seq Scan dimdate; Index Scan ix_ft_exit_date |
| q3_slice | Slice | 0.66 | 0.46 | 1.4x | Seq Scan diminstrument; Index Scan factmarketdata_instrumentkey_datekey_key | Bitmap Heap Scan factmarketdata; Bitmap Index Scan ix_fmd_date; Seq Scan diminstrument |
| q4_dice | Dice | 20.82 | 20.68 | 1.0x | Seq Scan factmarketdata; Seq Scan dimdate; Seq Scan diminstrument | Seq Scan factmarketdata; Seq Scan dimdate; Seq Scan diminstrument |
| q5_pivot | Pivot | 15.39 | 15.26 | 1.0x | Seq Scan facttrades; Seq Scan dimdate; Seq Scan dimstrategy | Seq Scan facttrades; Seq Scan dimdate; Seq Scan dimstrategy |
| q6_exposure | Slice (dashboard query) | 25.73 | 25.32 | 1.0x | Seq Scan factpositions; Seq Scan dimdate; Seq Scan dimstrategy | Seq Scan factpositions; Seq Scan dimdate; Seq Scan dimstrategy |
