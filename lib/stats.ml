(** {1 Performance Statistics & Latency Tracking}

    Tracks execution latency and throughput using nanosecond-resolution timers. Optimized
    for zero-allocation recording. *)

type t = {
  mutable total_orders : int;
  mutable start_time : float;
  latencies : int array; (* Array of latencies in nanoseconds *)
  mutable lat_idx : int;
}

let create capacity =
  {
    total_orders = 0;
    start_time = Unix.gettimeofday ();
    latencies = Array.make capacity 0;
    lat_idx = 0;
  }

let record (t : t) ns =
  t.total_orders <- t.total_orders + 1;
  if t.lat_idx < Array.length t.latencies then (
    t.latencies.(t.lat_idx) <- ns;
    t.lat_idx <- t.lat_idx + 1)

let record_us t us = record t (int_of_float (us *. 1000.0))

let record_timing t f =
  let t0 = Unix.gettimeofday () in
  let res = f () in
  let ns = (Unix.gettimeofday () -. t0) *. 1_000_000_000.0 |> int_of_float in
  record t ns;
  res

let count (t : t) = t.lat_idx
let total_orders (t : t) = t.total_orders

let elapsed_sec (t : t) =
  let elapsed = Unix.gettimeofday () -. t.start_time in
  if elapsed <= 0.0 then 0.0 else elapsed

let get_throughput (t : t) =
  let elapsed = elapsed_sec t in
  if elapsed <= 0.0 then 0.0
  else float_of_int t.total_orders /. elapsed /. 1_000_000.0 (* M orders/s *)

let reset (t : t) =
  t.total_orders <- 0;
  t.start_time <- Unix.gettimeofday ();
  t.lat_idx <- 0

let sorted_latencies (t : t) =
  if t.lat_idx = 0 then [||]
  else
    let sorted = Array.sub t.latencies 0 t.lat_idx in
    Array.sort compare sorted;
    sorted

let percentile_ns_from_sorted sorted p =
  let len = Array.length sorted in
  if len = 0 then 0
  else
    let idx = float_of_int (len - 1) *. p |> int_of_float in
    let clamped = max 0 (min (len - 1) idx) in
    sorted.(clamped)

let get_percentile (t : t) p =
  if t.lat_idx = 0 then 0.0
  else float_of_int (percentile_ns_from_sorted (sorted_latencies t) p) /. 1000.0

let percentile_ns (t : t) p =
  if t.lat_idx = 0 then 0 else percentile_ns_from_sorted (sorted_latencies t) p

let min_ns (t : t) = if t.lat_idx = 0 then 0 else (sorted_latencies t).(0)

let max_ns (t : t) =
  if t.lat_idx = 0 then 0
  else
    let s = sorted_latencies t in
    s.(Array.length s - 1)

let mean_ns (t : t) =
  if t.lat_idx = 0 then 0.0
  else
    let sum = ref 0.0 in
    for i = 0 to t.lat_idx - 1 do
      sum := !sum +. float_of_int t.latencies.(i)
    done;
    !sum /. float_of_int t.lat_idx

let stddev_ns (t : t) =
  if t.lat_idx <= 1 then 0.0
  else
    let m = mean_ns t in
    let sum_sq = ref 0.0 in
    for i = 0 to t.lat_idx - 1 do
      let diff = float_of_int t.latencies.(i) -. m in
      sum_sq := !sum_sq +. (diff *. diff)
    done;
    sqrt (!sum_sq /. float_of_int t.lat_idx)

type summary = {
  count : int;
  total_orders : int;
  min_ns : int;
  max_ns : int;
  mean_ns : float;
  stddev_ns : float;
  p50_us : float;
  p90_us : float;
  p95_us : float;
  p99_us : float;
  p99_9_us : float;
  p99_99_us : float;
  throughput_mops : float;
  elapsed_sec : float;
}

let get_summary (t : t) =
  let n = t.lat_idx in
  let elapsed = elapsed_sec t in
  let throughput = get_throughput t in
  if n = 0 then
    {
      count = 0;
      total_orders = t.total_orders;
      min_ns = 0;
      max_ns = 0;
      mean_ns = 0.0;
      stddev_ns = 0.0;
      p50_us = 0.0;
      p90_us = 0.0;
      p95_us = 0.0;
      p99_us = 0.0;
      p99_9_us = 0.0;
      p99_99_us = 0.0;
      throughput_mops = throughput;
      elapsed_sec = elapsed;
    }
  else
    let sorted = sorted_latencies t in
    let min_lat = sorted.(0) in
    let max_lat = sorted.(n - 1) in
    let m = mean_ns t in
    let s = stddev_ns t in
    let p pval = float_of_int (percentile_ns_from_sorted sorted pval) /. 1000.0 in
    {
      count = n;
      total_orders = t.total_orders;
      min_ns = min_lat;
      max_ns = max_lat;
      mean_ns = m;
      stddev_ns = s;
      p50_us = p 0.50;
      p90_us = p 0.90;
      p95_us = p 0.95;
      p99_us = p 0.99;
      p99_9_us = p 0.999;
      p99_99_us = p 0.9999;
      throughput_mops = throughput;
      elapsed_sec = elapsed;
    }

let table_header () =
  Printf.sprintf "%-22s %8s %10s %8s %8s %8s %8s %8s %9s %9s %8s %8s" "Flow" "Samples"
    "Throughput" "Min(ns)" "p50(μs)" "p90(μs)" "p95(μs)" "p99(μs)" "p99.9(μs)"
    "p99.99(μs)" "Max(μs)" "Mean(μs)"

let table_row name (s : summary) =
  Printf.sprintf "%-22s %8d %8.2f M/s %8d %8.2f %8.2f %8.2f %8.2f %9.2f %9.2f %8.2f %8.2f"
    name s.count s.throughput_mops s.min_ns s.p50_us s.p90_us s.p95_us s.p99_us s.p99_9_us
    s.p99_99_us
    (float_of_int s.max_ns /. 1000.0)
    (s.mean_ns /. 1000.0)

let format_summary name (s : summary) =
  Printf.sprintf
    "--- %s ---\n\
     Samples:     %d (Total Orders: %d)\n\
     Throughput:  %.2f M ops/sec (Elapsed: %.4fs)\n\
     Latency Min: %d ns\n\
     Latency p50: %.3f μs\n\
     Latency p90: %.3f μs\n\
     Latency p95: %.3f μs\n\
     Latency p99: %.3f μs\n\
     Latency p99.9:  %.3f μs\n\
     Latency p99.99: %.3f μs\n\
     Latency Max: %d ns (%.3f μs)\n\
     Mean ± Dev:  %.3f μs ± %.3f μs\n"
    name s.count s.total_orders s.throughput_mops s.elapsed_sec s.min_ns s.p50_us s.p90_us
    s.p95_us s.p99_us s.p99_9_us s.p99_99_us s.max_ns
    (float_of_int s.max_ns /. 1000.0)
    (s.mean_ns /. 1000.0) (s.stddev_ns /. 1000.0)
