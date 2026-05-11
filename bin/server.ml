(** {1 Real-Time Analytics Server}

    An OCaml [Dream] web server that bridges the high-performance matching
    engine with the browser-based dashboard via WebSockets. *)

open Ocaml_lob
open Types
module Engine = Engine
module Stats = Stats

(** {2 Snapshot Utilities} *)

(* Walk the side's price-level DLL from best to worst. The list is
   already sorted by aggressiveness (best at head), which matches how
   the dashboard wants to render — asks ascending, bids descending —
   so no client-side sort is needed. Skips empty levels left behind by
   the engine's lazy-keep policy on level exhaustion. *)
let snapshot_to_json (engine : Engine.t) =
    let level_to_json level =
        `Assoc [
            ("price", `Float (price_to_float level.pl_price));
            ("size", `Int level.pl_total_qty);
            ("totalSize", `Int level.pl_total_qty);
            ("depth", `Int (min 100 (level.pl_total_qty / 10)))
        ]
    in
    let side_to_json (side : book_side) =
        let rec walk lvl acc =
            if lvl == sentinel_level then List.rev acc
            else if lvl.pl_order_count = 0 then walk lvl.pl_next_level acc
            else walk lvl.pl_next_level (level_to_json lvl :: acc)
        in
        `List (walk side.best_level [])
    in
    `Assoc [
        ("type", `String "SNAPSHOT");
        ("asks", side_to_json engine.book.asks);
        ("bids", side_to_json engine.book.bids);
    ]

(** {2 Broadcast State}

    Every connected dashboard receives bot-generated trades and risk
    alerts. The list is mutated only on connect/disconnect; iteration
    is safe because Dream's default Lwt scheduler is single-threaded. *)

let connected_clients : Dream.websocket list ref = ref []

let broadcast (msg : string) =
    List.iter (fun ws ->
        Lwt.async (fun () ->
            try%lwt Dream.send ws msg with _ -> Lwt.return_unit))
    !connected_clients

(** {2 Demo Bot}

    A synthetic market-making + aggressor that keeps the book lively
    so visitors land on a moving market rather than a static snapshot.
    Pure demo affordance — none of this runs on the benchmarked hot path. *)

let bot_next_id = ref 1_000_000_000  (* above the manual-order id space *)
let mid_price_initial = 1_502_500     (* $150.25 in fixed-point ticks *)
let mid_price = ref mid_price_initial

(* Mid is clamped to [initial ± mid_drift_bound] so the bot can't
   accumulate unbounded unique price levels over a long-running deploy.
   The previous unbounded random walk hung the live demo after the
   per-side Price_index filled — see memory/engine_allocation_profile.md.
   Total bot-touched price range ≈ ±(mid_drift_bound + max_offset) =
   ±(300 + 550) = ±850 ticks ≈ 1700 unique prices. *)
let mid_drift_bound = 300

let next_bot_id () =
    incr bot_next_id; !bot_next_id

let make_bot_on_fill ~aggressive_side =
    fun passive_id active_id price qty _ts ->
        let msg = `Assoc [
            ("type", `String "TRADE");
            ("trade", `Assoc [
                ("side",       `String (side_to_string aggressive_side));
                ("price",      `Float (price_to_float price));
                ("size",       `Int qty);
                ("passive_id", `Int passive_id);
                ("active_id", `Int active_id);
            ]);
        ] |> Yojson.Safe.to_string in
        broadcast msg

let submit_bot_order engine ~side ~price ~qty =
    let order = make_order ~id:(next_bot_id ()) ~side ~price ~qty
        ~order_type:Limit ~timestamp:0 in
    ignore (Engine.submit engine order (make_bot_on_fill ~aggressive_side:side))

let alert_messages = [|
    "Heartbeat received from gateway 1";
    "Network jitter within bounds";
    "Risk limits verified";
    "Position check symbol: SPY";
    "Spread widened above 5bp";
    "Volatility spike detected";
    "Pre-trade gate latency 0.4μs";
    "Iceberg reload triggered on bid stack";
|]

let broadcast_random_alert () =
    let msg = alert_messages.(Random.int (Array.length alert_messages)) in
    let json = `Assoc [
        ("type",    `String "RISK_ALERT");
        ("message", `String msg);
    ] |> Yojson.Safe.to_string in
    broadcast json

(* Single iteration of bot behavior. Action distribution:
   55% aggressive cross  -> generates a fill, lights up the tape
   35% resting quote     -> deepens the book, lights up the depth chart
    7% mid drift         -> shifts BBO over time
    3% risk alert        -> populates the risk log *)
let bot_step engine =
    let action = Random.float 1.0 in
    if action < 0.55 then begin
        let side  = if Random.bool () then Buy else Ask in
        let cross = 50 + Random.int 200 in   (* 0.5–2.5¢ across the spread *)
        let price = match side with
            | Buy -> !mid_price + cross
            | Ask -> !mid_price - cross
        in
        submit_bot_order engine ~side ~price ~qty:(5 + Random.int 45)
    end else if action < 0.90 then begin
        let side   = if Random.bool () then Buy else Ask in
        let offset = 50 + Random.int 500 in  (* 0.5–5.5¢ resting from mid *)
        let price  = match side with
            | Buy -> !mid_price - offset
            | Ask -> !mid_price + offset
        in
        submit_bot_order engine ~side ~price ~qty:(100 + Random.int 900)
    end else if action < 0.97 then begin
        let new_mid = !mid_price + (Random.int 101 - 50) in   (* ±$0.005 step *)
        let low = mid_price_initial - mid_drift_bound in
        let high = mid_price_initial + mid_drift_bound in
        mid_price := max low (min high new_mid)
    end
    else
        broadcast_random_alert ()

(* Loop interval doubled from the original 150-400ms to 400-1000ms.
   The earlier rate (~3 orders/sec) saturated the 1/8 OCPU when
   combined with snapshot serialization for a live WS client and led
   to scheduler back-pressure on the live VM. Slower = stabler. *)
let rec run_demo_bot engine =
    let%lwt () = Lwt_unix.sleep (0.4 +. Random.float 0.6) in
    bot_step engine;
    run_demo_bot engine

(** {2 Server Logic} *)

let () =
    Random.self_init ();
    let config = default_config in
    let engine = Engine.create config in
    let stats = Stats.create 100_000 in

    (* Seed ~15 levels of depth on each side so the book reads as
       a real market the moment the page loads. *)
    let dummy_on_fill _ _ _ _ _ = () in
    for i = 1 to 15 do
        let bid = make_order ~id:(next_bot_id ())
            ~side:Buy ~price:(!mid_price - (i * 50))
            ~qty:(200 + Random.int 800) ~order_type:Limit ~timestamp:0 in
        let ask = make_order ~id:(next_bot_id ())
            ~side:Ask ~price:(!mid_price + (i * 50))
            ~qty:(200 + Random.int 800) ~order_type:Limit ~timestamp:0 in
        ignore (Engine.submit engine bid dummy_on_fill);
        ignore (Engine.submit engine ask dummy_on_fill)
    done;
    prerr_endline "[demo bot] seeded 15 levels per side; starting loop";
    Lwt.async (fun () -> run_demo_bot engine);

    (* Bind via env vars so the same binary works for local dev
       (defaults to localhost:8080) and behind a reverse proxy in
       Docker (set INTERFACE=0.0.0.0). *)
    let interface = try Sys.getenv "INTERFACE" with Not_found -> "localhost" in
    let port = try int_of_string (Sys.getenv "PORT") with _ -> 8080 in

    Dream.run ~interface ~port
    @@ Dream.logger
    @@ Dream.router [
        (* Static Files *)
        Dream.get "/" (Dream.from_filesystem "." "front/index.html");
        Dream.get "/app.js" (Dream.from_filesystem "." "front/app.js");
        Dream.get "/favicon.svg" (Dream.from_filesystem "." "front/favicon.svg");
        Dream.get "/social-preview.png" (Dream.from_filesystem "." "front/social-preview.png");

        (* WebSocket Endpoint *)
        Dream.get "/ws" (fun _ ->
            Dream.websocket (fun websocket ->
                connected_clients := websocket :: !connected_clients;
                let rec loop () =
                    let%lwt () = Lwt_unix.sleep 0.5 in (* Update UI every 500ms *)
                    
                    (* 1. Send Order Book Snapshot *)
                    let snapshot = snapshot_to_json engine |> Yojson.Safe.to_string in
                    let%lwt () = Dream.send websocket snapshot in
                    
                    (* 2. Send Performance Stats *)
                    let lat = Stats.get_percentile stats 0.99 in
                    let ops = Stats.get_throughput stats in
                    let stats_msg = `Assoc [
                        ("type", `String "STATS");
                        ("latency", `Float lat);
                        ("throughput", `Float ops)
                    ] |> Yojson.Safe.to_string in
                    let%lwt () = Dream.send websocket stats_msg in
                    
                    loop ()
                in

                (* Handle incoming messages (Manual Orders from Dashboard) *)
                let rec receiver () =
                    match%lwt Dream.receive websocket with
                    | Some msg ->
                        let json = Yojson.Safe.from_string msg in
                        (match Yojson.Safe.Util.member "type" json |> Yojson.Safe.Util.to_string with
                         | "ORDER" ->
                             let side = if Yojson.Safe.Util.member "side" json |> Yojson.Safe.Util.to_string = "BUY" then Buy else Ask in
                             let price = Yojson.Safe.Util.member "price" json |> Yojson.Safe.Util.to_float |> float_to_price in
                             let size = Yojson.Safe.Util.member "size" json |> Yojson.Safe.Util.to_int in
                             let order = make_order ~id:(Random.int 1000000) ~side ~price ~qty:size ~order_type:Limit ~timestamp:0 in
                             
                             let start = Unix.gettimeofday () in
                             let _ = Engine.submit engine order (fun passive_id active_id price qty _ ->
                                 let fill_msg = `Assoc [
                                     ("type", `String "TRADE");
                                     ("trade", `Assoc [
                                         ("side", `String (side_to_string side));
                                         ("price", `Float (price_to_float price));
                                         ("size", `Int qty);
                                         ("passive_id", `Int passive_id);
                                         ("active_id", `Int active_id)
                                     ])
                                 ] |> Yojson.Safe.to_string in
                                 Lwt.ignore_result (Dream.send websocket fill_msg)
                             ) in
                             let ns = (Unix.gettimeofday () -. start) *. 1_000_000_000.0 |> int_of_float in
                             Stats.record stats ns;
                             receiver ()
                         | _ -> receiver ())
                    | None -> Lwt.return_unit
                in

                Lwt.finalize
                    (fun () -> Lwt.choose [loop (); receiver ()])
                    (fun () ->
                        connected_clients :=
                            List.filter (fun w -> w != websocket) !connected_clients;
                        Lwt.return_unit)));
    ]
