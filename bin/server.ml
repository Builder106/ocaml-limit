(** {1 Live Demo Server}

    A [Dream] server that runs one matching engine, keeps it busy with a demo bot, and
    streams the book to the dashboard over Server-Sent Events. Visitors submit orders with
    [POST /order]. Nothing here runs on the benchmarked hot path; the server only calls
    [Engine.submit] and [Engine.cancel] like any other client. *)

open Ocaml_lob
open Types

(** {2 Limits}

    [Price_index] never removes a level, and the node pool is fixed at startup. A demo
    that runs for weeks must therefore bound both the prices it touches and the orders it
    leaves resting. An unbounded mid-price walk once filled the price table and hung the
    old VM (see JOURNAL, 2026-05-10). *)

let mid_price_initial = 1_502_500 (* $150.25 in ticks *)
let mid_drift_bound = 300
let visitor_price_band = 1_000 (* visitors may quote within ±$0.10 of the mid *)
let visitor_max_qty = 5_000
let max_resting_per_side = 120

(* The bot quotes on a ladder of [grid] ticks ($0.005) so orders queue at each price. *)
let grid = 50
let snapshot_levels = 12
let snapshot_orders_per_level = 48

(** {2 Counters} *)

type counters = {
  mutable orders_in : int;
  mutable trades : int;
  mutable volume : int;
  mutable last_price : price;
  mutable rejected : int;
}

let counters = { orders_in = 0; trades = 0; volume = 0; last_price = 0; rejected = 0 }

(** {2 Host Measurement}

    The dashboard reports throughput measured on the machine that serves it, using the
    workload from [test/perf_test.ml]: alternating buys and asks over 100 prices. Each
    trial gets fresh orders because [Engine.submit] mutates them. *)

type host_measure = { mops : float; bytes_per_order : float }

let measure_host () =
  let n = 200_000 in
  let fresh_orders () =
    Array.init n (fun i ->
        let side = if i mod 2 = 0 then Buy else Ask in
        make_order ~id:i ~side
          ~price:(100_000 + (i mod 100))
          ~qty:10 ~order_type:Limit ~timestamp:0)
  in
  let no_fill _ _ _ _ _ = () in
  let trial () =
    let engine = Engine.create default_config in
    let orders = fresh_orders () in
    let words_before = Gc.minor_words () in
    let t0 = Unix.gettimeofday () in
    for i = 0 to n - 1 do
      ignore (Engine.submit engine orders.(i) no_fill)
    done;
    let elapsed = Unix.gettimeofday () -. t0 in
    let words = Gc.minor_words () -. words_before in
    (float_of_int n /. elapsed /. 1_000_000.0, words *. 8.0 /. float_of_int n)
  in
  let results = [ trial (); trial (); trial () ] in
  let mops = List.fold_left (fun acc (m, _) -> Float.max acc m) 0.0 results in
  let bytes_per_order =
    List.fold_left (fun acc (_, b) -> Float.min acc b) infinity results
  in
  { mops; bytes_per_order }

(** {2 Fan-out Ring}

    Fills are serialized once and written into a fixed-size ring keyed by a monotonic
    sequence number. Each SSE client reads the ring inside its own loop, so every write to
    a socket is awaited by the task that owns it. The earlier fire-and-forget broadcast
    queued frames for closed WebSockets and wedged [gluten_lwt] (see JOURNAL, 2026-05-11).
    A client that lags more than [ring_size] fills loses the oldest. *)

let ring_size = 256

type ring = { buf : string array; mutable seq : int }

let trade_ring = { buf = Array.make ring_size ""; seq = 0 }

let push_ring r s =
  r.buf.(r.seq mod ring_size) <- s;
  r.seq <- r.seq + 1

let active_clients = ref 0
let wire_side = function Buy -> "BUY" | Ask -> "SELL"

let on_fill ~aggressor passive_id active_id price qty _ts =
  counters.trades <- counters.trades + 1;
  counters.volume <- counters.volume + qty;
  counters.last_price <- price;
  `Assoc
    [
      ("type", `String "TRADE");
      ("side", `String (wire_side aggressor));
      ("price", `Int price);
      ("qty", `Int qty);
      ("passive", `Int passive_id);
      ("active", `Int active_id);
      ("t", `Float (Unix.gettimeofday ()));
    ]
  |> Yojson.Safe.to_string |> push_ring trade_ring

let submit engine order =
  counters.orders_in <- counters.orders_in + 1;
  let result = Engine.submit engine order (on_fill ~aggressor:order.side) in
  if Result.is_error result then counters.rejected <- counters.rejected + 1;
  result

(** {2 Book Snapshot}

    Walks each side from the best level outward and emits every level's FIFO queue, oldest
    order first, as [[id, remaining_qty]] pairs. Empty levels left behind by the engine's
    lazy-keep policy are skipped. *)

let side_book (engine : Engine.t) = function
  | Buy -> engine.book.bids
  | Ask -> engine.book.asks

let level_queue (engine : Engine.t) level =
  let rec walk idx n acc =
    if idx = -1 || n = snapshot_orders_per_level then List.rev acc
    else
      let node = Pool.get engine.pool idx in
      let o = node.qn_order in
      walk node.qn_next (n + 1) (`List [ `Int o.id; `Int o.remaining_qty ] :: acc)
  in
  walk level.pl_head 0 []

let side_to_json engine side =
  let rec walk lvl n acc =
    if lvl == sentinel_level || n = snapshot_levels then List.rev acc
    else if lvl.pl_order_count = 0 then walk lvl.pl_next_level n acc
    else
      let level =
        `Assoc
          [
            ("price", `Int lvl.pl_price);
            ("qty", `Int lvl.pl_total_qty);
            ("count", `Int lvl.pl_order_count);
            ("orders", `List (level_queue engine lvl));
          ]
      in
      walk lvl.pl_next_level (n + 1) (level :: acc)
  in
  `List (walk (side_book engine side).best_level 0 [])

let book_json engine =
  `Assoc
    [
      ("type", `String "BOOK");
      ("asks", side_to_json engine Ask);
      ("bids", side_to_json engine Buy);
    ]
  |> Yojson.Safe.to_string

let stats_json host =
  `Assoc
    [
      ("type", `String "STATS");
      ("orders", `Int counters.orders_in);
      ("trades", `Int counters.trades);
      ("volume", `Int counters.volume);
      ("rejected", `Int counters.rejected);
      ("last", if counters.last_price = 0 then `Null else `Int counters.last_price);
      ("viewers", `Int !active_clients);
      ("host_mops", `Float host.mops);
      ("host_bytes_per_order", `Float host.bytes_per_order);
    ]
  |> Yojson.Safe.to_string

(** {2 Demo Bot}

    A market maker and an aggressor keep the book moving so visitors land on a live
    market. Every order goes through [Engine.submit] like a visitor's. *)

let bot_next_id = ref 1_000_000_000 (* above the visitor id space *)
let visitor_next_id = ref 0
let mid_price = ref mid_price_initial

let next_id r =
  incr r;
  !r

let bot_order engine ~side ~price ~qty =
  let order =
    make_order ~id:(next_id bot_next_id) ~side ~price ~qty ~order_type:Limit ~timestamp:0
  in
  ignore (submit engine order)

let rec resting_orders lvl acc =
  if lvl == sentinel_level then acc
  else resting_orders lvl.pl_next_level (acc + lvl.pl_order_count)

let rec worst_nonempty lvl found =
  if lvl == sentinel_level then found
  else worst_nonempty lvl.pl_next_level (if lvl.pl_order_count > 0 then lvl else found)

(* Cancel the oldest order at the farthest level once a side holds more than
   [max_resting_per_side] orders, so resting quotes cannot exhaust the node pool. *)
let trim_side (engine : Engine.t) side =
  let book = side_book engine side in
  if resting_orders book.best_level 0 > max_resting_per_side then
    let lvl = worst_nonempty book.best_level sentinel_level in
    if lvl != sentinel_level && lvl.pl_head <> -1 then
      let head = Pool.get engine.pool lvl.pl_head in
      ignore (Engine.cancel engine head.qn_order.id lvl.pl_price side)

(* Action mix: 55% cross the spread (fills), 35% rest a quote (depth), 10% step the
   mid one rung within [mid_drift_bound]. *)
let bot_step engine =
  let action = Random.float 1.0 in
  let side = if Random.bool () then Buy else Ask in
  if action < 0.55 then
    let cross = grid * (1 + Random.int 3) in
    let price = match side with Buy -> !mid_price + cross | Ask -> !mid_price - cross in
    bot_order engine ~side ~price ~qty:(20 + Random.int 180)
  else if action < 0.90 then
    let offset = grid * (1 + Random.int 10) in
    let price =
      match side with Buy -> !mid_price - offset | Ask -> !mid_price + offset
    in
    bot_order engine ~side ~price ~qty:(100 + Random.int 600)
  else
    let low = mid_price_initial - mid_drift_bound in
    let high = mid_price_initial + mid_drift_bound in
    let step = if Random.bool () then grid else -grid in
    mid_price := max low (min high (!mid_price + step))

let rec run_bot engine =
  let%lwt () = Lwt_unix.sleep (0.4 +. Random.float 0.6) in
  (try
     bot_step engine;
     trim_side engine Buy;
     trim_side engine Ask
   with exn -> prerr_endline ("[demo bot] step failed: " ^ Printexc.to_string exn));
  run_bot engine

let seed_book engine =
  for i = 1 to 15 do
    bot_order engine ~side:Buy ~price:(!mid_price - (i * grid)) ~qty:(200 + Random.int 800);
    bot_order engine ~side:Ask ~price:(!mid_price + (i * grid)) ~qty:(200 + Random.int 800)
  done

(** {2 Visitor Orders} *)

let json_response ?(status = `OK) body =
  Dream.respond ~status ~headers:[ ("Content-Type", "application/json") ] body

let error_response reason =
  `Assoc [ ("status", `String "error"); ("reason", `String reason) ]
  |> Yojson.Safe.to_string
  |> json_response ~status:`Bad_Request

let reject_reason = function
  | Risk.Reject_price_band -> "price band"
  | Risk.Reject_max_qty -> "order size"
  | Risk.Reject_position_limit -> "position limit"
  | Risk.Pass -> "none"

let place_order engine request =
  let%lwt body = Dream.body request in
  let open Yojson.Safe.Util in
  match
    let json = Yojson.Safe.from_string body in
    let side =
      match json |> member "side" |> to_string with
      | "BUY" -> Buy
      | "SELL" -> Ask
      | _ -> raise (Type_error ("side", json))
    in
    (side, json |> member "price" |> to_int, json |> member "qty" |> to_int)
  with
  | exception (Yojson.Json_error _ | Type_error _) ->
      error_response "expected {side: BUY|SELL, price: ticks, qty}"
  | _, _, qty when qty < 1 || qty > visitor_max_qty ->
      error_response (Printf.sprintf "qty must be 1 to %d" visitor_max_qty)
  | _, price, _ when price mod grid <> 0 ->
      error_response "price must be a multiple of 0.0050"
  | _, price, _ when abs (price - !mid_price) > visitor_price_band ->
      error_response
        (Printf.sprintf "price must be within %.4f of the mid, %.4f"
           (price_to_float visitor_price_band)
           (price_to_float !mid_price))
  | side, price, qty ->
      let id = next_id visitor_next_id in
      let order = make_order ~id ~side ~price ~qty ~order_type:Limit ~timestamp:0 in
      let status =
        match submit engine order with
        | Ok () -> "ok"
        | Error r -> "rejected: " ^ reject_reason r
      in
      `Assoc
        [
          ("status", `String status);
          ("id", `Int id);
          ("filled", `Int (qty - order.remaining_qty));
          ("resting", `Int (if order.status = Active then order.remaining_qty else 0));
        ]
      |> Yojson.Safe.to_string |> json_response

(** {2 Event Stream}

    Each client gets the book and counters every 500 ms, followed by any fills since its
    last read. SSE runs over plain chunked HTTP; its close path never reaches the
    [gluten_lwt] WebSocket write loop that used to spin (JOURNAL, 2026-05-11). *)

let events engine host _request =
  Dream.stream
    ~headers:
      [
        ("Content-Type", "text/event-stream");
        ("Cache-Control", "no-cache");
        (* Stop reverse proxies from buffering the stream. *)
        ("X-Accel-Buffering", "no");
      ]
    (fun stream ->
      incr active_clients;
      let last_seq = ref (max 0 (trade_ring.seq - 20)) in
      let send payload =
        let%lwt () = Dream.write stream ("data: " ^ payload ^ "\n\n") in
        Dream.flush stream
      in
      let rec drain () =
        if !last_seq >= trade_ring.seq then Lwt.return_unit
        else (
          if trade_ring.seq - !last_seq > ring_size then
            last_seq := trade_ring.seq - ring_size;
          let msg = trade_ring.buf.(!last_seq mod ring_size) in
          incr last_seq;
          let%lwt () = send msg in
          drain ())
      in
      let rec tick () =
        let%lwt () = send (book_json engine) in
        let%lwt () = send (stats_json host) in
        let%lwt () = drain () in
        let%lwt () = Lwt_unix.sleep 0.5 in
        tick ()
      in
      Lwt.finalize tick (fun () ->
          decr active_clients;
          Lwt.return_unit))

(** {2 CORS}

    The dashboard is served from Vercel and calls this server cross-origin. The endpoints
    read no cookies, so a wildcard origin exposes nothing. [POST /order] sends JSON, which
    triggers a preflight [OPTIONS] request. *)

let cors (inner : Dream.handler) : Dream.handler =
 fun request ->
  match Dream.method_ request with
  | `OPTIONS ->
      Dream.respond
        ~headers:
          [
            ("Access-Control-Allow-Origin", "*");
            ("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
            ("Access-Control-Allow-Headers", "Content-Type");
            ("Access-Control-Max-Age", "86400");
          ]
        ""
  | _ ->
      let%lwt response = inner request in
      Dream.set_header response "Access-Control-Allow-Origin" "*";
      Lwt.return response

let () =
  Random.self_init ();
  let host = measure_host () in
  Printf.eprintf "[host] %.2f M orders/s, %.4f bytes/order\n%!" host.mops
    host.bytes_per_order;
  let engine = Engine.create default_config in
  seed_book engine;
  (* BOT=0 keeps the engine quiet for scripted demo recordings. *)
  if Sys.getenv_opt "BOT" <> Some "0" then Lwt.async (fun () -> run_bot engine);
  let interface = Option.value (Sys.getenv_opt "INTERFACE") ~default:"localhost" in
  let port = Option.fold (Sys.getenv_opt "PORT") ~none:8080 ~some:int_of_string in
  Dream.run ~interface ~port @@ Dream.logger @@ cors
  @@ Dream.router
       [
         Dream.get "/" (Dream.from_filesystem "front" "index.html");
         Dream.get "/healthz" (fun _ -> Dream.respond "ok");
         Dream.get "/events" (events engine host);
         Dream.post "/order" (place_order engine);
         Dream.get "/**" (Dream.static "front");
       ]
