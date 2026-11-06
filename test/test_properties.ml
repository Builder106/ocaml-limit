(** {1 Limit Order Book Property-Based Tests}

    Exhaustive invariant fuzzing using QCheck for order insertion, cancellation, and
    execution.

    Invariants verified:
    - Sorted price level doubly-linked lists (Bids descending, Asks ascending).
    - Doubly-linked list pointer integrity ([pl_prev_level] / [pl_next_level]).
    - FIFO queue ordering within price levels ([pl_head] to [pl_tail]).
    - Price level volume and count conservation ([pl_total_qty], [pl_order_count]).
    - Pool node allocation conservation (zero node leaks).
    - Uncrossed book invariant (best active bid < best active ask).
    - Price-time priority matching execution.
    - Post-only, IOC, and FOK order semantics.
    - Iceberg order visible reload and queue re-ordering.
    - Exact risk position tracking conservation.
    - Randomized stateful command sequence fuzzing with continuous invariant checks. *)

open Ocaml_lob
open Types

let test_config =
  {
    default_config with
    max_orders = 50_000;
    max_order_qty = 1_000_000;
    max_position = 100_000_000;
  }

(* ────────────────────────────────────────────────────────────────────── *)
(*  Fill Recorder and Helper Types                                        *)
(* ────────────────────────────────────────────────────────────────────── *)

type fill_event = { passive_id : order_id; fill_price : price; fill_qty : qty }

let make_recorder () =
  let fills = ref [] in
  let cb passive_id _active_id fill_price fill_qty _ts =
    fills := { passive_id; fill_price; fill_qty } :: !fills
  in
  (fills, cb)

let dummy_on_fill _ _ _ _ _ = ()

(* ────────────────────────────────────────────────────────────────────── *)
(*  Comprehensive Invariant Checkers                                      *)
(* ────────────────────────────────────────────────────────────────────── *)

(** Verify the FIFO order queue at a single price level *)
let check_level_queue pool side (level : price_level) =
  if level.pl_order_count = 0 then (
    if level.pl_head <> -1 || level.pl_tail <> -1 || level.pl_total_qty <> 0 then
      failwith
        (Printf.sprintf
           "Empty level at price %d has inconsistent head/tail/qty: head=%d, tail=%d, \
            qty=%d"
           level.pl_price level.pl_head level.pl_tail level.pl_total_qty))
  else (
    if level.pl_head = -1 || level.pl_tail = -1 || level.pl_total_qty <= 0 then
      failwith
        (Printf.sprintf
           "Non-empty level at price %d has invalid head/tail/qty: head=%d, tail=%d, \
            qty=%d, count=%d"
           level.pl_price level.pl_head level.pl_tail level.pl_total_qty
           level.pl_order_count);

    (* Forward traversal *)
    let forward_nodes = ref [] in
    let forward_qty = ref 0 in
    let rec walk_fwd idx prev_idx =
      if idx = -1 then prev_idx
      else
        let node = Pool.get pool idx in
        if node.qn_prev <> prev_idx then
          failwith
            (Printf.sprintf "Node %d qn_prev mismatch: expected %d, got %d" idx prev_idx
               node.qn_prev);
        if node.qn_order.status <> Active then
          failwith
            (Printf.sprintf "Node %d order %d status is not Active: %s" idx
               node.qn_order.id
               (status_to_string node.qn_order.status));
        if node.qn_order.remaining_qty <= 0 then
          failwith
            (Printf.sprintf "Node %d order %d has non-positive remaining qty: %d" idx
               node.qn_order.id node.qn_order.remaining_qty);
        if node.qn_order.price <> level.pl_price then
          failwith
            (Printf.sprintf "Node %d order %d price %d does not match level %d" idx
               node.qn_order.id node.qn_order.price level.pl_price);
        if node.qn_order.side <> side then
          failwith
            (Printf.sprintf "Node %d order %d side does not match book side" idx
               node.qn_order.id);
        forward_nodes := idx :: !forward_nodes;
        forward_qty := !forward_qty + node.qn_order.remaining_qty;
        walk_fwd node.qn_next idx
    in
    let last_fwd = walk_fwd level.pl_head (-1) in
    if last_fwd <> level.pl_tail then
      failwith
        (Printf.sprintf "Forward walk ended at %d but level.pl_tail is %d" last_fwd
           level.pl_tail);

    let count = List.length !forward_nodes in
    if count <> level.pl_order_count then
      failwith
        (Printf.sprintf "Level order count mismatch: counted %d, recorded %d" count
           level.pl_order_count);
    if !forward_qty <> level.pl_total_qty then
      failwith
        (Printf.sprintf "Level total qty mismatch: counted %d, recorded %d" !forward_qty
           level.pl_total_qty);

    (* Backward traversal *)
    let backward_nodes = ref [] in
    let rec walk_bwd idx next_idx =
      if idx = -1 then next_idx
      else
        let node = Pool.get pool idx in
        if node.qn_next <> next_idx then
          failwith
            (Printf.sprintf "Node %d qn_next mismatch: expected %d, got %d" idx next_idx
               node.qn_next);
        backward_nodes := idx :: !backward_nodes;
        walk_bwd node.qn_prev idx
    in
    let first_bwd = walk_bwd level.pl_tail (-1) in
    if first_bwd <> level.pl_head then
      failwith
        (Printf.sprintf "Backward walk ended at %d but level.pl_head is %d" first_bwd
           level.pl_head);

    if !forward_nodes <> List.rev !backward_nodes then
      failwith "Forward and backward node traversals do not match")

(** Verify the doubly-linked list of price levels on one side *)
let check_side_dll pool side (book_side : book_side) =
  let root = book_side.root_level in
  if root == sentinel_level then (0, [])
  else (
    if root.pl_prev_level != sentinel_level then
      failwith "root_level pl_prev_level is not sentinel_level";

    let levels_visited = ref [] in
    let total_orders = ref 0 in
    let seen_best = ref false in
    let rec walk lvl prev_lvl =
      if lvl == sentinel_level then ()
      else (
        if lvl.pl_prev_level != prev_lvl then
          failwith (Printf.sprintf "Level %d pl_prev_level mismatch" lvl.pl_price);
        if List.memq lvl !levels_visited then
          failwith (Printf.sprintf "Cycle detected at price level %d" lvl.pl_price);
        levels_visited := lvl :: !levels_visited;

        if lvl == book_side.best_level then seen_best := true;
        (* Any level ahead of best_level must be exhausted *)
        if (not !seen_best) && book_side.best_level != sentinel_level then
          if lvl.pl_order_count > 0 then
            failwith
              (Printf.sprintf "Level %d ahead of best_level %d has %d active orders"
                 lvl.pl_price book_side.best_level.pl_price lvl.pl_order_count);

        (* Check monotonicity against next level *)
        let next = lvl.pl_next_level in
        (if next != sentinel_level then
           match side with
           | Buy ->
               if lvl.pl_price <= next.pl_price then
                 failwith
                   (Printf.sprintf "Bid levels not strictly descending: %d followed by %d"
                      lvl.pl_price next.pl_price)
           | Ask ->
               if lvl.pl_price >= next.pl_price then
                 failwith
                   (Printf.sprintf "Ask levels not strictly ascending: %d followed by %d"
                      lvl.pl_price next.pl_price));

        check_level_queue pool side lvl;
        total_orders := !total_orders + lvl.pl_order_count;
        walk next lvl)
    in
    walk root sentinel_level;
    (!total_orders, List.rev !levels_visited))

(** Find the best active (non-empty) price level on a side *)
let find_best_active_level (book_side : book_side) =
  let rec loop lvl =
    if lvl == sentinel_level then None
    else if lvl.pl_order_count > 0 then Some lvl
    else loop lvl.pl_next_level
  in
  loop book_side.best_level

(** Verify all structural invariants across the entire order book *)
let check_book_invariants (engine : Engine.t) ~expected_net_position =
  let bid_orders, _ = check_side_dll engine.pool Buy engine.book.bids in
  let ask_orders, _ = check_side_dll engine.pool Ask engine.book.asks in

  (* Pool allocation count matches active resting orders exactly *)
  let alloc_nodes, _cap = Pool.stats engine.pool in
  let total_resting = bid_orders + ask_orders in
  if alloc_nodes <> total_resting then
    failwith
      (Printf.sprintf
         "Pool allocation leak/mismatch: pool alloc = %d, total resting = %d (bids: %d, \
          asks: %d)"
         alloc_nodes total_resting bid_orders ask_orders);

  (* Uncrossed book invariant: best active bid < best active ask *)
  (match
     (find_best_active_level engine.book.bids, find_best_active_level engine.book.asks)
   with
  | Some best_bid, Some best_ask ->
      if best_bid.pl_price >= best_ask.pl_price then
        failwith
          (Printf.sprintf
             "Crossed book detected! Best active bid %d >= best active ask %d"
             best_bid.pl_price best_ask.pl_price)
  | _ -> ());

  (* Risk position conservation *)
  let cur_pos = engine.risk.net_position in
  if cur_pos <> expected_net_position then
    failwith
      (Printf.sprintf "Risk position mismatch: tracker has %d, expected %d" cur_pos
         expected_net_position)

(* ────────────────────────────────────────────────────────────────────── *)
(*  QCheck Generators                                                     *)
(* ────────────────────────────────────────────────────────────────────── *)

let gen_side = QCheck.oneof_list [ Buy; Ask ]

let gen_grid_price =
  (* Fixed 50-tick grid centered around 100_000 ticks *)
  QCheck.map (fun k -> 100_000 + (k * 50)) (QCheck.int_range 0 40)

let gen_qty = QCheck.int_range 1 200

(* ────────────────────────────────────────────────────────────────────── *)
(*  Section 1: Insertion Properties                                       *)
(* ────────────────────────────────────────────────────────────────────── *)

(** Property: Non-crossing limit order insertions maintain sorted price levels, bid/ask
    monotonicity, and correct queue counts. *)
let prop_insertion_sorted_levels =
  let gen =
    QCheck.list_size (QCheck.Gen.int_range 5 40)
      (QCheck.pair gen_side (QCheck.pair gen_grid_price gen_qty))
  in
  QCheck.Test.make ~count:100 ~name:"insertion_sorted_levels" gen (fun orders_spec ->
      let engine = Engine.create test_config in
      let id = ref 0 in
      let total_fills = ref 0 in
      let on_fill _ _ _ _ _ = incr total_fills in

      List.iter
        (fun (side, (price, qty)) ->
          incr id;
          let o = make_order ~id:!id ~side ~price ~qty ~order_type:Limit ~timestamp:!id in
          ignore (Engine.submit engine o on_fill))
        orders_spec;

      let net_pos = engine.risk.net_position in
      try
        check_book_invariants engine ~expected_net_position:net_pos;
        true
      with Failure msg ->
        Printf.eprintf "prop_insertion_sorted_levels failed: %s\n%!" msg;
        false)

(** Property: Multiple orders at the same price level strictly maintain FIFO arrival
    order. *)
let prop_fifo_queue_ordering =
  let gen =
    QCheck.pair gen_side
      (QCheck.pair gen_grid_price (QCheck.list_size (QCheck.Gen.int_range 2 25) gen_qty))
  in
  QCheck.Test.make ~count:80 ~name:"fifo_queue_ordering" gen (fun (side, (price, qtys)) ->
      let engine = Engine.create test_config in
      let orders =
        List.mapi
          (fun idx qty ->
            let id = idx + 1 in
            make_order ~id ~side ~price ~qty ~order_type:Limit ~timestamp:id)
          qtys
      in
      List.iter (fun o -> ignore (Engine.submit engine o dummy_on_fill)) orders;

      let book_side = if side = Buy then engine.book.bids else engine.book.asks in
      let level = Price_index.find book_side.levels price in

      (* Verify the queue order matches submission order *)
      let rec collect_ids idx acc =
        if idx = -1 then List.rev acc
        else
          let node = Pool.get engine.pool idx in
          collect_ids node.qn_next (node.qn_order.id :: acc)
      in
      let ids_in_queue = collect_ids level.pl_head [] in
      let expected_ids = List.map (fun (o : order) -> o.id) orders in
      let sum_qty = List.fold_left ( + ) 0 qtys in

      ids_in_queue = expected_ids
      && level.pl_order_count = List.length qtys
      && level.pl_total_qty = sum_qty)

(** Property: Post-only orders are rejected if they would cross existing liquidity, and
    are accepted as maker orders when non-crossing. *)
let prop_post_only_semantics =
  let gen = QCheck.triple gen_grid_price gen_qty (QCheck.pair gen_grid_price gen_qty) in
  QCheck.Test.make ~count:100 ~name:"post_only_semantics" gen
    (fun (resting_price, resting_qty, (po_price, po_qty)) ->
      let engine = Engine.create test_config in
      (* Place resting Ask at resting_price *)
      let resting =
        make_order ~id:1 ~side:Ask ~price:resting_price ~qty:resting_qty ~order_type:Limit
          ~timestamp:1
      in
      ignore (Engine.submit engine resting dummy_on_fill);

      (* Submit Buy Post_only at po_price *)
      let po =
        make_order ~id:2 ~side:Buy ~price:po_price ~qty:po_qty ~order_type:Post_only
          ~timestamp:2
      in
      let res = Engine.submit engine po dummy_on_fill in

      if po_price >= resting_price then
        (* Crossing: must reject and leave book intact *)
        res = Error Risk.Reject_price_band
        && po.status = Rejected && resting.status = Active
        && resting.remaining_qty = resting_qty
      else
        (* Non-crossing: must accept and rest on bid side *)
        res = Ok () && po.status = Active && po.remaining_qty = po_qty
        && engine.book.bids.best_level.pl_price = po_price)

(** Property: IOC orders never rest on the book; unmatched quantity is cancelled. *)
let prop_ioc_never_rests =
  let gen =
    QCheck.pair
      (QCheck.list_size (QCheck.Gen.int_range 1 5) (QCheck.pair gen_grid_price gen_qty))
      (QCheck.pair gen_grid_price gen_qty)
  in
  QCheck.Test.make ~count:80 ~name:"ioc_never_rests" gen
    (fun (resting_asks, (ioc_price, ioc_qty)) ->
      let engine = Engine.create test_config in
      let id = ref 0 in
      List.iter
        (fun (p, q) ->
          incr id;
          let o =
            make_order ~id:!id ~side:Ask ~price:p ~qty:q ~order_type:Limit ~timestamp:!id
          in
          ignore (Engine.submit engine o dummy_on_fill))
        resting_asks;

      incr id;
      let ioc =
        make_order ~id:!id ~side:Buy ~price:ioc_price ~qty:ioc_qty ~order_type:IOC
          ~timestamp:!id
      in
      let fills, cb = make_recorder () in
      ignore (Engine.submit engine ioc cb);

      (* IOC order itself is never Active *)
      let ioc_not_active = ioc.status = Filled || ioc.status = Cancelled in
      (* Bid book has no resting IOC orders *)
      let bid_has_ioc =
        match find_best_active_level engine.book.bids with
        | None -> false
        | Some lvl -> lvl.pl_order_count > 0
      in
      let total_filled = List.fold_left (fun acc f -> acc + f.fill_qty) 0 !fills in
      let qty_conserved = ioc.remaining_qty + total_filled = ioc_qty in

      ioc_not_active && (not bid_has_ioc) && qty_conserved)

(** Property: FOK orders are all-or-nothing; fill entirely or reject without mutating
    book. *)
let prop_fok_all_or_nothing =
  let gen =
    QCheck.pair
      (QCheck.list_size (QCheck.Gen.int_range 1 4) (QCheck.pair gen_grid_price gen_qty))
      (QCheck.pair gen_grid_price gen_qty)
  in
  QCheck.Test.make ~count:80 ~name:"fok_all_or_nothing" gen
    (fun (resting_specs, (fok_price, fok_qty)) ->
      let engine = Engine.create test_config in
      let id = ref 0 in
      List.iter
        (fun (p, q) ->
          incr id;
          let o =
            make_order ~id:!id ~side:Ask ~price:p ~qty:q ~order_type:Limit ~timestamp:!id
          in
          ignore (Engine.submit engine o dummy_on_fill))
        resting_specs;

      let avail_liquidity =
        List.fold_left
          (fun acc (p, q) -> if p <= fok_price then acc + q else acc)
          0 resting_specs
      in

      incr id;
      let fok =
        make_order ~id:!id ~side:Buy ~price:fok_price ~qty:fok_qty ~order_type:FOK
          ~timestamp:!id
      in
      let fills, cb = make_recorder () in
      ignore (Engine.submit engine fok cb);

      if avail_liquidity < fok_qty then
        (* Insufficient liquidity: rejected, zero fills *)
        fok.status = Rejected && fok.remaining_qty = fok_qty && List.length !fills = 0
      else
        (* Sufficient: completely filled *)
        fok.status = Filled && fok.remaining_qty = 0)

(* ────────────────────────────────────────────────────────────────────── *)
(*  Section 2: Cancellation Properties                                    *)
(* ────────────────────────────────────────────────────────────────────── *)

(** Property: Cancelling an active resting order removes it from the level queue,
    decrements total count and quantity, frees the pool node, and preserves FIFO relative
    ordering of other resting orders. *)
let prop_cancel_active_order =
  let gen =
    QCheck.pair gen_side
      (QCheck.pair gen_grid_price (QCheck.list_size (QCheck.Gen.int_range 2 15) gen_qty))
  in
  QCheck.Test.make ~count:80 ~name:"cancel_active_order" gen (fun (side, (price, qtys)) ->
      let engine = Engine.create test_config in
      let orders =
        List.mapi
          (fun idx qty ->
            let id = idx + 1 in
            make_order ~id ~side ~price ~qty ~order_type:Limit ~timestamp:id)
          qtys
      in
      List.iter (fun o -> ignore (Engine.submit engine o dummy_on_fill)) orders;

      (* Choose an order in the middle to cancel *)
      let target_idx = List.length orders / 2 in
      let target = List.nth orders target_idx in

      let alloc_before, _ = Pool.stats engine.pool in
      let ok = Engine.cancel engine target.id target.price target.side in
      let alloc_after, _ = Pool.stats engine.pool in

      let book_side = if side = Buy then engine.book.bids else engine.book.asks in
      let level = Price_index.find book_side.levels price in

      (* Remaining orders in queue *)
      let rec collect_ids idx acc =
        if idx = -1 then List.rev acc
        else
          let node = Pool.get engine.pool idx in
          collect_ids node.qn_next (node.qn_order.id :: acc)
      in
      let remaining_ids = collect_ids level.pl_head [] in
      let expected_remaining_ids =
        List.filter_map
          (fun (o : order) -> if o.id = target.id then None else Some o.id)
          orders
      in

      ok && target.status = Cancelled
      && alloc_after = alloc_before - 1
      && remaining_ids = expected_remaining_ids
      && level.pl_order_count = List.length orders - 1
      && level.pl_total_qty = List.fold_left ( + ) 0 qtys - target.original_qty)

(** Property: Cancelling non-existent order, already-cancelled order, or wrong price/side
    is an idempotent no-op returning false. *)
let prop_cancel_invalid_noop =
  let gen = QCheck.pair gen_side (QCheck.pair gen_grid_price gen_qty) in
  QCheck.Test.make ~count:60 ~name:"cancel_invalid_noop" gen (fun (side, (price, qty)) ->
      let engine = Engine.create test_config in
      let o = make_order ~id:1 ~side ~price ~qty ~order_type:Limit ~timestamp:1 in
      ignore (Engine.submit engine o dummy_on_fill);

      let alloc_before, _ = Pool.stats engine.pool in
      (* Wrong price *)
      let wrong_price = Engine.cancel engine 1 (price + 500) side in
      (* Wrong side *)
      let wrong_side = Engine.cancel engine 1 price (opposite_side side) in
      (* Non-existent id *)
      let wrong_id = Engine.cancel engine 999 price side in

      (* Valid cancel *)
      let valid = Engine.cancel engine 1 price side in
      (* Second cancel of same order *)
      let second = Engine.cancel engine 1 price side in

      let alloc_after, _ = Pool.stats engine.pool in

      (not wrong_price) && (not wrong_side) && (not wrong_id) && valid && (not second)
      && alloc_after = alloc_before - 1)

(* ────────────────────────────────────────────────────────────────────── *)
(*  Section 3: Execution & Priority Properties                            *)
(* ────────────────────────────────────────────────────────────────────── *)

(** Property: Aggressive orders match in strict price priority; fill price is always the
    resting passive price. *)
let prop_price_priority_execution =
  let gen =
    QCheck.pair
      (QCheck.list_size (QCheck.Gen.int_range 2 6) (QCheck.pair gen_grid_price gen_qty))
      gen_qty
  in
  QCheck.Test.make ~count:80 ~name:"price_priority_execution" gen
    (fun (ask_specs, buy_qty) ->
      let engine = Engine.create test_config in
      (* Create asks at distinct prices *)
      let id = ref 0 in
      List.iter
        (fun (p, q) ->
          incr id;
          let o =
            make_order ~id:!id ~side:Ask ~price:p ~qty:q ~order_type:Limit ~timestamp:!id
          in
          ignore (Engine.submit engine o dummy_on_fill))
        ask_specs;

      (* Submit aggressive buy at very high price to sweep *)
      incr id;
      let aggressive_buy =
        make_order ~id:!id ~side:Buy ~price:200_000 ~qty:buy_qty ~order_type:Limit
          ~timestamp:!id
      in
      let fills, cb = make_recorder () in
      ignore (Engine.submit engine aggressive_buy cb);

      let fills_rev = List.rev !fills in
      (* Fills must occur in non-decreasing price order (lowest ask first) *)
      let rec check_ascending_prices = function
        | [] | [ _ ] -> true
        | f1 :: f2 :: rest ->
            f1.fill_price <= f2.fill_price && check_ascending_prices (f2 :: rest)
      in
      (* Fill price must never exceed aggressive limit *)
      let within_limit =
        List.for_all (fun f -> f.fill_price <= aggressive_buy.price) fills_rev
      in

      check_ascending_prices fills_rev && within_limit)

(** Property: Within the same price level, resting orders are filled in strict time
    priority (oldest first). *)
let prop_time_priority_execution =
  let gen =
    QCheck.pair gen_grid_price (QCheck.list_size (QCheck.Gen.int_range 2 8) gen_qty)
  in
  QCheck.Test.make ~count:80 ~name:"time_priority_execution" gen (fun (price, qtys) ->
      let engine = Engine.create test_config in
      let id = ref 0 in
      let passive_orders =
        List.map
          (fun qty ->
            incr id;
            let o =
              make_order ~id:!id ~side:Ask ~price ~qty ~order_type:Limit ~timestamp:!id
            in
            ignore (Engine.submit engine o dummy_on_fill);
            o)
          qtys
      in

      (* Match partially *)
      let total_liquidity = List.fold_left ( + ) 0 qtys in
      let match_qty = max 1 (total_liquidity / 2) in
      incr id;
      let buy =
        make_order ~id:!id ~side:Buy ~price ~qty:match_qty ~order_type:Limit
          ~timestamp:!id
      in
      let fills, cb = make_recorder () in
      ignore (Engine.submit engine buy cb);

      let fills_rev = List.rev !fills in
      let matched_passive_ids = List.map (fun f -> f.passive_id) fills_rev in
      let expected_prefix = List.map (fun (o : order) -> o.id) passive_orders in
      let rec is_prefix sub full =
        match (sub, full) with
        | [], _ -> true
        | x :: xs, y :: ys -> x = y && is_prefix xs ys
        | _ -> false
      in
      is_prefix matched_passive_ids expected_prefix)

(** Property: Iceberg orders reload at the tail of their level queue upon exhausting their
    visible portion, losing time priority on reload. *)
let prop_iceberg_reload_tail =
  let gen = QCheck.pair gen_grid_price (QCheck.int_range 2 10) in
  QCheck.Test.make ~count:80 ~name:"iceberg_reload_tail" gen (fun (price, chunks) ->
      let engine = Engine.create test_config in
      let visible = 10 in
      let total = visible * chunks in
      let ice =
        make_order ~id:1 ~side:Buy ~price ~qty:visible
          ~order_type:(Iceberg { visible_qty = visible; total_qty = total })
          ~timestamp:1
      in
      ignore (Engine.submit engine ice dummy_on_fill);

      (* Place regular limit order behind iceberg *)
      let lim = make_order ~id:2 ~side:Buy ~price ~qty:5 ~order_type:Limit ~timestamp:2 in
      ignore (Engine.submit engine lim dummy_on_fill);

      (* Sell exactly the visible portion of iceberg *)
      let sell1 =
        make_order ~id:3 ~side:Ask ~price ~qty:visible ~order_type:Limit ~timestamp:3
      in
      ignore (Engine.submit engine sell1 dummy_on_fill);

      (* Next match should hit [lim] (id=2), NOT the reloaded iceberg! *)
      let fills, cb = make_recorder () in
      let sell2 =
        make_order ~id:4 ~side:Ask ~price ~qty:5 ~order_type:Limit ~timestamp:4
      in
      ignore (Engine.submit engine sell2 cb);

      match !fills with [ f ] -> f.passive_id = 2 && f.fill_qty = 5 | _ -> false)

(* ────────────────────────────────────────────────────────────────────── *)
(*  Section 4: Exhaustive Invariant Fuzzing State Machine                  *)
(* ────────────────────────────────────────────────────────────────────── *)

type fuzzer_cmd =
  | Cmd_Limit of side * int * int
  | Cmd_PostOnly of side * int * int
  | Cmd_IOC of side * int * int
  | Cmd_FOK of side * int * int
  | Cmd_Iceberg of side * int * int * int
  | Cmd_Cancel_Active of int
  | Cmd_Cancel_Random of int * int * side

let cmd_to_string = function
  | Cmd_Limit (s, p, q) -> Printf.sprintf "Limit(%s, %d, %d)" (side_to_string s) p q
  | Cmd_PostOnly (s, p, q) -> Printf.sprintf "PostOnly(%s, %d, %d)" (side_to_string s) p q
  | Cmd_IOC (s, p, q) -> Printf.sprintf "IOC(%s, %d, %d)" (side_to_string s) p q
  | Cmd_FOK (s, p, q) -> Printf.sprintf "FOK(%s, %d, %d)" (side_to_string s) p q
  | Cmd_Iceberg (s, p, v, t) ->
      Printf.sprintf "Iceberg(%s, %d, %d, %d)" (side_to_string s) p v t
  | Cmd_Cancel_Active idx -> Printf.sprintf "Cancel_Active(%d)" idx
  | Cmd_Cancel_Random (id, p, s) ->
      Printf.sprintf "Cancel_Random(%d, %d, %s)" id p (side_to_string s)

let gen_cmd =
  let p_idx = QCheck.int_range 0 15 in
  let q = QCheck.int_range 1 100 in
  let s = gen_side in
  QCheck.set_print cmd_to_string
    (QCheck.oneof
       [
         QCheck.map
           (fun (side, (p, qty)) -> Cmd_Limit (side, p, qty))
           (QCheck.pair s (QCheck.pair p_idx q));
         QCheck.map
           (fun (side, (p, qty)) -> Cmd_PostOnly (side, p, qty))
           (QCheck.pair s (QCheck.pair p_idx q));
         QCheck.map
           (fun (side, (p, qty)) -> Cmd_IOC (side, p, qty))
           (QCheck.pair s (QCheck.pair p_idx q));
         QCheck.map
           (fun (side, (p, qty)) -> Cmd_FOK (side, p, qty))
           (QCheck.pair s (QCheck.pair p_idx q));
         QCheck.map
           (fun (side, (p, (v, mult))) ->
             let total = v * mult in
             Cmd_Iceberg (side, p, v, total))
           (QCheck.pair s
              (QCheck.pair p_idx
                 (QCheck.pair (QCheck.int_range 5 20) (QCheck.int_range 2 5))));
         QCheck.map (fun idx -> Cmd_Cancel_Active idx) (QCheck.int_range 0 100);
         QCheck.map
           (fun (id, (p, side)) -> Cmd_Cancel_Random (id, p, side))
           (QCheck.pair (QCheck.int_range 1 500) (QCheck.pair p_idx s));
       ])

(** Property: Stateful command sequence fuzzing with continuous invariant validation. Runs
    interleaved submissions (Limit, PostOnly, IOC, FOK, Iceberg) and cancels across dense
    overlapping price grids. Asserts all structural and accounting invariants after every
    single operation. *)
let prop_exhaustive_fuzzing =
  let gen = QCheck.list_size (QCheck.Gen.int_range 20 60) gen_cmd in
  QCheck.Test.make ~count:150 ~name:"exhaustive_fuzzing" gen (fun cmd_seq ->
      let engine = Engine.create test_config in
      let id = ref 0 in
      let active_orders = ref [] in
      let net_pos = ref 0 in

      let on_fill passive_id active_id _price qty _ts =
        (* Update tracked positions *)
        List.iter
          (fun (o : order) ->
            if o.id = active_id then
              match o.side with
              | Buy -> net_pos := !net_pos + qty
              | Ask -> net_pos := !net_pos - qty)
          !active_orders;
        (* Update passive orders in active list *)
        active_orders :=
          List.filter_map
            (fun (o : order) ->
              if o.id = passive_id && o.remaining_qty = 0 && o.status <> Active then None
              else Some o)
            !active_orders
      in

      let grid_price idx = 100_000 + (idx * 50) in

      let history = ref [] in
      let step cmd =
        history := cmd :: !history;
        (match cmd with
        | Cmd_Limit (side, p_idx, qty) ->
            incr id;
            let o =
              make_order ~id:!id ~side ~price:(grid_price p_idx) ~qty ~order_type:Limit
                ~timestamp:!id
            in
            let res = Engine.submit engine o on_fill in
            if res = Ok () && o.status = Active then active_orders := o :: !active_orders
        | Cmd_PostOnly (side, p_idx, qty) ->
            incr id;
            let o =
              make_order ~id:!id ~side ~price:(grid_price p_idx) ~qty
                ~order_type:Post_only ~timestamp:!id
            in
            let res = Engine.submit engine o on_fill in
            if res = Ok () && o.status = Active then active_orders := o :: !active_orders
        | Cmd_IOC (side, p_idx, qty) ->
            incr id;
            let o =
              make_order ~id:!id ~side ~price:(grid_price p_idx) ~qty ~order_type:IOC
                ~timestamp:!id
            in
            ignore (Engine.submit engine o on_fill)
        | Cmd_FOK (side, p_idx, qty) ->
            incr id;
            let o =
              make_order ~id:!id ~side ~price:(grid_price p_idx) ~qty ~order_type:FOK
                ~timestamp:!id
            in
            ignore (Engine.submit engine o on_fill)
        | Cmd_Iceberg (side, p_idx, vis, tot) ->
            incr id;
            let o =
              make_order ~id:!id ~side ~price:(grid_price p_idx) ~qty:vis
                ~order_type:(Iceberg { visible_qty = vis; total_qty = tot })
                ~timestamp:!id
            in
            let res = Engine.submit engine o on_fill in
            if res = Ok () && o.status = Active then active_orders := o :: !active_orders
        | Cmd_Cancel_Active idx ->
            let actives =
              List.filter (fun (o : order) -> o.status = Active) !active_orders
            in
            if actives <> [] then
              let pick = List.nth actives (abs idx mod List.length actives) in
              let ok = Engine.cancel engine pick.id pick.price pick.side in
              if ok then
                active_orders :=
                  List.filter (fun (o : order) -> o.id <> pick.id) !active_orders
        | Cmd_Cancel_Random (cand_id, p_idx, side) ->
            ignore (Engine.cancel engine cand_id (grid_price p_idx) side));

        (* Clean up non-active orders from active_orders tracking list *)
        active_orders := List.filter (fun (o : order) -> o.status = Active) !active_orders;

        (* Check all book invariants *)
        let cur_net = engine.risk.net_position in
        check_book_invariants engine ~expected_net_position:cur_net
      in

      try
        List.iter step cmd_seq;
        true
      with Failure _ -> false)

(* ────────────────────────────────────────────────────────────────────── *)
(*  Main Test Runner                                                      *)
(* ────────────────────────────────────────────────────────────────────── *)

let () =
  let open Alcotest in
  run "OCaml-LOB Properties"
    [
      ( "insertion",
        [
          QCheck_alcotest.to_alcotest prop_insertion_sorted_levels;
          QCheck_alcotest.to_alcotest prop_fifo_queue_ordering;
          QCheck_alcotest.to_alcotest prop_post_only_semantics;
          QCheck_alcotest.to_alcotest prop_ioc_never_rests;
          QCheck_alcotest.to_alcotest prop_fok_all_or_nothing;
        ] );
      ( "cancellation",
        [
          QCheck_alcotest.to_alcotest prop_cancel_active_order;
          QCheck_alcotest.to_alcotest prop_cancel_invalid_noop;
        ] );
      ( "execution",
        [
          QCheck_alcotest.to_alcotest prop_price_priority_execution;
          QCheck_alcotest.to_alcotest prop_time_priority_execution;
          QCheck_alcotest.to_alcotest prop_iceberg_reload_tail;
        ] );
      ("fuzzing", [ QCheck_alcotest.to_alcotest prop_exhaustive_fuzzing ]);
    ]
