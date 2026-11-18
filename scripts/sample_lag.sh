#!/bin/bash
# Usage: scripts/sample_lag.sh <output_csv> [interval_seconds]
OUT=${1:-evidence/b1/lag.csv}; INT=${2:-5}
echo "time,elapsed_s,current_offset,log_end_offset,lag" > "$OUT"
START=$(date +%s)
while true; do
  NOW=$(date +%s)
  docker compose -f docker/compose.yaml exec -T broker /opt/kafka/bin/kafka-consumer-groups.sh \
    --bootstrap-server localhost:9092 --describe --group featurizer_group 2>/dev/null \
  | awk -v t="$(date +%H:%M:%S)" -v e=$((NOW-START)) '$2=="ticks.raw"{print t","e","$4","$5","$6}' \
  | tee -a "$OUT"
  sleep "$INT"
done
