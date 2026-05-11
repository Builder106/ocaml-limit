(** {1 Engine + Messaging Behavioral Tests}

    Alcotest-based correctness checks. Performance / allocation regressions
    live in [test/perf_test.ml]; this file is about WHAT the engine does,
    not how fast or how much it allocates.

    Covers:
    - Basic price-time matching.
    - Iceberg reload (visible portion exhausts, hidden portion reloads at tail).
    - Post-only rejection when the order would cross.
    - Cancel preserving FIFO across the canceled-out gap.
    - Aggressive orders sweeping multiple price levels in one submit.
    - Level resurrection (lazy-keep + promote-on-resubmit).
    - MPSC queue FIFO under single-producer and multi-producer (Domains). *)

open Ocaml_lob
open Types
module Engine = Engine
module Risk = Risk
module Messaging = Messaging

let reject_result_test =
    Alcotest.testable
        (fun ppf r -> Format.pp_print_string ppf (Risk.risk_result_to_string r))
        ( = )

(* A fill listener that records (passive_id, active_id, price, qty) for each
   fill so tests can inspect what matched. *)
let make_fill_recorder () =
    let fills = ref [] in
    let cb passive_id active_id price qty _ =
        fills := (passive_id, active_id, price, qty) :: !fills
    in
    (fills, cb)

let noop_on_fill _ _ _ _ _ = ()

let limit ~id ~side ~price ~qty =
    make_order ~id ~side ~price ~qty ~order_type:Limit ~timestamp:0

(* ────────────────────────────────────────────────────────────────────── *)
(*  Matching correctness                                                   *)
(* ────────────────────────────────────────────────────────────────────── *)

let test_basic_matching () =
    let engine = Engine.create default_config in
    let buy  = limit ~id:1 ~side:Buy ~price:100 ~qty:10 in
    let sell = limit ~id:2 ~side:Ask ~price:100 ~qty:10 in

    let fill_count = ref 0 in
    let on_fill _ _ _ _ _ = incr fill_count in

    let res_buy = Engine.submit engine buy on_fill in
    Alcotest.(check (result unit reject_result_test)) "Buy submit" (Ok ()) res_buy;
    Alcotest.(check int) "No fills on buy" 0 !fill_count;

    let res_sell = Engine.submit engine sell on_fill in
    Alcotest.(check (result unit reject_result_test)) "Sell submit" (Ok ()) res_sell;
    Alcotest.(check int) "One fill on sell" 1 !fill_count;
    Alcotest.(check int) "Buy filled" 0 buy.remaining_qty;
    Alcotest.(check int) "Sell filled" 0 sell.remaining_qty

let test_iceberg_reload () =
    (* Iceberg buy: 10 visible, 30 total = 3 chunks of 10. Aggressive
       sells of 10 should each fill one chunk; the 4th finds nothing. *)
    let engine = Engine.create default_config in
    let iceberg =
        make_order ~id:1 ~side:Buy ~price:100 ~qty:10
            ~order_type:(Iceberg { visible_qty = 10; total_qty = 30 })
            ~timestamp:0
    in
    ignore (Engine.submit engine iceberg noop_on_fill);

    let (fills, cb) = make_fill_recorder () in
    let sell_10 id = limit ~id ~side:Ask ~price:100 ~qty:10 in
    ignore (Engine.submit engine (sell_10 2) cb);
    ignore (Engine.submit engine (sell_10 3) cb);
    ignore (Engine.submit engine (sell_10 4) cb);
    Alcotest.(check int) "3 reloads × 10 qty each consumed" 3 (List.length !fills);
    let total = List.fold_left (fun acc (_, _, _, q) -> acc + q) 0 !fills in
    Alcotest.(check int) "Total qty filled = 30" 30 total;

    (* Fourth sell finds nothing on the bid side — should rest, no new fill. *)
    let resting = sell_10 5 in
    ignore (Engine.submit engine resting cb);
    Alcotest.(check int) "Fourth sell rests, no new fill" 3 (List.length !fills);
    Alcotest.(check int) "Fourth sell remaining" 10 resting.remaining_qty

let test_post_only_rejection () =
    (* Resting ask at 100; a post-only buy at 100 would cross → must reject. *)
    let engine = Engine.create default_config in
    ignore (Engine.submit engine (limit ~id:1 ~side:Ask ~price:100 ~qty:10) noop_on_fill);
    let post_only =
        make_order ~id:2 ~side:Buy ~price:100 ~qty:10
            ~order_type:Post_only ~timestamp:0
    in
    let res = Engine.submit engine post_only noop_on_fill in
    Alcotest.(check (result unit reject_result_test))
        "Post-only rejected with price-band reject"
        (Error Risk.Reject_price_band) res;
    Alcotest.(check bool) "Post-only original qty intact"
        true (post_only.remaining_qty = 10)

let test_cancel_preserves_fifo () =
    (* Three resting bids in time order at the same price. Cancel the middle
       one. An aggressive ask that consumes both remaining should fill in
       FIFO order, never seeing the canceled order. *)
    let engine = Engine.create default_config in
    ignore (Engine.submit engine (limit ~id:1 ~side:Buy ~price:100 ~qty:10) noop_on_fill);
    let mid = limit ~id:2 ~side:Buy ~price:100 ~qty:10 in
    ignore (Engine.submit engine mid noop_on_fill);
    ignore (Engine.submit engine (limit ~id:3 ~side:Buy ~price:100 ~qty:10) noop_on_fill);

    let canceled = Engine.cancel engine 2 100 Buy in
    Alcotest.(check bool) "Cancel of order 2 returns true" true canceled;
    Alcotest.(check bool) "Order 2 marked cancelled"
        true (mid.status = Cancelled);

    let (fills, cb) = make_fill_recorder () in
    let agg = limit ~id:4 ~side:Ask ~price:100 ~qty:20 in
    ignore (Engine.submit engine agg cb);

    Alcotest.(check int) "Two fills (skipping canceled order)" 2 (List.length !fills);
    let passive_ids =
        List.map (fun (p, _, _, _) -> p) !fills |> List.sort compare
    in
    Alcotest.(check (list int)) "Filled passive ids = [1; 3]" [1; 3] passive_ids

let test_sweep_across_levels () =
    (* Three ask levels stacked. One aggressive buy sweeps levels 100 and
       101 fully, plus a partial of level 102. *)
    let engine = Engine.create default_config in
    ignore (Engine.submit engine (limit ~id:1 ~side:Ask ~price:100 ~qty:10) noop_on_fill);
    ignore (Engine.submit engine (limit ~id:2 ~side:Ask ~price:101 ~qty:10) noop_on_fill);
    ignore (Engine.submit engine (limit ~id:3 ~side:Ask ~price:102 ~qty:10) noop_on_fill);

    let (fills, cb) = make_fill_recorder () in
    let agg = limit ~id:4 ~side:Buy ~price:103 ~qty:25 in
    ignore (Engine.submit engine agg cb);

    Alcotest.(check int) "Three partial / full fills" 3 (List.length !fills);
    let total = List.fold_left (fun acc (_, _, _, q) -> acc + q) 0 !fills in
    Alcotest.(check int) "Total filled qty = 25" 25 total;
    Alcotest.(check int) "Best ask now at price 102"
        102 engine.book.asks.best_level.pl_price;
    Alcotest.(check int) "Remaining qty at best ask = 5"
        5 engine.book.asks.best_level.pl_total_qty;
    Alcotest.(check int) "Aggressor fully consumed"
        0 agg.remaining_qty

let test_resurrection () =
    (* Two bids at 100 and 99. Sweep them both — level 100 becomes empty
       first, then fill_loop advances best to 99 to fulfill the second
       aggressor. Then submit a fresh buy at 100: get_or_create_level finds
       the now-empty level 100 in the index, was_empty triggers the
       resurrection check, and best_level gets promoted back to 100. *)
    let engine = Engine.create default_config in
    ignore (Engine.submit engine (limit ~id:1 ~side:Buy ~price:100 ~qty:10) noop_on_fill);
    ignore (Engine.submit engine (limit ~id:2 ~side:Buy ~price:99 ~qty:10) noop_on_fill);
    Alcotest.(check int) "Initial best bid = 100"
        100 engine.book.bids.best_level.pl_price;

    (* Sweep both levels. *)
    ignore (Engine.submit engine (limit ~id:3 ~side:Ask ~price:100 ~qty:10) noop_on_fill);
    ignore (Engine.submit engine (limit ~id:4 ~side:Ask ~price:99  ~qty:10) noop_on_fill);

    (* Resurrect level 100 with a fresh buy. *)
    ignore (Engine.submit engine (limit ~id:5 ~side:Buy ~price:100 ~qty:7) noop_on_fill);
    Alcotest.(check int) "Best bid resurrected at 100"
        100 engine.book.bids.best_level.pl_price;
    Alcotest.(check int) "Resurrected level qty = 7"
        7 engine.book.bids.best_level.pl_total_qty

(* ────────────────────────────────────────────────────────────────────── *)
(*  Messaging (MPSC queue) — concurrency tests using OCaml 5 Domains      *)
(* ────────────────────────────────────────────────────────────────────── *)

let drain_to_list q =
    let acc = ref [] in
    let rec loop () =
        match Messaging.pop q with
        | Some v -> acc := v :: !acc; loop ()
        | None -> ()
    in
    loop ();
    List.rev !acc

let test_mpsc_single_producer () =
    let q = Messaging.create () in
    for i = 1 to 100 do Messaging.push q i done;
    let popped = drain_to_list q in
    Alcotest.(check int) "All 100 values popped" 100 (List.length popped);
    Alcotest.(check (list int)) "Push/pop preserves FIFO order"
        (List.init 100 (fun i -> i + 1)) popped

let test_mpsc_multi_producer () =
    (* 4 domains each push 250 values; consumer drains after all join.
       Per-producer values are encoded as [producer_id * 1000 + seq] so we
       can split the output stream and check each producer's slice is
       still in submission order. *)
    let q = Messaging.create () in
    let n_producers = 4 in
    let per_producer = 250 in
    let producers =
        List.init n_producers (fun i ->
            Domain.spawn (fun () ->
                for j = 0 to per_producer - 1 do
                    Messaging.push q (i * 1000 + j)
                done))
    in
    List.iter Domain.join producers;

    let popped = drain_to_list q in
    Alcotest.(check int) "Total popped = N producers × per-producer"
        (n_producers * per_producer) (List.length popped);

    for i = 0 to n_producers - 1 do
        let slice = List.filter (fun v -> v / 1000 = i) popped in
        let expected = List.init per_producer (fun j -> i * 1000 + j) in
        Alcotest.(check (list int))
            (Printf.sprintf "Producer %d's slice is in submission order" i)
            expected slice
    done

(* ────────────────────────────────────────────────────────────────────── *)

let () =
    let open Alcotest in
    run "OCaml-LOB" [
        "matching", [
            test_case "Basic matching"          `Quick test_basic_matching;
            test_case "Iceberg reload"          `Quick test_iceberg_reload;
            test_case "Post-only rejection"     `Quick test_post_only_rejection;
            test_case "Cancel preserves FIFO"   `Quick test_cancel_preserves_fifo;
            test_case "Sweep across levels"     `Quick test_sweep_across_levels;
            test_case "Level resurrection"      `Quick test_resurrection;
        ];
        "messaging", [
            test_case "MPSC FIFO (1 producer)"   `Quick test_mpsc_single_producer;
            test_case "MPSC FIFO (4 domains)"    `Quick test_mpsc_multi_producer;
        ];
    ]
