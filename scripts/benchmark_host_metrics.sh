#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="$ROOT_DIR/dist/benchmarks"
mkdir -p "$OUTPUT_DIR"

swiftc -O -swift-version 6 -parse-as-library \
  "$ROOT_DIR"/Shared/NVBeaconCore/Sources/NVBeaconCore/*.swift \
  "$ROOT_DIR/Sources/NVBeacon/ProcessCommandRunner.swift" \
  "$ROOT_DIR/scripts/benchmark_host_metrics.swift" \
  -o "$OUTPUT_DIR/benchmark-host-metrics"

"$OUTPUT_DIR/benchmark-host-metrics" "$@"
