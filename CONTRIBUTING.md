# Contributing

Thanks for the interest. This is a small, opinionated project — the matching engine's hot path is **zero-allocation per submit** and the test suite enforces it. Most of the guidance below is about not regressing that.

## Dev setup

Prerequisites:

- **opam 2.x** with an **OCaml 5.x** switch (5.2 is what CI builds against)
- A C toolchain (libev is a transitive dep; `brew install libev pkg-config` on macOS, the equivalent `apt install libev-dev pkg-config` on Linux)

Bootstrap:

```bash
opam install --yes --deps-only .
dune build
```

The first `opam install` takes ~10 min on a clean switch (Dream's dep tree is heavy). Subsequent builds are seconds.

## Build and run

```bash
# Matching engine + tests + bench — everything except the web server
dune build lib/ test/ bin/bench.exe

# Full server
dune build bin/server.exe
dune exec bin/server.exe         # localhost:8080, demo bot enabled

# Run with the demo bot off (e.g. for E2E recording)
BOT=0 dune exec bin/server.exe
```

## Tests

```bash
dune runtest            # alcotest matching-correctness suite + perf guards
dune exec bin/bench.exe # standalone bench, prints throughput / p99 / bytes-per-order
```

CI runs both via [.github/workflows/deploy.yml](.github/workflows/deploy.yml) before any image is built.

### Allocation regression guard

[test/perf_test.ml](test/perf_test.ml) asserts a `bytes_per_order_ceiling = 0.20` (measured is ~0.06). **Do not loosen this.** If your change pushes it over the ceiling, the right answer is almost always to find what allocated — not to bump the ceiling. The hot path's zero-alloc claim is load-bearing for the project's whole pitch.

Common allocation sources to watch for:

- Closures capturing local state inside `Engine.submit` or `fill_loop` — see [lib/engine.ml](lib/engine.ml). Always lift recursive helpers to top-level functions and pass state explicitly. Closures cost a heap allocation on every iteration.
- `Map.find_opt` / `max_binding_opt` / `min_binding_opt` allocate a `Some _` per call. Use `find` + `Not_found` or the custom `Price_index` from [lib/price_index.ml](lib/price_index.ml).
- Result records — pre-allocate them as module-level constants (`r_ok`, `r_reject_*` in [lib/engine.ml](lib/engine.ml)).
- Iteration over `PriceMap`/`Map` rebuilds tree spine on `remove`. Use the doubly-linked level list with lazy-keep instead.

Read [memory/engine_allocation_profile.md](https://github.com/Builder106/ocaml_limit) (project-internal note) or grep for "lazy-keep" / "intrusive DLL" in the engine source for the full story.

### Use `Gc.minor_words`, not `Gc.stat`

When measuring allocation: `Gc.stat ()` itself allocates a 17-field record and triggers minor heap flushes — it contaminates the measurement. `Gc.minor_words ()` is cumulative words allocated and is the right metric. The existing bench/test code uses it; new measurements should too.

## Server-side code (`bin/server.ml`)

The Dream HTTP server is **not** on the benchmarked path. The hot path ends at `Engine.submit`; everything in [bin/server.ml](bin/server.ml) is transport. So:

- The trade-tape / risk-alert fan-out goes through a bounded ring buffer that per-client SSE handlers drain on a 500 ms tick. **Don't add `Lwt.async (Dream.send …)` anywhere.** A long-standing wedge in this project came from queueing into gluten_lwt's write buffer for a client that subsequently closed — gluten's `write_loop_step` spins on the close path. The ring + per-client serialized drain is the workaround. See [bin/server.ml](bin/server.ml)'s "Fan-out Rings" section for the reasoning.

- WebSockets are gone. The `/events` endpoint is Server-Sent Events; manual orders POST to `/order`. If you find yourself reaching for `Dream.websocket`, stop and read the history in `bin/server.ml`.

- `SIGUSR1` triggers a diagnostic dump (Printexc callstack + GC stats) to stderr. Useful if the live container ever wedges again:

  ```bash
  ssh ubuntu@<vm-ip> 'sudo kill -USR1 $(docker inspect --format "{{.State.Pid}}" ocaml_lob)'
  docker logs --tail 200 ocaml_lob | grep -A 80 "SIGUSR1 dump"
  ```

## E2E demos

The repo ships a Gherkin/Playwright suite that records the demo GIFs embedded in the README. See [e2e/README.md](e2e/README.md) for the convention. Two key bits:

- Two suites would normally share infra (QA + demo); this repo only has the **demo** suite. Don't add assertion-dense scenarios there — that's a future QA-suite job.
- Recording resolution is `1440×900` (Playwright viewport) → `1280px` wide GIF. Light/dark variants per scenario feed the README's `<picture media="(prefers-color-scheme: dark)">` swap.

```bash
npm --prefix e2e run demo       # records mp4s → e2e/demo-output/
npm --prefix e2e run gifs       # converts to GIFs → assets/demos/
```

## Code style

- **No comments explaining what** the code does — the names should. Comments are for **why** something is non-obvious: a hidden invariant, a workaround for a specific bug, a perf trick whose intent isn't apparent from the source.
- **Bench-validated claims in code comments** must reference the measurement (see how [lib/engine.ml](lib/engine.ml) documents the layered allocation fixes).
- **Don't `match … with exception` to swallow exceptions silently.** Wrap with a context-bearing log line, or let it propagate. The Lwt side already has too much defensive `with _ ->` from the bad old days; new code shouldn't add more.

## PRs

- Match the existing commit-message style: `type(scope): subject` lowercase, body explains the why. The recent history is the best reference.
- Keep PRs focused. Combined "refactor + feature + style cleanup" PRs are harder to review than three separate ones.
- If you're touching the hot path, attach a before/after `bin/bench.exe` output. The numbers do the talking.
- CI gates merges. Don't skip the `dune runtest` step locally — the matching-correctness suite catches subtle regressions (the `Sweep across levels` and `Level resurrection` cases are particularly load-bearing).

## Reporting bugs

Open a GitHub issue with:

- The exact reproduction (a minimal script or `bin/bench.exe` invocation)
- Expected vs. observed behavior
- `dune --version`, `ocamlc -version`, OS/arch
- For runtime wedges on the live demo: include the SIGUSR1 stack dump if you can grab one before restarting the container

## Out of scope

A few things this project explicitly doesn't do:

- **Persistence.** The book is in-memory by design.
- **Multi-symbol.** Engine instances are per-symbol; orchestration is the caller's problem.
- **Network protocols beyond the demo.** No FIX, no ITCH, no OUCH — Server-Sent Events + a tiny JSON envelope is enough for the dashboard.
- **Authentication.** The live demo is a public sandbox.

PRs that add any of those will probably be closed unless they're cleanly separable behind a feature flag.
