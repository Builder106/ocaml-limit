open Bench_suite

let check_bool = Alcotest.(check bool)
let check_int = Alcotest.(check int)

let test_flow_parsing () =
  let test_case (raw, expected) =
    match Synthetic_flow.parse_flow raw with
    | Some f -> check_bool ("parse " ^ raw) true (f = expected)
    | None -> Alcotest.fail ("failed to parse flow: " ^ raw)
  in
  List.iter test_case
    [
      ("balanced", Synthetic_flow.BalancedTwoSided);
      ("two_sided", Synthetic_flow.BalancedTwoSided);
      ("Balanced Two-Sided", Synthetic_flow.BalancedTwoSided);
      ("deep", Synthetic_flow.DeepBookLadder);
      ("ladder", Synthetic_flow.DeepBookLadder);
      ("deep_book", Synthetic_flow.DeepBookLadder);
      ("sweep", Synthetic_flow.AggressiveSweep);
      ("aggressive", Synthetic_flow.AggressiveSweep);
      ("churn", Synthetic_flow.CancelChurn);
      ("cancel", Synthetic_flow.CancelChurn);
      ("iceberg", Synthetic_flow.IcebergReplenish);
      ("replenish", Synthetic_flow.IcebergReplenish);
      ("mixed", Synthetic_flow.MixedRealistic);
      ("realistic", Synthetic_flow.MixedRealistic);
      ("itch", Synthetic_flow.ItchStream);
      ("itch50", Synthetic_flow.ItchStream);
      ("ouch", Synthetic_flow.OuchStream);
      ("ouch50", Synthetic_flow.OuchStream);
      ("wire", Synthetic_flow.WireToEngine);
      ("e2e", Synthetic_flow.WireToEngine);
      ("wire_to_engine", Synthetic_flow.WireToEngine);
    ];
  check_bool "unknown flow returns None" true
    (Synthetic_flow.parse_flow "invalid_nonexistent_flow" = None)

let test_synthetic_flow_execution flow () =
  let n = 20_000 in
  let warmup = 1_000 in
  let result = run_flow flow ~n ~warmup in
  let s = result.summary in
  let name = Synthetic_flow.flow_name flow in

  (* Samples match *)
  check_int (name ^ " samples") n s.count;

  (* Monotonicity of statistical percentiles *)
  check_bool (name ^ " min <= max") true (s.min_ns <= s.max_ns);
  check_bool (name ^ " p50 <= p90") true (s.p50_us <= s.p90_us);
  check_bool (name ^ " p90 <= p95") true (s.p90_us <= s.p95_us);
  check_bool (name ^ " p95 <= p99") true (s.p95_us <= s.p99_us);
  check_bool (name ^ " p99 <= p99.9") true (s.p99_us <= s.p99_9_us);
  check_bool (name ^ " p99.9 <= p99.99") true (s.p99_9_us <= s.p99_99_us);

  let p99_99_ns = int_of_float (s.p99_99_us *. 1000.0) in
  check_bool (name ^ " p99.99 <= max") true (p99_99_ns <= s.max_ns);

  (* Latency ceiling: p99 <= 100.0 μs (generous CI-safe ceiling) *)
  check_bool
    (name ^ " p99 <= 100μs (measured " ^ string_of_float s.p99_us ^ "μs)")
    true (s.p99_us <= 100.0);

  (* Throughput floor: >= 0.40 Mops/s (CI floor) *)
  check_bool
    (name ^ " throughput >= 0.40 M/s (measured "
    ^ string_of_float s.throughput_mops
    ^ " M/s)")
    true (s.throughput_mops >= 0.40);

  (* Memory allocation invariants *)
  match flow with
  | Synthetic_flow.ItchStream | Synthetic_flow.OuchStream ->
      check_bool
        (name ^ " bounded wire decode allocation <= 512 B/op")
        true
        (result.bytes_per_op <= 512.0)
  | Synthetic_flow.WireToEngine ->
      check_bool
        (name ^ " wire-to-engine pipeline allocation <= 512 B/op")
        true
        (result.bytes_per_op <= 512.0)
  | _ ->
      check_bool
        (name ^ " matching core zero-allocation hot path (measured "
        ^ string_of_float result.bytes_per_op
        ^ " B/op)")
        true (result.bytes_per_op <= 0.20)

let test_reporting_formats () =
  let suite =
    run_suite ~flows:[ Synthetic_flow.BalancedTwoSided ] ~n:1_000 ~warmup:100 ()
  in
  let json_str = to_json suite in
  check_bool "json non-empty" true (String.length json_str > 0);
  check_bool "json contains total_orders" true (String.contains json_str 't');

  (* Verify print_table and print_markdown don't raise *)
  print_table suite;
  print_markdown suite

let () =
  let flow_tests =
    List.map
      (fun f ->
        let name = Synthetic_flow.flow_name f in
        Alcotest.test_case name `Quick (test_synthetic_flow_execution f))
      Synthetic_flow.all_flows
  in
  Alcotest.run "benchmarking suite"
    [
      ("flow_parsing", [ Alcotest.test_case "parse_flow" `Quick test_flow_parsing ]);
      ("synthetic_flows", flow_tests);
      ("reporting", [ Alcotest.test_case "table_and_json" `Quick test_reporting_formats ]);
    ]
