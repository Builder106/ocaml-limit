# OCaml-Limit Roadmap

Pure functional high-performance order book engine roadmap.

## v1.1 — Zero-Allocation Matching Loop
- **Unboxed Float & Fixed-Point Records**: Eliminating GC pressure in the core limit order book execution path.
- **Property-Based Testing**: Exhaustive invariant fuzzing using QCheck for order insertion, cancellation, and execution.

## v1.2 — Binary Wire Protocols
- **ITCH 5.0 / OUCH 5.0 Parser**: High-throughput binary protocol decoders.
- **Benchmarking Suite**: Statistical percentile latency analysis across synthetic order flows.

## Out of Scope
- Blocking I/O in matching core
- Dynamic runtime type coercion

---
For technical specifications, see [`docs/specs/`](docs/specs/).
