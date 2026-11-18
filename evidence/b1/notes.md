# B1 Falling Behind – evidence notes (owner: Iris)

Machine: MacBook Pro (Apple Silicon), macOS, Docker Desktop, Python 3.12 venv
Branch: b1-throughput

## Baseline smoke test (2026-11-18 ~13:28)
- docker compose up: broker / mlflow / scorer healthy
- replay -> Kafka -> featurizer produced feature rows; model trained
- POST /score -> {"score":1.0,"spike":true}

## Run 1 – documented rate, concurrent (2026-11-18 13:39)
- Clean state: docker compose down -v; rm data/processed/features.parquet; up -d
- Terminals: A featurizer.py | B scripts/sample_lag.sh lag_baseline_run1.csv 5 | C time replay.py --file data/challenges/b1_long_ticks.jsonl --rate 500
- Replay: 15,640 msgs in 39.1s real -> actual arrival ~400 msg/s (not 500; per-message sleep + produce overhead). LOG-END-OFFSET slope between samples ≈410 msg/s (39.1s includes startup).
- LAG bounded and oscillating (max 1,703 at t=31s, 106 at t=37s); reached 0 within one sample (~6s) after LOG-END-OFFSET hit 15,640
- elapsed_s counts from sampler start, not replay start; actual interval ≈6s (5s sleep + docker exec time); 98s→110s gap likely from a Ctrl+C press during sampling (rows after t=55 are post-drain, all LAG=0)
- CURRENT-OFFSET advances in steps (offsets stored, published by auto-commit ~5s), so 5s sampling shows a sawtooth
- File: lag_baseline_run1.csv

## Run 2 – pre-filled topic, then featurizer (2026-11-18 13:47)
- Clean state; replay --rate 0 first; then featurizer; then sampler (2s)
- First sample already LAG=0 -> featurizer drained the full backlog within a few seconds
- Confirmed clean run: features.parquet = 13,050 rows, mtime 13:47
- File: lag_drain_run1.csv (shows LAG 0 throughout; sampler started too late to capture drain)

## Max throughput (2026-11-18 ~14:17, clean state)
- time replay.py --rate 0: 15,640 msgs in 1.32s -> ~11,800 msg/s (Kafka write is not the bottleneck)
- time featurizer.py --max_messages 13000 (pre-filled topic): 5.70s real. 13,000 feature rows ≈ 15,400 raw msgs consumed (non-ticker msgs are filtered) -> ~2,700 raw msg/s incl. startup (conservative)
- Conclusion: documented arrival (~400/s) is ~1/7 of featurizer capacity on this machine -> no sustained backlog

## cProfile (featurizer, 13,000 rows; separate clean run ~14:18; see cprofile_baseline_top30.txt)
- run_featurizer total ~5.5s
- consumer.poll: 3.17s (~58%), 15,570 calls, one message per poll (also includes group-join wait at startup)
- _append_parquet: 1.75s (~32%), 520 calls; read_parquet 0.58s + to_parquet 0.98s (re-reads and rewrites the whole file every 25 rows)
- parse/compute/produce: small (not in top 30)

## Open questions / next
- Teammates run the documented rate (Test A) + max speeds (Test B) on their machines. If one shows growing LAG at rate 500, run the official before/after there (same machine for both).
- Otherwise calibrate one fixed rate > ~2.7k msg/s on this Mac and document it (limitation: each run only ~4–5s long, few lag samples).
- Asked instructor in checkpoint whether calibrating a higher rate is the intended approach.
- Test whether per-batch parquet cost grows with file size (per-batch timing).
- Start sampler BEFORE featurizer in drain runs (Run 2 sampler started too late).
