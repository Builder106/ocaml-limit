open Ocaml_lob

let dummy_order : Types.order = { id = 1; side = Types.Buy; price = 100; original_qty = 10; remaining_qty = 10; order_type = Types.Limit; status = Types.Active; timestamp = 0 }

let test_pool_exhaustion () =
  let p = Pool.create 2 in
  let _ = Pool.alloc p dummy_order in
  let _ = Pool.alloc p dummy_order in
  try
    let _ = Pool.alloc p dummy_order in
    Alcotest.fail "Expected pool exhaustion"
  with Failure _ -> ()

let test_pool_stats () =
  let p = Pool.create 10 in
  let _ = Pool.alloc p dummy_order in
  let util = Pool.utilization p in
  let alloc, cap = Pool.stats p in
  Alcotest.(check (float 0.001)) "utilization" 0.1 util;
  Alcotest.(check int) "alloc" 1 alloc;
  Alcotest.(check int) "cap" 10 cap

let test_types () =
  let side_b = Types.Buy in
  let side_s = Types.Ask in
  Alcotest.(check string) "buy string" "BUY" (Types.side_to_string side_b);
  Alcotest.(check string) "sell string" "ASK" (Types.side_to_string side_s);
  Alcotest.(check string) "active" "ACTIVE" (Types.status_to_string Types.Active);
  Alcotest.(check string) "filled" "FILLED" (Types.status_to_string Types.Filled);
  Alcotest.(check string) "cancelled" "CANCELLED" (Types.status_to_string Types.Cancelled);
  Alcotest.(check string) "rejected" "REJECTED" (Types.status_to_string Types.Rejected);
  Alcotest.(check bool) "opposite buy" true (Types.opposite_side side_b = Types.Ask);
  Alcotest.(check bool) "opposite ask" true (Types.opposite_side side_s = Types.Buy);
  Alcotest.(check (float 0.001)) "price float" 1.0 (Types.price_to_float 10000);
  Alcotest.(check int) "float price" 10000 (Types.float_to_price 1.0)

let test_messaging () =
  let q = Messaging.create () in
  Alcotest.(check (option int)) "empty pop" None (Messaging.pop q);
  Messaging.push q 1;
  Messaging.push q 2;
  Alcotest.(check (option int)) "pop 1" (Some 1) (Messaging.pop q);
  Alcotest.(check (option int)) "pop 2" (Some 2) (Messaging.pop q);
  Alcotest.(check (option int)) "empty pop again" None (Messaging.pop q)

let test_risk () =
  let config = { Types.max_orders = 100; tick_size = 1; min_price = 10; max_price = 100; max_order_qty = 50; max_position = 20 } in
  let tracker = { Risk.net_position = 0 } in
  let good_order = { Types.id = 1; side = Types.Buy; price = 50; original_qty = 10; remaining_qty = 10; order_type = Types.Limit; status = Types.Active; timestamp = 0 } in
  
  (* Price band *)
  let low_order = { good_order with price = 5 } in
  let high_order = { good_order with price = 105 } in
  Alcotest.(check bool) "reject low" true (Risk.check_price_band config low_order = Risk.Reject_price_band);
  Alcotest.(check bool) "reject high" true (Risk.check_price_band config high_order = Risk.Reject_price_band);
  Alcotest.(check bool) "pass low" true (Risk.check_price_band config good_order = Risk.Pass);

  (* Max qty *)
  let big_order = { good_order with remaining_qty = 100 } in
  Alcotest.(check bool) "reject big" true (Risk.check_max_qty config big_order = Risk.Reject_max_qty);
  
  (* Position limit *)
  let over_limit = { good_order with remaining_qty = 25 } in
  Alcotest.(check bool) "reject pos" true (Risk.check_position_limit config tracker over_limit = Risk.Reject_position_limit);
  Alcotest.(check bool) "pass pos" true (Risk.check_position_limit config tracker good_order = Risk.Pass);

  (* Ask side position limit (requires net_position < 0 eventually) *)
  let ask_order = { over_limit with side = Types.Ask } in
  Alcotest.(check bool) "reject ask pos" true (Risk.check_position_limit config tracker ask_order = Risk.Reject_position_limit);

  (* Full validate pipeline *)
  Alcotest.(check bool) "val max_qty" true (Risk.validate config tracker big_order = Risk.Reject_max_qty);
  Alcotest.(check bool) "val price" true (Risk.validate config tracker high_order = Risk.Reject_price_band);
  Alcotest.(check bool) "val pos" true (Risk.validate config tracker over_limit = Risk.Reject_position_limit);
  Alcotest.(check bool) "val pass" true (Risk.validate config tracker good_order = Risk.Pass);

  (* String repr *)
  Alcotest.(check string) "str pass" "PASS" (Risk.risk_result_to_string Risk.Pass);
  Alcotest.(check string) "str pb" "REJECTED: price outside configured band" (Risk.risk_result_to_string Risk.Reject_price_band);
  Alcotest.(check string) "str mq" "REJECTED: quantity exceeds maximum" (Risk.risk_result_to_string Risk.Reject_max_qty);
  Alcotest.(check string) "str pl" "REJECTED: would breach position limit" (Risk.risk_result_to_string Risk.Reject_position_limit)

let test_price_index () =
  let idx = Price_index.create 4 ~empty_value:0 in (* 2^2 capacity *)
  Price_index.add idx 1 10;
  Price_index.add idx 2 20;
  Price_index.add idx 3 30;
  Price_index.add idx 4 40;
  
  (* Overwrite *)
  Price_index.add idx 1 11;
  Alcotest.(check int) "find 1" 11 (Price_index.find idx 1);
  
  (* Missing key (should trigger find_aux collision skipping and not found) *)
  try
    let _ = Price_index.find idx 5 in
    Alcotest.fail "Expected Not_found"
  with Not_found -> ();

  (* Force collision and full-table Not_found on find_aux *)
  let idx2 = Price_index.create 4 ~empty_value:0 in
  for i = 1 to 15 do
    Price_index.add idx2 i (i * 10)
  done;
  (* Now table has 15 items, 1 empty slot. Finding a non-existent key will probe until empty slot. *)
  (try let _ = Price_index.find idx2 100 in () with Not_found -> ());
  
  (* Fill the last slot to make it 16/16 *)
  Price_index.add idx2 16 160;
  (* Now find a missing key on a full table, which triggers probes > mask *)
  (try let _ = Price_index.find idx2 100 in () with Not_found -> ());

  (* Exhaust capacity during add *)
  try
    for i = 5 to 20 do
      Price_index.add idx i (i * 10)
    done;
    Alcotest.fail "Expected capacity exceeded"
  with Failure _ -> ()

let test_stats () =
  let st = Stats.create 10 in
  Alcotest.(check (float 0.001)) "empty p99" 0.0 (Stats.get_percentile st 0.99);
  Stats.record st 1000;
  Stats.record st 2000;
  let p50 = Stats.get_percentile st 0.5 in
  Alcotest.(check bool) "p50 > 0" true (p50 > 0.0);
  
  st.Stats.start_time <- Unix.gettimeofday () +. 10.0; (* Force elapsed <= 0 *)
  Alcotest.(check (float 0.001)) "zero throughput" 0.0 (Stats.get_throughput st);
  
  st.Stats.start_time <- Unix.gettimeofday () -. 10.0; (* Force elapsed > 0 *)
  Alcotest.(check bool) "positive throughput" true (Stats.get_throughput st > 0.0);
  
  Stats.reset st;
  Alcotest.(check int) "reset" 0 st.Stats.lat_idx

let () =
  let open Alcotest in
  run "OCaml-LOB Internals" [
    "pool", [
      test_case "Exhaustion" `Quick test_pool_exhaustion;
      test_case "Stats" `Quick test_pool_stats;
    ];
    "types", [
      test_case "ToString" `Quick test_types;
    ];
    "messaging", [
      test_case "Queue" `Quick test_messaging;
    ];
    "risk", [
      test_case "Validation" `Quick test_risk;
    ];
    "price_index", [
      test_case "Index" `Quick test_price_index;
    ];
    "stats", [
      test_case "Stats" `Quick test_stats;
    ]
  ]
