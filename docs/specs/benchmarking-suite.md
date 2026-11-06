# Benchmarking Suite: Statistical Percentile Latency Analysis

The v1.2 benchmarking suite milestone provides statistical latency percentile
analysis across synthetic order flows, covering the core limit order book
engine, binary wire protocol decoders, and end-to-end wire-to-engine ingestion.

## Architecture and Components

The suite consists of four integrated modules:

1. **`Ocaml_lob.Stats`** (`lib/stats.ml`):
   Low-overhead, zero-allocation latency recording using pre-allocated integer arrays
   and nanosecond-resolution timing. Computes statistical distributions:
   `min_ns`, `p50_us`, `p90_us`, `p95_us`, `p99_us`, `p99_9_us`, `p99_99_us`,
   `max_ns`, `mean_ns`, `stddev_ns`, and sustained throughput.
2. **`Synthetic_flow`** (`bench/synthetic_flow.ml`):
   Deterministic generators for nine realistic synthetic order flows modeling distinct
   exchange market conditions and binary protocol feeds.
3. **`Bench_suite`** (`bench/bench_suite.ml`):
   Benchmark harness executing warmup and dual-pass measurement (an uninstrumented
   throughput and allocation pass, followed by high-resolution latency profiling).
   Outputs formatted ASCII tables, GitHub Flavored Markdown tables, and machine-readable JSON.
4. **`bin/bench.ml`** (`bin/bench.exe`):
   Command-line utility supporting order counts, warmup iterations, flow selection,
   and output format options.

## Synthetic Order Flows

The suite exercises nine distinct market profiles:

| Flow Name | Target Subsystem | Description |
| :--- | :--- | :--- |
| **Balanced Two-Sided** | Matching Engine | Alternating bids and asks (45% buy, 45% ask, 10% crossing) around a moving mid-price on a 1-tick grid. |
| **Deep Book Ladder** | DLL & Price Index | Deep liquidity placement across 200 distinct price levels (100 bids, 100 asks), testing level linking and hash probing. |
| **Aggressive Sweep** | Fill Loop & Pruning | Pre-seeded resting depth followed by multi-level aggressive fills, IOC liquidity sweeps, and FOK executions. |
| **Cancel Churn** | DLL Unlinking & Pool | High-frequency quote stuffing and rapid order cancellations across queue heads, middles, and tails. |
| **Iceberg Replenish** | Hidden Orders | Resting iceberg orders repeatedly hit by crossing orders, triggering the visible peak reload loop and queue repositioning. |
| **Mixed Realistic** | Full Engine Core | Composite institutional exchange profile: 45% limit quotes, 25% cancels, 15% aggressive sweeps, 10% IOC/FOK, 5% icebergs. |
| **ITCH 5.0 Feed Stream** | Wire Decoder | High-throughput binary parsing of 10 ITCH 5.0 message types (A, F, E, C, X, D, P, Q, S, R) in a contiguous stream. |
| **OUCH 5.0 Protocol Stream** | Wire Decoder | High-throughput binary parsing of OUCH 5.0 inbound requests (O, U, X) and outbound responses (A, E, C) with appendages. |
| **Wire-to-Engine Ingestion** | End-to-End Pipeline | Full wire-to-engine pipeline: decoding incoming binary OUCH enter and cancel payloads and executing them in the matching core. |

## Statistical Latency Methodology

To eliminate measurement contamination while preserving accuracy:

- **Dual-Pass Measurement**:
  1. *Uninstrumented Throughput & GC Pass*: Measures pure sustained engine throughput
     and minor heap allocations (`Gc.minor_words ()`) without per-iteration timer calls,
     avoiding float-boxing overhead.
  2. *Latency Profiling Pass*: Records per-operation elapsed time using nanosecond-resolution
     timestamps into the pre-allocated `Stats` buffer.
- **Percentiles**: Computes Min, p50, p90, p95, p99, p99.9, p99.99, Max, Mean, and Standard
  Deviation using rank order interpolation over the sorted latency sample array.
- **Top-Level DLL Unlinking**: Lifted `cancel_find_and_remove` to module top-level in `lib/engine.ml`,
  eliminating closure allocations during queue unlinking and maintaining zero allocation across
  cancellations.

## Acceptance and Verification

- **Statistical Monotonicity**: Verified across all flows:
  `min_ns <= p50 <= p90 <= p95 <= p99 <= p99.9 <= p99.99 <= max_ns`.
- **Latency Ceiling**: p99 latency stays strictly below the 100 μs regression ceiling across all flows.
- **Throughput Floor**: Sustained throughput exceeds the 0.40 MOps/s regression baseline.
- **Zero-Allocation Hot Path**: Matching engine flows maintain zero allocation per operation
  (amortized cold-path warmup `<= 0.20` bytes/order, `0` bytes per operation in warm steady state).
- **Bounded Wire Allocation**: ITCH 5.0 and OUCH 5.0 payload decoders maintain bounded record
  allocations `<= 512` bytes/payload.
- **Test Coverage**: Automated Alcotest suite in `test/test_benchmarks.ml` integrated into `dune runtest`,
  with 100.00% deterministic line coverage enforced across all `lib/` modules.
