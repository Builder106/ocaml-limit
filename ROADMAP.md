# OCaml-Limit Roadmap

Plans for the functional order book engine.

## v1.1 — Zero-Allocation Matching Loop

- [x] **Unboxed Float & Fixed-Point Records**: Eliminate GC pressure in the core limit order book execution path.
- [x] **Property-Based Testing**: Use QCheck to fuzz invariants for order insertion, cancellation, and execution.

## v1.2 — Binary Wire Protocols

- [x] **ITCH 5.0 / OUCH 5.0 Parser**: Decode binary protocols at high throughput.
- [x] **Benchmarking Suite**: Analyze latency percentiles across synthetic order flows.

## Out of Scope

- Blocking I/O in matching core
- Dynamic runtime type coercion

---
For technical specifications, see [`docs/specs/`](docs/specs/).
