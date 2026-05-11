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

(** {2 Fan-out Rings}

    Bot fills, manual fills, and risk alerts are serialized once and
    written into a fixed-size ring keyed by a monotonic sequence
    number. Each connected WS reads only from the ring, inside its own
    serialized snapshot loop — so every byte that hits a socket has
    been awaited by the per-client task that owns that socket.

    Previously this module used a fire-and-forget broadcast: each
    producer iterated [connected_clients] and spawned [Lwt.async
    (Dream.send ws msg)] per client. Under bot load with a client that
    subsequently disconnected, the queued frames piled up inside
    gluten_lwt's internal write buffer. Once the socket was closed,
    gluten's [write_loop_step] entered a tight retry-on-failed-write
    cycle (Trivial_promises.fail caught by Sequential_composition.catch,
    no yield between iterations) and pegged a core. SIGUSR1 dump on
    2026-05-11 caught the loop mid-spin. Our [Lwt.pick] cancellation
    and [try%lwt] guard were both *above* gluten; the bug was in the
    layer below.

    Pull-from-ring eliminates the entire class of bug: nothing is
    queued for a closed socket because nothing is queued at all —
    each [Dream.send] happens inside the cancellable per-client loop
    and is awaited.

    Ring is bounded; a client lagging more than [ring_size] entries
    loses the oldest. Acceptable for a trade tape — viewers see the
    most recent activity, not history. *)

let stream_ring_size = 256

type stream_ring = {
    buf : string array;
    mutable seq : int;   (* monotonic, total ever pushed *)
}

let mk_ring () =
    { buf = Array.make stream_ring_size ""; seq = 0 }

let push_ring r s =
    r.buf.(r.seq mod stream_ring_size) <- s;
    r.seq <- r.seq + 1

(* Send entries [!last_seq .. r.seq) on [ws], updating [last_seq]. If
   the client has fallen behind by more than the ring's capacity,
   the oldest missed entries are dropped (we jump forward to the
   tail-most stream_ring_size entries). *)
let drain_ring ws r last_seq =
    let cur = r.seq in
    if cur = !last_seq then Lwt.return_unit
    else begin
        let start =
            if cur - !last_seq > stream_ring_size
            then cur - stream_ring_size
            else !last_seq
        in
        let rec loop i =
            if i >= cur then begin last_seq := cur; Lwt.return_unit end
            else
                let%lwt () = Dream.send ws r.buf.(i mod stream_ring_size) in
                loop (i + 1)
        in
        loop start
    end

let trade_ring = mk_ring ()
let alert_ring = mk_ring ()

(* Retained only so the SIGUSR1 dump can report client count. Not
   iterated for sends. *)
let active_clients = ref 0

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
        push_ring trade_ring msg

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
    push_ring alert_ring json

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

(* SIGUSR1 dumps the main thread's call stack + GC state to stderr
   without restarting the process. To trigger from the host:
     kill -USR1 $(docker inspect --format '{{.State.Pid}}' ocaml_lob)
   Then capture the dump from `docker logs --tail 200 ocaml_lob`
   BEFORE running `docker restart`. The wedge is "container Up but
   URL hangs"; this is how we find where the main thread is parked
   next time it happens. *)
let install_diagnostic_dump () =
    Printexc.record_backtrace true;
    Sys.set_signal Sys.sigusr1 (Sys.Signal_handle (fun _ ->
        let cs = Printexc.get_callstack 64 in
        let s  = Gc.stat () in
        Printf.eprintf
            "[diag] === SIGUSR1 dump ===\n\
             [diag] callstack:\n%s\
             [diag] gc heap_words=%d live_words=%d top_heap_words=%d \
             stack_size=%d minor_collections=%d major_collections=%d \
             compactions=%d\n\
             [diag] active_clients=%d bot_orders_submitted=%d \
             trade_seq=%d alert_seq=%d\n%!"
            (Printexc.raw_backtrace_to_string cs)
            s.heap_words s.live_words s.top_heap_words s.stack_size
            s.minor_collections s.major_collections s.compactions
            !active_clients
            (!bot_next_id - 1_000_000_000)
            trade_ring.seq
            alert_ring.seq))

let () =
    install_diagnostic_dump ();
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
    (* The demo bot is gated on a BOT env var so the same image works
       for the live deploy (BOT unset → bot runs, dashboard is lively)
       and for E2E demo recording (BOT=0 → no bot, quiet engine, no
       chance of hitting the as-yet-undiagnosed engine hang that fires
       once an aggressive bot order stream meets a live WS client). *)
    let bot_enabled =
        try Sys.getenv "BOT" <> "0" with Not_found -> true
    in
    if bot_enabled then begin
        prerr_endline "[demo bot] seeded 15 levels per side; starting loop";
        Lwt.async (fun () -> run_demo_bot engine)
    end else
        prerr_endline "[demo bot] disabled via BOT=0; engine quiet";

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

        (* Server-Sent Events stream. Replaces the previous /ws
           endpoint. WebSockets — even with all our async sends
           removed — still wedged in gluten_lwt's write_loop_step
           on every WS close because [Dream_pure.Stream.close] in
           Dream's WS close path spawns an [Lwt.async] write-loop
           internally that we cannot reach from our code. SSE runs
           over plain HTTP chunked encoding; the close path does
           not go through [close_websocket], so the gluten WS
           spin is structurally inaccessible.

           Protocol: identical JSON payloads as before. Each event
           is one [data: <json>\n\n] frame. Frontend uses
           [EventSource] in place of [WebSocket]; the message
           handler is unchanged. Manual orders moved to
           [POST /order] since SSE is server→client only. *)
        Dream.get "/events" (fun _ ->
            Dream.stream
                ~headers:[
                    ("Content-Type", "text/event-stream");
                    ("Cache-Control", "no-cache");
                    (* Defeat reverse-proxy buffering (Caddy, nginx).
                       Without this, the client sees nothing until the
                       proxy flushes — defeats the whole point of SSE. *)
                    ("X-Accel-Buffering", "no");
                ]
                (fun stream ->
                    incr active_clients;
                    let last_trade_seq = ref trade_ring.seq in
                    let last_alert_seq = ref alert_ring.seq in
                    let send_event payload =
                        let%lwt () = Dream.write stream ("data: " ^ payload ^ "\n\n") in
                        Dream.flush stream
                    in
                    let drain_sse r last_seq =
                        let cur = r.seq in
                        if cur = !last_seq then Lwt.return_unit
                        else begin
                            let start =
                                if cur - !last_seq > stream_ring_size
                                then cur - stream_ring_size
                                else !last_seq
                            in
                            let rec loop i =
                                if i >= cur then begin last_seq := cur; Lwt.return_unit end
                                else
                                    let%lwt () = send_event r.buf.(i mod stream_ring_size) in
                                    loop (i + 1)
                            in
                            loop start
                        end
                    in
                    let rec tick () =
                        let%lwt () = Lwt_unix.sleep 0.5 in
                        let snapshot = snapshot_to_json engine |> Yojson.Safe.to_string in
                        let%lwt () = send_event snapshot in
                        let lat = Stats.get_percentile stats 0.99 in
                        let ops = Stats.get_throughput stats in
                        let stats_msg = `Assoc [
                            ("type", `String "STATS");
                            ("latency", `Float lat);
                            ("throughput", `Float ops)
                        ] |> Yojson.Safe.to_string in
                        let%lwt () = send_event stats_msg in
                        let%lwt () = drain_sse trade_ring last_trade_seq in
                        let%lwt () = drain_sse alert_ring last_alert_seq in
                        tick ()
                    in
                    Lwt.finalize
                        (fun () -> tick ())
                        (fun () -> decr active_clients; Lwt.return_unit)));

        (* Manual order placement. Replaces the WS ORDER message. *)
        Dream.post "/order" (fun request ->
            let%lwt body = Dream.body request in
            try
                let json = Yojson.Safe.from_string body in
                let side =
                    if Yojson.Safe.Util.member "side" json |> Yojson.Safe.Util.to_string = "BUY"
                    then Buy else Ask
                in
                let price =
                    Yojson.Safe.Util.member "price" json
                    |> Yojson.Safe.Util.to_float |> float_to_price
                in
                let size =
                    Yojson.Safe.Util.member "size" json
                    |> Yojson.Safe.Util.to_int
                in
                let order = make_order ~id:(Random.int 1000000) ~side ~price
                    ~qty:size ~order_type:Limit ~timestamp:0 in

                let t0 = Unix.gettimeofday () in
                let _ = Engine.submit engine order
                    (fun passive_id active_id price qty _ ->
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
                        push_ring trade_ring fill_msg)
                in
                let ns = (Unix.gettimeofday () -. t0) *. 1_000_000_000.0 |> int_of_float in
                Stats.record stats ns;
                Dream.respond
                    ~headers:[("Content-Type", "application/json")]
                    {|{"status":"ok"}|}
            with _ ->
                Dream.respond ~status:`Bad_Request
                    ~headers:[("Content-Type", "application/json")]
                    {|{"status":"error"}|});
    ]
