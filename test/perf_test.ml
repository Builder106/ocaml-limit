(** {1 Performance Regression Tests}

    Locks current engine perf characteristics so a refactor can't silently regress them:
    - Per-order allocation stays at zero (cold-path warmup amortized out).
    - Sustained throughput stays above a CI-safe floor.
    - p99 latency stays below a sane ceiling.

    Thresholds are intentionally generous so this passes on under- provisioned CI runners.
    Tighten them as the engine improves.

    The allocation guard uses [Gc.minor_words] (cumulative words allocated in the minor
    heap), NOT [Gc.minor_collections] — [Gc.stat] itself allocates a 17-field record and
    triggers minor flushes, so collection counts reflect measurement overhead, not engine
    work. With [minor_words] the engine reports ~792 words fixed (cold-path price-level
    records on first sight of each price) and 0 words per submit at scale. *)

open Ocaml_lob
open Types
module Engine = Engine
module Stats = Stats

let num_orders = 100_000
let throughput_floor_mops = 0.5 (* 0.5 M orders/s — bench typically sees 5–50× this *)

let p99_ceiling_us =
  100.0 (* engine hot path is sub-μs; 100μs swallows gettimeofday noise *)

(* Per-order allocation budget: cold-path warmup is ~792 words = ~6.3KB
   total, fixed regardless of order count. At [num_orders = 100_000]
   that's ~0.06 bytes/order. Set the ceiling at 0.20 bytes/order = ~25k
   bytes / 100k orders, comfortably above the cold-path floor while
   still failing on any actual per-submit allocation regression. *)
let bytes_per_order_ceiling = 0.20

(* Mirror bench.ml's pre-allocation pattern: build the order array
   outside the timed/measured region so we're only measuring the engine. *)
let make_order_pool () =
  Array.init num_orders (fun i ->
      let side = if i mod 2 = 0 then Buy else Ask in
      let price = 100_000 + (i mod 100) in
      make_order ~id:i ~side ~price ~qty:10 ~order_type:Limit ~timestamp:0)

let dummy_on_fill _ _ _ _ _ = ()

let test_zero_per_order_allocation () =
  let engine = Engine.create default_config in
  let pool = make_order_pool () in
  let mw_before = Gc.minor_words () in

  for i = 0 to num_orders - 1 do
    ignore (Engine.submit engine pool.(i) dummy_on_fill)
  done;

  let mw_after = Gc.minor_words () in
  let bytes_per_order = (mw_after -. mw_before) *. 8.0 /. float_of_int num_orders in
  Alcotest.(check bool)
    (Printf.sprintf "allocation <= %.2f bytes/order (measured %.4f)"
       bytes_per_order_ceiling bytes_per_order)
    true
    (bytes_per_order <= bytes_per_order_ceiling)

let test_throughput_floor () =
  let engine = Engine.create default_config in
  let pool = make_order_pool () in

  let start = Unix.gettimeofday () in
  for i = 0 to num_orders - 1 do
    ignore (Engine.submit engine pool.(i) dummy_on_fill)
  done;
  let elapsed = Unix.gettimeofday () -. start in
  let mops_per_sec = float_of_int num_orders /. elapsed /. 1_000_000.0 in

  Alcotest.(check bool)
    (Printf.sprintf "throughput >= %.2f Mops/s (measured %.2f)" throughput_floor_mops
       mops_per_sec)
    true
    (mops_per_sec >= throughput_floor_mops)

let test_p99_latency_ceiling () =
  let engine = Engine.create default_config in
  let pool = make_order_pool () in
  let stats = Stats.create num_orders in

  for i = 0 to num_orders - 1 do
    let t0 = Unix.gettimeofday () in
    ignore (Engine.submit engine pool.(i) dummy_on_fill);
    let ns = (Unix.gettimeofday () -. t0) *. 1_000_000_000.0 |> int_of_float in
    Stats.record stats ns
  done;

  let p99_us = Stats.get_percentile stats 0.99 in
  Alcotest.(check bool)
    (Printf.sprintf "p99 <= %.0f μs (measured %.2f)" p99_ceiling_us p99_us)
    true (p99_us <= p99_ceiling_us)

let () =
  let open Alcotest in
  run "OCaml-LOB perf"
    [
      ( "regression",
        [
          test_case "Zero per-order allocation" `Quick test_zero_per_order_allocation;
          test_case "Throughput floor" `Quick test_throughput_floor;
          test_case "p99 latency ceiling" `Quick test_p99_latency_ceiling;
        ] );
    ]
