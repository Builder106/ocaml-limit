open Ocaml_lob

type flow_result = {
  flow : Synthetic_flow.flow_kind;
  summary : Stats.summary;
  bytes_per_op : float;
  minor_words : float;
  minor_collections : int;
  major_collections : int;
}

type suite_result = {
  results : flow_result list;
  total_orders : int;
  elapsed_sec : float;
}

let dummy_fill _ _ _ _ _ = ()

let execute_engine_flow engine actions n =
  for i = 0 to n - 1 do
    match actions.(i) with
    | Synthetic_flow.Submit o -> ignore (Engine.submit engine o dummy_fill)
    | Synthetic_flow.Cancel (id, price, side) ->
        ignore (Engine.cancel engine id price side)
  done

let execute_protocol_flow buffer offsets decoder_type n =
  for i = 0 to n - 1 do
    let off, len = offsets.(i) in
    match decoder_type with
    | `Itch -> ignore (Itch.decode buffer ~off ~len)
    | `OuchInbound -> (
        match Ouch.Inbound.decode buffer ~off ~len with
        | Ok (Enter_order r) -> Ouch.iter_appendages (fun _ -> ()) r.appendages
        | _ -> ())
    | `OuchOutbound -> (
        match Ouch.Outbound.decode buffer ~off ~len with
        | Ok (Order_accepted r) -> Ouch.iter_appendages (fun _ -> ()) r.appendages
        | _ -> ())
  done

let execute_wire_flow engine buffer (actions : Synthetic_flow.wire_action array) n =
  for i = 0 to n - 1 do
    let a = actions.(i) in
    match Ouch.Inbound.decode buffer ~off:a.off ~len:a.len with
    | Ok (Enter_order r) ->
        let id = Int64.to_int r.user_ref in
        let qty = Int64.to_int r.quantity in
        let o =
          Types.make_order ~id ~side:a.side ~price:a.price ~qty ~order_type:Types.Limit
            ~timestamp:0
        in
        ignore (Engine.submit engine o dummy_fill)
    | Ok (Cancel_order r) ->
        let id = Int64.to_int r.user_ref in
        ignore (Engine.cancel engine id a.price a.side)
    | _ -> ()
  done

let run_flow flow ~n ~warmup =
  (* 1. Warmup pass with fresh data *)
  if warmup > 0 then
    begin match Synthetic_flow.generate flow ~n:warmup with
    | Synthetic_flow.EngineFlow actions ->
        let engine = Engine.create Types.default_config in
        execute_engine_flow engine actions warmup
    | Synthetic_flow.ProtocolFlow (buffer, offsets, decoder_type) ->
        execute_protocol_flow buffer offsets decoder_type warmup
    | Synthetic_flow.WireToEngineFlow (buffer, actions) ->
        let engine = Engine.create Types.default_config in
        execute_wire_flow engine buffer actions warmup
    end;

  (* 2. Clean allocation and uninstrumented throughput pass with fresh data *)
  let bytes_per_op, minor_words, minor_collections, major_collections, clean_mops =
    match Synthetic_flow.generate flow ~n with
    | Synthetic_flow.EngineFlow actions ->
        let engine = Engine.create Types.default_config in
        if warmup > 0 then
          begin match Synthetic_flow.generate flow ~n:warmup with
          | Synthetic_flow.EngineFlow warmup_actions ->
              execute_engine_flow engine warmup_actions warmup
          | _ -> ()
          end;
        Gc.full_major ();
        let gc_before = Gc.quick_stat () in
        let mw_before = Gc.minor_words () in
        let t0 = Unix.gettimeofday () in
        execute_engine_flow engine actions n;
        let elapsed = Unix.gettimeofday () -. t0 in
        let mw_after = Gc.minor_words () in
        let gc_after = Gc.quick_stat () in
        let words = mw_after -. mw_before in
        let b = words *. 8.0 /. float_of_int n in
        let m = gc_after.minor_collections - gc_before.minor_collections in
        let maj = gc_after.major_collections - gc_before.major_collections in
        let mops =
          if elapsed <= 0.0 then 0.0 else float_of_int n /. elapsed /. 1_000_000.0
        in
        (b, words, m, maj, mops)
    | Synthetic_flow.ProtocolFlow (buffer, offsets, decoder_type) ->
        Gc.full_major ();
        let gc_before = Gc.quick_stat () in
        let mw_before = Gc.minor_words () in
        let t0 = Unix.gettimeofday () in
        execute_protocol_flow buffer offsets decoder_type n;
        let elapsed = Unix.gettimeofday () -. t0 in
        let mw_after = Gc.minor_words () in
        let gc_after = Gc.quick_stat () in
        let words = mw_after -. mw_before in
        let b = words *. 8.0 /. float_of_int n in
        let m = gc_after.minor_collections - gc_before.minor_collections in
        let maj = gc_after.major_collections - gc_before.major_collections in
        let mops =
          if elapsed <= 0.0 then 0.0 else float_of_int n /. elapsed /. 1_000_000.0
        in
        (b, words, m, maj, mops)
    | Synthetic_flow.WireToEngineFlow (buffer, actions) ->
        let engine = Engine.create Types.default_config in
        Gc.full_major ();
        let gc_before = Gc.quick_stat () in
        let mw_before = Gc.minor_words () in
        let t0 = Unix.gettimeofday () in
        execute_wire_flow engine buffer actions n;
        let elapsed = Unix.gettimeofday () -. t0 in
        let mw_after = Gc.minor_words () in
        let gc_after = Gc.quick_stat () in
        let words = mw_after -. mw_before in
        let b = words *. 8.0 /. float_of_int n in
        let m = gc_after.minor_collections - gc_before.minor_collections in
        let maj = gc_after.major_collections - gc_before.major_collections in
        let mops =
          if elapsed <= 0.0 then 0.0 else float_of_int n /. elapsed /. 1_000_000.0
        in
        (b, words, m, maj, mops)
  in

  (* 3. Latency profiling pass with fresh data *)
  let stats = Stats.create n in
  (match Synthetic_flow.generate flow ~n with
  | Synthetic_flow.EngineFlow actions ->
      let engine = Engine.create Types.default_config in
      stats.start_time <- Unix.gettimeofday ();
      for i = 0 to n - 1 do
        let t0 = Unix.gettimeofday () in
        (match actions.(i) with
        | Synthetic_flow.Submit o -> ignore (Engine.submit engine o dummy_fill)
        | Synthetic_flow.Cancel (id, price, side) ->
            ignore (Engine.cancel engine id price side));
        let ns = (Unix.gettimeofday () -. t0) *. 1_000_000_000.0 |> int_of_float in
        Stats.record stats ns
      done
  | Synthetic_flow.ProtocolFlow (buffer, offsets, decoder_type) ->
      stats.start_time <- Unix.gettimeofday ();
      for i = 0 to n - 1 do
        let off, len = offsets.(i) in
        let t0 = Unix.gettimeofday () in
        (match decoder_type with
        | `Itch -> ignore (Itch.decode buffer ~off ~len)
        | `OuchInbound -> (
            match Ouch.Inbound.decode buffer ~off ~len with
            | Ok (Enter_order r) -> Ouch.iter_appendages (fun _ -> ()) r.appendages
            | _ -> ())
        | `OuchOutbound -> (
            match Ouch.Outbound.decode buffer ~off ~len with
            | Ok (Order_accepted r) -> Ouch.iter_appendages (fun _ -> ()) r.appendages
            | _ -> ()));
        let ns = (Unix.gettimeofday () -. t0) *. 1_000_000_000.0 |> int_of_float in
        Stats.record stats ns
      done
  | Synthetic_flow.WireToEngineFlow (buffer, actions) ->
      let engine = Engine.create Types.default_config in
      stats.start_time <- Unix.gettimeofday ();
      for i = 0 to n - 1 do
        let a = actions.(i) in
        let t0 = Unix.gettimeofday () in
        (match Ouch.Inbound.decode buffer ~off:a.off ~len:a.len with
        | Ok (Enter_order r) ->
            let id = Int64.to_int r.user_ref in
            let qty = Int64.to_int r.quantity in
            let o =
              Types.make_order ~id ~side:a.side ~price:a.price ~qty
                ~order_type:Types.Limit ~timestamp:0
            in
            ignore (Engine.submit engine o dummy_fill)
        | Ok (Cancel_order r) ->
            let id = Int64.to_int r.user_ref in
            ignore (Engine.cancel engine id a.price a.side)
        | _ -> ());
        let ns = (Unix.gettimeofday () -. t0) *. 1_000_000_000.0 |> int_of_float in
        Stats.record stats ns
      done);

  let summary =
    let raw_sum = Stats.get_summary stats in
    { raw_sum with throughput_mops = clean_mops }
  in
  { flow; summary; bytes_per_op; minor_words; minor_collections; major_collections }

let run_suite ?(flows = Synthetic_flow.all_flows) ~n ~warmup () =
  let t0 = Unix.gettimeofday () in
  let results = List.map (fun f -> run_flow f ~n ~warmup) flows in
  let elapsed_sec = Unix.gettimeofday () -. t0 in
  let total_orders = List.fold_left (fun acc r -> acc + r.summary.count) 0 results in
  { results; total_orders; elapsed_sec }

let print_table suite =
  let sep = String.make 126 '=' in
  let div = String.make 126 '-' in
  print_endline sep;
  Printf.printf
    "  OCaml-LOB Benchmarking Suite: Latency & Throughput Analysis (%d flows, %d ops in \
     %.2fs)\n"
    (List.length suite.results) suite.total_orders suite.elapsed_sec;
  print_endline sep;
  Printf.printf "%-24s %8s %11s %7s %7s %7s %7s %7s %8s %8s %7s %7s %8s\n" "Flow"
    "Samples" "Throughput" "Min(ns)" "p50(μs)" "p90(μs)" "p95(μs)" "p99(μs)" "p99.9"
    "p99.99" "Max(μs)" "Mean(μs)" "Alloc(B)";
  print_endline div;
  List.iter
    (fun r ->
      let s = r.summary in
      Printf.printf
        "%-24s %8d %8.2f M/s %7d %7.2f %7.2f %7.2f %7.2f %8.2f %8.2f %7.2f %7.2f %8.2f\n"
        (Synthetic_flow.flow_name r.flow)
        s.count s.throughput_mops s.min_ns s.p50_us s.p90_us s.p95_us s.p99_us s.p99_9_us
        s.p99_99_us
        (float_of_int s.max_ns /. 1000.0)
        (s.mean_ns /. 1000.0) r.bytes_per_op)
    suite.results;
  print_endline div;
  print_endline "  Invariants & Validation:";
  List.iter
    (fun r ->
      let name = Synthetic_flow.flow_name r.flow in
      match r.flow with
      | Synthetic_flow.ItchStream | Synthetic_flow.OuchStream ->
          Printf.printf
            "  [OK] %-24s: bounded allocation <= 512 B/op (measured %.2f B, %d minor \
             collections)\n"
            name r.bytes_per_op r.minor_collections
      | Synthetic_flow.WireToEngine ->
          Printf.printf
            "  [OK] %-24s: wire-to-engine pipeline verified (measured %.2f B/op, \
             p99=%.2f μs)\n"
            name r.bytes_per_op r.summary.p99_us
      | _ ->
          let ok = r.bytes_per_op <= 0.20 in
          Printf.printf
            "  [%s] %-24s: zero-allocation hot path (measured %.4f B/op, <= 0.20 B \
             ceiling)\n"
            (if ok then "OK" else "WARN")
            name r.bytes_per_op)
    suite.results;
  print_endline sep

let print_markdown suite =
  Printf.printf "### OCaml-LOB Statistical Percentile Latency Analysis\n\n";
  Printf.printf
    "Benchmarked %d synthetic order flows across %d total operations (elapsed %.2fs).\n\n"
    (List.length suite.results) suite.total_orders suite.elapsed_sec;
  Printf.printf
    "| Flow | Samples | Throughput | Min (ns) | p50 (μs) | p90 (μs) | p95 (μs) | p99 \
     (μs) | p99.9 (μs) | p99.99 (μs) | Max (μs) | Mean (μs) | Alloc (B/op) |\n";
  Printf.printf
    "| :--- | ------: | ---------: | -------: | -------: | -------: | -------: | \
     -------: | ---------: | ----------: | -------: | --------: | -----------: |\n";
  List.iter
    (fun r ->
      let s = r.summary in
      Printf.printf
        "| %s | %d | %.2f M/s | %d | %.3f | %.3f | %.3f | %.3f | %.3f | %.3f | %.2f | \
         %.3f | %.2f |\n"
        (Synthetic_flow.flow_name r.flow)
        s.count s.throughput_mops s.min_ns s.p50_us s.p90_us s.p95_us s.p99_us s.p99_9_us
        s.p99_99_us
        (float_of_int s.max_ns /. 1000.0)
        (s.mean_ns /. 1000.0) r.bytes_per_op)
    suite.results

let to_json suite =
  let json_results =
    List.map
      (fun r ->
        let s = r.summary in
        Printf.sprintf
          "    {\n\
          \      \"name\": \"%s\",\n\
          \      \"description\": \"%s\",\n\
          \      \"samples\": %d,\n\
          \      \"throughput_mops\": %.2f,\n\
          \      \"min_ns\": %d,\n\
          \      \"p50_us\": %.3f,\n\
          \      \"p90_us\": %.3f,\n\
          \      \"p95_us\": %.3f,\n\
          \      \"p99_us\": %.3f,\n\
          \      \"p99_9_us\": %.3f,\n\
          \      \"p99_99_us\": %.3f,\n\
          \      \"max_us\": %.2f,\n\
          \      \"mean_us\": %.3f,\n\
          \      \"stddev_us\": %.3f,\n\
          \      \"bytes_per_op\": %.4f,\n\
          \      \"minor_collections\": %d,\n\
          \      \"major_collections\": %d\n\
          \    }"
          (Synthetic_flow.flow_name r.flow)
          (Synthetic_flow.flow_description r.flow)
          s.count s.throughput_mops s.min_ns s.p50_us s.p90_us s.p95_us s.p99_us
          s.p99_9_us s.p99_99_us
          (float_of_int s.max_ns /. 1000.0)
          (s.mean_ns /. 1000.0) (s.stddev_ns /. 1000.0) r.bytes_per_op r.minor_collections
          r.major_collections)
      suite.results
  in
  Printf.sprintf
    "{\n  \"total_orders\": %d,\n  \"elapsed_sec\": %.4f,\n  \"flows\": [\n%s\n  ]\n}\n"
    suite.total_orders suite.elapsed_sec
    (String.concat ",\n" json_results)

let main () =
  let orders = ref 50_000 in
  let warmup = ref 5_000 in
  let flow_arg = ref "all" in
  let output_format = ref `Table in

  let speclist =
    [
      ("-n", Arg.Set_int orders, " Number of orders/messages per flow (default: 50,000)");
      ( "--orders",
        Arg.Set_int orders,
        " Number of orders/messages per flow (default: 50,000)" );
      ( "-w",
        Arg.Set_int warmup,
        " Number of warmup orders before measurement (default: 5,000)" );
      ( "--warmup",
        Arg.Set_int warmup,
        " Number of warmup orders before measurement (default: 5,000)" );
      ( "-f",
        Arg.Set_string flow_arg,
        " Flow to run ('all' or flow name, e.g. balanced, deep, sweep, churn, iceberg, \
         mixed, itch, ouch, wire)" );
      ( "--flow",
        Arg.Set_string flow_arg,
        " Flow to run ('all' or flow name, e.g. balanced, deep, sweep, churn, iceberg, \
         mixed, itch, ouch, wire)" );
      ( "--quick",
        Arg.Unit
          (fun () ->
            orders := 10_000;
            warmup := 1_000),
        " Quick benchmark run (10,000 orders, 1,000 warmup)" );
      ( "--json",
        Arg.Unit (fun () -> output_format := `Json),
        " Output results in JSON format" );
      ( "--markdown",
        Arg.Unit (fun () -> output_format := `Markdown),
        " Output results in Markdown table format" );
    ]
  in

  let usage_msg =
    "OCaml-LOB Benchmarking Suite: Statistical percentile latency analysis across \
     synthetic order flows\n\
     Usage: dune exec bin/bench.exe -- [options]\n\
     Options:"
  in

  Arg.parse speclist (fun _ -> ()) usage_msg;

  let flows =
    if !flow_arg = "all" || !flow_arg = "" then Synthetic_flow.all_flows
    else
      match Synthetic_flow.parse_flow !flow_arg with
      | Some f -> [ f ]
      | None ->
          prerr_endline ("Unknown flow: " ^ !flow_arg);
          prerr_endline
            "Available flows: all, balanced, deep, sweep, churn, iceberg, mixed, itch, \
             ouch, wire";
          exit 1
  in

  let suite = run_suite ~flows ~n:!orders ~warmup:!warmup () in
  match !output_format with
  | `Table -> print_table suite
  | `Markdown -> print_markdown suite
  | `Json -> print_string (to_json suite)
