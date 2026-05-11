# ocaml_lob — onboarding

A high-performance limit order book matching engine in OCaml 5, with a Dream WebSocket server and Bloomberg-terminal–styled browser dashboard. **Zero-allocation per submit** (verified — bench prints `[STUNNING] ZERO-ALLOCATION CLAIM VALIDATED`), ~18 M orders/s in the clean perf test, p99 latency ~1 μs.

**Live demo:** https://ocaml-lob.duckdns.org/

---

## 5-minute orientation

```
ocaml_lob/
├── lib/                         # the engine (all perf-sensitive code)
│   ├── types.ml                 # price_level, book_side, sentinel_level
│   ├── engine.ml                # submit, fill_loop, link_level
│   ├── price_index.ml           # custom open-addressing hashtable
│   ├── pool.ml                  # pre-allocated order pool
│   ├── risk.ml                  # pre-trade checks (variant returns, no exceptions)
│   ├── stats.ml                 # nanosecond latency tracker
│   └── messaging.ml             # OCaml 5 atomic MPSC queue (unused for now)
├── bin/
│   ├── server.ml                # Dream HTTP + /ws + demo bot
│   ├── bench.ml                 # 1M-order benchmark, prints throughput + alloc
│   └── diag.ml                  # one-shot allocation measurement via Gc.minor_words
├── test/
│   ├── test_engine.ml           # Alcotest matching correctness
│   └── perf_test.ml             # regression guards (bytes/order, throughput, p99)
├── front/                       # Bloomberg-style dashboard (vanilla JS + Tailwind CDN + Chart.js)
│   ├── index.html
│   ├── app.js                   # LOBTerminal class — WS client, render loop
│   └── favicon.svg              # depth-chart silhouette
├── Dockerfile                   # multi-stage: ocaml/opam → ubuntu:22.04
├── DEPLOY.md                    # Oracle Cloud E2.1.Micro provisioning walkthrough
└── .github/workflows/deploy.yml # build → GHCR → SSH-deploy on push to main
```

## Build & run locally

Prerequisites: opam 2.x with an OCaml 5.x switch active.

```bash
opam install --deps-only -y .         # dream, yojson, lwt_ppx, alcotest
dune build                            # compiles everything
dune exec bin/server.exe              # serves on localhost:8080 (set INTERFACE=0.0.0.0 for external)
dune exec bin/bench.exe               # 1M-order benchmark
dune runtest                          # matching + perf regression tests
dune exec bin/diag.exe                # raw bytes-per-order measurement (see "Perf" below)
```

The dashboard is at `http://localhost:8080/`. The demo bot starts automatically; it seeds 15 levels per side then submits ~1 order/sec.

> **Local gotcha — libssl on macOS:** `dune build bin/server.exe` may fail at the link stage with `ld: library 'ssl' not found` if Homebrew has rotated OpenSSL versions out from under you. `brew reinstall openssl@3` fixes it. The OCaml compile itself succeeds — `bench.exe` and `test/` build fine without OpenSSL.

## Tests + benchmarks

`dune runtest` enforces three regression guards in [test/perf_test.ml](test/perf_test.ml):

| Guard | Threshold | Why |
|---|---|---|
| `bytes_per_order_ceiling` | ≤ 0.20 bytes/order | Hot path is allocation-free; this catches any new allocation regressing per-submit work. Measured via `Gc.minor_words`, not `minor_collections` — the latter is contaminated by `Gc.stat`'s own allocation. |
| `throughput_floor_mops` | ≥ 0.5 M orders/s | CI-safe floor; engine routinely does 10×+ this. |
| `p99_ceiling_us` | ≤ 100 μs | Engine is sub-μs in practice; the ceiling absorbs `gettimeofday` measurement noise. |

`bin/bench.exe` is the user-facing perf demo — prints throughput, p50/p99/p99.9, and self-validates the zero-allocation claim.

## Architecture: the zero-allocation hot path

The path through `Engine.submit` doesn't allocate. Six layered fixes got it there:

1. **Pre-allocated result wrappers.** `submit` returns shared `r_ok` / `r_reject_*` module-level constants instead of building fresh `Ok ()` / `Error _` per call.
2. **`PriceMap.find` + `exception Not_found`** instead of `find_opt` (which boxes a `Some level` per hit).
3. **`fill_loop` lifted to top level** so its recursive self-call compiles to a jump without allocating a capturing closure.
4. **Intrusive doubly-linked list** of price levels (`pl_prev_level` / `pl_next_level`, sentinel-terminated via self-referential `Types.sentinel_level`). `fill_loop`'s level-exhaustion path walks the DLL — no `Some (k, v)` from `max_binding_opt`.
5. **Lazy-keep on exhaustion**: empty levels stay in the index and the DLL. `submit` has resurrection logic that re-promotes a re-populated level to `best_level` if it beats the current best.
6. **Custom `Price_index`** open-addressing hashtable (lib/price_index.ml) replacing stdlib `Map.Make(Int)`. Stdlib `Map.add` rebuilt the tree spine per insert (~36 KB warmup); this allocates nothing on the hot path.

`book_side` no longer has a `best : price` field — read the price via `book_side.best_level.pl_price` and test for "no liquidity" with physical equality against `Types.sentinel_level`.

## Deployment

Live at https://ocaml-lob.duckdns.org/ on an Oracle Cloud Always-Free E2.1.Micro in `us-phoenix-1`. Caddy fronts the container with auto-renewing Let's Encrypt TLS. Auto-deploy on push to `main` via [.github/workflows/deploy.yml](.github/workflows/deploy.yml): builds the linux/amd64 image with GHA layer cache, pushes to GHCR, SSHs into the VM to pull and restart.

For first-time setup or rebuilding the VM, see [DEPLOY.md](DEPLOY.md). For the resource OCIDs and cleanup commands, see the memory entry `oracle_deployment.md`.

## Known gotchas

- **`Price_index` capacity is fixed** (no resize) at 65536 slots / side. `add` raises `Failure` if the table fills. An earlier 8192 cap took down the live VM after ~3 hours when the demo bot's drifting mid-price filled it; if you change the bot's drift rate or expect more distinct prices, recompute the capacity needed in `engine.ml: price_index_capacity`.
- **The demo bot is rate-limited** (loop interval 400–1000 ms, mid drift clamped to ±300 ticks) after a back-pressure incident hung the live container ~40 s after a browser WS connection. Faster bot = more impressive demo but worse stability on a 1/8 OCPU box.
- **`gh secret set` is async with workflow triggers.** Secrets are resolved at workflow-START time, not step-time, so setting a secret after `git push` does not help the in-flight run. Set first, push second.
- **`${{ github.repository }}` preserves owner casing.** Docker requires lowercase image names; `metadata-action` auto-lowercases for tagging, but raw uses in scripts need `${VAR,,}` (bash parameter expansion).
- **GHCR packages inherit the repo's visibility on first push.** Public repo → public package → VM can `docker pull` anonymously. Make the repo private and the deploy job needs a PAT.
- **bench's throughput is measurement-bound.** Per-iteration `Unix.gettimeofday` boxes floats; bench tops out around 11–17 M/s. The clean perf_test (no per-iter timing) is the real engine number (~18 M/s + recent slowdown from `Price_index` cap bump).
- **Oracle's Always-Free instances are reclaimed after 7 days idle.** SSH in, hit the URL, or set up a free UptimeRobot ping to keep it warm.

## Where things live (operational)

- **Memory entries** (file-based, persistent across sessions): `~/.claude/projects/.../memory/` — `project_overview.md`, `engine_allocation_profile.md` (6-fix history + incident log), `oracle_deployment.md` (OCIDs + cleanup).
- **Commit history** is dense with rationale — `git log --oneline` reads as a project timeline; commit bodies explain *why* each change happened.
- **Bug history**: the `engine_allocation_profile.md` memory has a "Bug history" section logging the two production incidents (Price_index overflow → cap raise + probe bound; bot back-pressure → rate limit).

## If the live URL hangs

1. `ssh ubuntu@129.146.43.97` (or whatever IP `oracle_deployment.md` lists)
2. `docker stats ocaml_lob --no-stream` — if CPU is pegged ≥100%, it's a hang
3. `docker restart ocaml_lob` — restores service in ~3 sec
4. `docker logs --tail 100 ocaml_lob` — check what the bot was doing right before the hang
5. If it recurs: `sudo apt install strace; sudo strace -p $(docker inspect -f '{{.State.Pid}}' ocaml_lob)` next time, to see what syscall it's stuck on (or no syscall = pure CPU loop in OCaml land — most likely an unbounded recursion through the level DLL)
