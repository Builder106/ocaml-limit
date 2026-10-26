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
[![Tailscale](https://img.shields.io/badge/Tailscale_Funnel-242424?logo=tailscale&logoColor=white)](https://tailscale.com/kb/1223/funnel)
[![Oracle Cloud](https://img.shields.io/badge/Oracle_Cloud-F80000?logo=oracle&logoColor=white)](https://www.oracle.com/cloud/)
[![Demo](https://img.shields.io/badge/demo-live-success.svg)](https://ocaml-lob.vercel.app/)

> **A high-speed financial exchange engine.** OCaml-Limit pairs buyers and sellers at sub-millisecond speeds, featuring a live Bloomberg-style trading terminal.

## 💡 What is OCaml-Limit?

At modern stock exchanges, millions of buy and sell orders arrive every second. OCaml-Limit is the core engine responsible for matching buyers and sellers instantly and fairly. It is built to run continuously with zero micro-pauses or lag, paired with an interactive market dashboard.

The matching hot path is allocation-free per submit (bench-validated), achieves ~18 million orders/sec in clean performance benchmarks, and holds p99 latency under 1 microsecond.

🟢 **Live demo:** [ocaml-lob.vercel.app](https://ocaml-lob.vercel.app/). The page is static on Vercel and the engine runs in a container behind a Tailscale Funnel. Each price row shows its queue of resting orders, and orders you send join the same book. Press `3` for a short explanation.

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

The browser loads the static dashboard from Vercel. Its JavaScript opens an `EventSource` on `/events` and sends orders with `POST /order`, pointing both at the Funnel host when the page is served from a Vercel hostname. Tailscale terminates TLS and proxies both routes to the Dream server in `bin/server.ml`. Every 500 ms the server sends a `BOOK` event with each level's FIFO queue (order id and remaining size, oldest first) and a `STATS` event with counters, then any `TRADE` events since the last frame. `POST /order` takes `{"side": "BUY" | "SELL", "price": <ticks>, "qty": <int>}` and answers with the order id and how much filled on arrival; later fills follow over SSE.

At startup the server times the `perf_test` workload on its own host and reports that throughput and allocation figure to the page. A demo bot keeps the book moving on a 50-tick ($0.0050) grid. Visitor orders must sit on that grid within 1,000 ticks of the mid, and the bot cancels the oldest order at the farthest level once a side holds more than 120 orders, so a long-running demo can't fill the price index or the node pool.

The Docker image runs the server by default and also ships `./perf_test`. SSE replaced an earlier WebSocket transport after `gluten_lwt`'s WS close path was found to wedge the event loop in a tight retry-on-failed-write cycle (see commit `0c62bc0`).

---

## Features

Demo videos below were recorded with Playwright + the project's local E2E suite. Each one shows a single user flow end-to-end so you can see the dashboard behaving live.

<details>
<summary><strong>The live book, drawn as queues</strong></summary>

<img src="assets/demos/01-core.gif" alt="A fixed price ladder where each row holds its resting orders as blocks, oldest first. Fills shrink and remove blocks from the front of the queues while the fills tape updates.">

The dashboard streams the book every 500 ms over Server-Sent Events. Each row of the price ladder holds the orders resting at that price, oldest next to the price, and fills from the demo bot eat them from the front.

</details>

<details>
<summary><strong>Joining the queue at the best bid</strong></summary>

<img src="assets/demos/02-manual-entry.gif" alt="Clicking the best bid price, typing a quantity of 300, and pressing Send. The new order appears outlined at the back of the bid queue and the ticket reports its place in line.">

Clicking a price loads it into the ticket, and Send posts the order into the running engine. Your order is outlined in its queue, and the ticket counts its place in line as orders ahead of it fill.

</details>

<details>
<summary><strong>How it works</strong></summary>

<img src="assets/demos/03-how-it-works.gif" alt="Pressing 3 opens a short explanation of price-time priority and integer ticks, then Close returns to the book.">

Pressing `3`, or choosing it from the numbered menu, opens a short explanation of price-time priority and integer ticks.

</details>

> **For maintainers:** `npm --prefix e2e run demo` records mp4s at 1440×900 into `e2e/demo-output/`, then `npm --prefix e2e run gifs` converts them to 1280px-wide GIFs in `assets/demos/`. The page is dark-only, so each flow has one GIF. See [e2e/README.md](e2e/README.md) for recording from a machine inside the tailnet.

---

## Try it locally

Prerequisites: opam 2.x with an OCaml 5.x switch active.

```bash
opam install --deps-only --with-test -y .   # alcotest + transitive
opam install -y dream yojson lwt_ppx        # server-only deps
dune build                                   # compile everything
dune runtest                                 # 11 tests across matching + perf
dune exec bin/server.exe                     # serves on localhost:8080
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
│   └── server.ml                  Dream HTTP: GET /events (SSE), POST /order, demo bot
├── test/
│   ├── test_engine.ml             matching + messaging cases
│   └── perf_test.ml               regression guards
├── front/                         dashboard (one HTML file and one script, no build step)
├── assets/                        repo-only banner artwork
├── Dockerfile                     multi-stage: ocaml/opam → ubuntu:26.04
├── ONBOARDING.md                  architecture deep-dive for new contributors
└── .github/workflows/deploy.yml   CI (test) + CD (build + ship)
```

---

## Documentation

- **[ONBOARDING.md](ONBOARDING.md)** — full architecture, the six perf fixes explained, known gotchas, hang runbook

## License

MIT. See [`ocaml_lob.opam`](ocaml_lob.opam) for full package metadata.
