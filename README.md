<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/banner-dark.png">
  <source media="(prefers-color-scheme: light)" srcset="assets/banner-light.png">
  <img alt="OCaml LOB: a limit order book and matching engine in OCaml 5. Beside the name, each price level is drawn as its queue of resting orders, oldest first, with the two oldest asks at the best price filled by a market buy." src="assets/banner-dark.png">
</picture>

# OCaml LOB

[![CI](https://github.com/Builder106/ocaml-limit/actions/workflows/deploy.yml/badge.svg)](https://github.com/Builder106/ocaml-limit/actions/workflows/deploy.yml)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](#license)
[![OCaml](https://img.shields.io/badge/OCaml-5.2%2B-EC6813?logo=ocaml&logoColor=white)](https://ocaml.org/)
[![Dream](https://img.shields.io/badge/Dream-1F8AAB?logo=ocaml&logoColor=white)](https://aantron.github.io/dream/)
[![Tailwind CSS](https://img.shields.io/badge/Tailwind_CSS-06B6D4?logo=tailwindcss&logoColor=white)](https://tailwindcss.com/)
[![Chart.js](https://img.shields.io/badge/Chart.js-FF6384?logo=chartdotjs&logoColor=white)](https://www.chartjs.org/)
[![Docker](https://img.shields.io/badge/Docker-2496ED?logo=docker&logoColor=white)](https://www.docker.com/)
[![Playwright](https://img.shields.io/badge/Playwright-2EAD33?logo=playwright&logoColor=white)](https://playwright.dev/)
[![Caddy](https://img.shields.io/badge/Caddy-1F88C0?logo=caddy&logoColor=white)](https://caddyserver.com/)
[![Oracle Cloud](https://img.shields.io/badge/Oracle_Cloud-F80000?logo=oracle&logoColor=white)](https://www.oracle.com/cloud/)
[![Demo](https://img.shields.io/badge/demo-live-success.svg)](https://ocaml-lob.vercel.app/)

> **A high-speed financial exchange engine.** OCaml-Limit pairs buyers and sellers at sub-millisecond speeds, featuring a live Bloomberg-style trading terminal.

## 💡 What is OCaml-Limit?

At modern stock exchanges, millions of buy and sell orders arrive every second. OCaml-Limit is the core engine responsible for matching buyers and sellers instantly and fairly. It is built to run continuously with zero micro-pauses or lag, paired with an interactive market dashboard.

The matching hot path is allocation-free per submit (bench-validated), achieves ~18 million orders/sec in clean performance benchmarks, and holds p99 latency under 1 microsecond.

🟢 **Live demo:** [ocaml-lob.vercel.app](https://ocaml-lob.vercel.app/) (dashboard hosted on Vercel, matching engine running on an Oracle Cloud VM). Click the info icon in the top right for an in-app tour.

---

## 🛠 Technical Architecture

A working implementation of an exchange-grade matching engine. The engine matches trades based on price and time priority, supporting standard professional order types:
- **Limit and Market Orders**: Standard trades at specified or market prices.
- **Iceberg Orders**: Large orders that hide total volume to avoid moving the market.
- **Immediate-or-Cancel (IOC) and Fill-or-Kill (FOK)**: Time-in-force conditions that prevent partial or lingering fills.
- **Pre-trade Risk Checks**: Automated guardrails blocking invalid or oversized orders.

The core API is compact:

```ocaml
open Ocaml_lob.Types
module Engine = Ocaml_lob.Engine

let engine = Engine.create default_config in
let order  = make_order ~id:1 ~side:Buy ~price:1_502_500 ~qty:100
               ~order_type:Limit ~timestamp:0 in

match Engine.submit engine order (fun passive_id active_id price qty _ts ->
        Printf.printf "fill: %d×%d @ %d (passive=%d active=%d)\n"
          qty 1 price passive_id active_id)
with
| Ok ()   -> () (* order accepted *)
| Error _ -> () (* pre-trade risk rejected *)
```

Six layered optimizations eliminate memory allocation overhead on the matching hot path:
1. Reusing pre-allocated result constants
2. Direct exception handling to avoid memory wrapper allocations
3. Top-level execution loops that avoid runtime closures
4. Compact doubly linked lists for price levels
5. Reusing inactive price levels rather than rebuilding tree structures
6. Fast custom hash tables replacing general-purpose map allocations

Full architectural details are in [ONBOARDING.md](ONBOARDING.md).

---

## Architecture (user flow)

The browser loads the static dashboard from Vercel. Its JavaScript opens an `EventSource` on `/events` and sends orders with `POST /order`, pointing both at the remote host when the page is served from a Vercel hostname. In the documented design, Caddy terminates TLS and proxies both routes to a Dream server, which streams book snapshots every 500 ms and trades as SSE events. `POST /order` returns `200 {"status":"ok"}`, and any fill follows over SSE.

That server was removed from this repository in commit `7a5e8a4`. The checked-in Dockerfile builds and runs `perf_test`. SSE replaced an earlier WebSocket transport after `gluten_lwt`'s WS close path was found to wedge the event loop in a tight retry-on-failed-write cycle (see commit `0c62bc0`).

---

## Features

Demo videos below were recorded with Playwright + the project's local E2E suite. Each one shows a single user flow end-to-end so you can see the dashboard behaving live.

<details>
<summary><strong>Live order book + depth chart + trade tape</strong></summary>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/demos/01-core-dark.gif">
  <img src="assets/demos/01-core-light.gif" alt="Live order book, depth chart, and trade tape">
</picture>

The dashboard streams L2 book snapshots every 500 ms over Server-Sent Events. The depth chart on the center pane visualizes resting liquidity; the trade tape on the right shows every fill the engine produces (both from the in-process demo bot and from manual orders).

</details>

<details>
<summary><strong>Manual order entry with live risk feedback</strong></summary>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/demos/02-manual-entry-dark.gif">
  <img src="assets/demos/02-manual-entry-light.gif" alt="Submitting a manual order from the Quick Entry panel">
</picture>

The Quick Entry panel POSTs orders straight into the running engine. Rejected orders surface in the Risk Engine Activity log on the left.

</details>

<details>
<summary><strong>First-visit onboarding modal</strong></summary>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/demos/04-onboarding-dark.gif">
  <img src="assets/demos/04-onboarding-light.gif" alt="First-visit onboarding modal: open, dismiss, re-open via info icon">
</picture>

Auto-opens on first visit with the headline numbers and a panel-by-panel guide. Dismissal persists in `localStorage`; the (i) icon in the header re-opens it.

</details>

> **For maintainers:** recording flow — `npm --prefix e2e run demo`records mp4s at 1440×900 into`e2e/demo-output/`, then `npm --prefix e2e run gifs`converts them to 1280px-wide GIFs in`assets/demos/`. Every feature has a `-light`and`-dark`variant; the README embeds them via`<picture media="(prefers-color-scheme: dark)">` so the active gif follows the reader's browser theme. Recorded close to the README's display resolution so the GIFs are crisp on Retina without blowing GitHub's 10 MB inline-image cap.

---

## Try it locally

Prerequisites: opam 2.x with an OCaml 5.x switch active.

```bash
opam install --deps-only --with-test -y .   # alcotest + transitive
opam install -y dream yojson lwt_ppx        # server-only deps
dune build                                   # compile everything
dune runtest                                 # 11 tests across matching + perf
dune exec bin/server.exe                     # serves on localhost:8080
dune exec bin/bench.exe                      # 1M-order benchmark with allocation report
dune exec bin/diag.exe                       # bytes/order at varying scales
```

Open `http://localhost:8080/`. The demo bot starts automatically.

For deploying to your own VM (Oracle Cloud Always-Free walkthrough), see [DEPLOY.md](DEPLOY.md).

---

## CI/CD pipeline

[.github/workflows/deploy.yml](.github/workflows/deploy.yml) wires up CI + CD on every push to `main`.

Both image builds wait for the test job, so a failed test publishes nothing.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/diagrams/deployment-flow-dark.png">
  <img src="assets/diagrams/deployment-flow.png" alt="The build and test job either fails and stops with no image published, or starts native amd64 and arm64 image builds in parallel. Both feed a manifest merge tagged latest and with the commit SHA, which feeds the deploy job." width="880">
</picture>

A push to `main` runs `dune build` and `dune runtest`. Passing tests start native amd64 and arm64 image builds in parallel. Their tags merge into one GHCR manifest tagged `latest` and with the commit SHA, and the deploy job pulls `latest` and runs it on the host. [Editable HTML source](assets/diagrams/deployment-flow.html).

**Sequential gating**: both architecture builds have `needs: test`, so a failed test prevents either image from being published. `merge-manifest` waits for both builds, and `deploy-vm` waits for the manifest. The `deploy-prod` concurrency group keeps releases from racing on the host.

**Caching**: `ocaml/setup-ocaml@v3` caches the opam switch. Both native Docker builds use the GitHub Actions layer cache.

**Secrets** (`SSH_HOST`, `SSH_USER`, `SSH_PRIVATE_KEY`) are used by the deploy job's SSH command. Setup walkthrough in DEPLOY.md.

---

## Test suite

Two Alcotest files under [test/](test/), 11 cases total. Runs in well under a second.

| Group | Test | What it pins |
| --- | --- | --- |
| `matching` | Basic matching | Same-price Buy/Ask filling each other |
| `matching` | Iceberg reload | Visible-portion exhausts, hidden portion reloads at the queue tail; total qty conserved |
| `matching` | Post-only rejection | Crossing post-only returns`Reject_price_band` |
| `matching` | Cancel preserves FIFO | Canceling a mid-queue order leaves FIFO linkage intact across the gap |
| `matching` | Sweep across levels | Aggressive order eating partial fills across 3 price levels with correct`pl_total_qty` |
| `matching` | Level resurrection | Empty level + new order at same price re-promotes`best_level` |
| `messaging` | MPSC FIFO (1 producer) | Single-producer/consumer round-trip preserves order |
| `messaging` | MPSC FIFO (4 domains) | 4 OCaml Domains push concurrently; per-producer FIFO holds across 1000 messages |
| `regression` | Zero per-order allocation | `≤ 0.20 bytes/order` over 100k submits (measured: ~0.06) |
| `regression` | Throughput floor | `≥ 0.5 M orders/sec` (measured: ~30+) |
| `regression` | p99 latency ceiling | `≤ 100 μs` (measured: ~1 μs) |

The two matching cases that originally surfaced as test failures (`Sweep across levels`and`Level resurrection`) caught a real production bug — an OCaml scope gotcha where `else let … in …; stmt; stmt;`silently extended into following statements, dropping`pl_total_qty`and the resurrection check on the`tail_idx = -1` code path. Fix shipped; the tests stay as regression sentinels.

---

## Project layout

```text
ocaml_lob/
├── lib/                           engine + types + custom data structures
│   ├── types.ml                   price_level, book_side, sentinel_level
│   ├── engine.ml                  submit, fill_loop, link_level
│   ├── price_index.ml             open-addressing hashtable replacing stdlib Map
│   ├── pool.ml                    pre-allocated order pool
│   ├── risk.ml                    pre-trade gates (variant returns, no exns)
│   ├── stats.ml                   nanosecond latency tracker
│   └── messaging.ml               OCaml 5 atomic MPSC queue
├── bin/
│   ├── server.ml                  Dream HTTP: GET /events (SSE), POST /order, demo bot
│   ├── bench.ml                   1M-order benchmark, prints throughput + alloc
│   └── diag.ml                    raw bytes/order measurement via Gc.minor_words
├── test/
│   ├── test_engine.ml             matching + messaging cases
│   └── perf_test.ml               regression guards
├── front/                         dashboard (vanilla JS + Tailwind CDN + Chart.js)
├── assets/                        repo-only banner artwork
├── Dockerfile                     multi-stage: ocaml/opam → ubuntu:22.04
├── DEPLOY.md                      Oracle Cloud E2.1.Micro walkthrough
├── ONBOARDING.md                  architecture deep-dive for new contributors
└── .github/workflows/deploy.yml   CI (test) + CD (build + ship)
```

---

## Documentation

- **[ONBOARDING.md](ONBOARDING.md)** — full architecture, the six perf fixes explained, known gotchas, hang runbook

## License

MIT. See [`ocaml_lob.opam`](ocaml_lob.opam) for full package metadata.
