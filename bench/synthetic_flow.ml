open Ocaml_lob
open Types

type flow_kind =
  | BalancedTwoSided
  | DeepBookLadder
  | AggressiveSweep
  | CancelChurn
  | IcebergReplenish
  | MixedRealistic
  | ItchStream
  | OuchStream
  | WireToEngine

let flow_name = function
  | BalancedTwoSided -> "Balanced Two-Sided"
  | DeepBookLadder -> "Deep Book Ladder"
  | AggressiveSweep -> "Aggressive Sweep"
  | CancelChurn -> "Cancel Churn"
  | IcebergReplenish -> "Iceberg Replenish"
  | MixedRealistic -> "Mixed Realistic"
  | ItchStream -> "ITCH 5.0 Feed Stream"
  | OuchStream -> "OUCH 5.0 Protocol Stream"
  | WireToEngine -> "Wire-to-Engine Ingestion"

let flow_description = function
  | BalancedTwoSided ->
      "Alternating two-sided quotes and aggressive crossing fills around mid price"
  | DeepBookLadder ->
      "Deep order book ladder with limit orders distributed over 200 price levels"
  | AggressiveSweep ->
      "Market sweeps, multi-level aggressive fills, IOC, and FOK executions"
  | CancelChurn ->
      "High-frequency quote churn: rapid submissions and cancellations across queues"
  | IcebergReplenish ->
      "Iceberg hidden volume replenishment and queue priority re-ordering"
  | MixedRealistic ->
      "Realistic production composite: 45% limit, 25% cancel, 15% sweep, 10% IOC/FOK, 5% \
       iceberg"
  | ItchStream ->
      "Standalone binary parsing of 10 ITCH 5.0 message variants in a contiguous stream"
  | OuchStream ->
      "Standalone binary parsing of OUCH 5.0 inbound requests and outbound responses"
  | WireToEngine ->
      "End-to-end binary wire payload decoding driving direct matching engine execution"

let all_flows =
  [
    BalancedTwoSided;
    DeepBookLadder;
    AggressiveSweep;
    CancelChurn;
    IcebergReplenish;
    MixedRealistic;
    ItchStream;
    OuchStream;
    WireToEngine;
  ]

let parse_flow s =
  let norm = String.lowercase_ascii (String.trim s) in
  List.find_opt
    (fun f ->
      let n = String.lowercase_ascii (flow_name f) in
      n = norm
      ||
      match f with
      | BalancedTwoSided -> norm = "balanced" || norm = "two_sided"
      | DeepBookLadder -> norm = "deep" || norm = "ladder" || norm = "deep_book"
      | AggressiveSweep -> norm = "sweep" || norm = "aggressive"
      | CancelChurn -> norm = "churn" || norm = "cancel"
      | IcebergReplenish -> norm = "iceberg" || norm = "replenish"
      | MixedRealistic -> norm = "mixed" || norm = "realistic"
      | ItchStream -> norm = "itch" || norm = "itch50"
      | OuchStream -> norm = "ouch" || norm = "ouch50"
      | WireToEngine -> norm = "wire" || norm = "e2e" || norm = "wire_to_engine")
    all_flows

type engine_action = Submit of Types.order | Cancel of int * Types.price * Types.side
type wire_action = { off : int; len : int; price : Types.price; side : Types.side }

type t =
  | EngineFlow of engine_action array
  | ProtocolFlow of string * (int * int) array * [ `Itch | `OuchInbound | `OuchOutbound ]
  | WireToEngineFlow of string * wire_action array

let mid_price = 100_000

let gen_balanced_flow n =
  let actions =
    Array.init n (fun i ->
        let is_buy = i mod 2 = 0 in
        let is_crossing = i mod 10 = 0 in
        let side, price =
          if is_crossing then
            if is_buy then (Buy, mid_price + 10) else (Ask, mid_price - 10)
          else
            let spread_offset = 10 + (i * 7 mod 190) in
            if is_buy then (Buy, mid_price - spread_offset)
            else (Ask, mid_price + spread_offset)
        in
        let qty = 10 + (i * 13 mod 90) in
        let o = make_order ~id:(i + 1) ~side ~price ~qty ~order_type:Limit ~timestamp:0 in
        Submit o)
  in
  EngineFlow actions

let gen_deep_book_flow n =
  let actions =
    Array.init n (fun i ->
        let is_buy = i mod 2 = 0 in
        let level_step = i / 2 mod 100 in
        let price =
          if is_buy then mid_price - 50 - (level_step * 50)
          else mid_price + 50 + (level_step * 50)
        in
        let qty = 20 + (i * 17 mod 100) in
        let side = if is_buy then Buy else Ask in
        let o = make_order ~id:(i + 1) ~side ~price ~qty ~order_type:Limit ~timestamp:0 in
        Submit o)
  in
  EngineFlow actions

let gen_aggressive_sweep_flow n =
  let actions =
    Array.init n (fun i ->
        let phase = i mod 5 in
        match phase with
        | 0 | 1 ->
            let side = if phase = 0 then Buy else Ask in
            let offset = 20 + (i * 11 mod 100) in
            let price = if side = Buy then mid_price - offset else mid_price + offset in
            let o =
              make_order ~id:(i + 1) ~side ~price ~qty:100 ~order_type:Limit ~timestamp:0
            in
            Submit o
        | 2 ->
            let side = if i mod 2 = 0 then Buy else Ask in
            let price = if side = Buy then mid_price + 80 else mid_price - 80 in
            let o =
              make_order ~id:(i + 1) ~side ~price ~qty:250 ~order_type:Limit ~timestamp:0
            in
            Submit o
        | 3 ->
            let side = if i mod 2 = 0 then Buy else Ask in
            let price = if side = Buy then mid_price + 100 else mid_price - 100 in
            let o =
              make_order ~id:(i + 1) ~side ~price ~qty:150 ~order_type:IOC ~timestamp:0
            in
            Submit o
        | _ ->
            let side = if i mod 2 = 0 then Buy else Ask in
            let price = if side = Buy then mid_price + 120 else mid_price - 120 in
            let o =
              make_order ~id:(i + 1) ~side ~price ~qty:50 ~order_type:FOK ~timestamp:0
            in
            Submit o)
  in
  EngineFlow actions

let gen_cancel_churn_flow n =
  let placed = Array.make n (0, 0, Buy) in
  let actions =
    Array.init n (fun i ->
        if i mod 2 = 1 && i >= 1 then
          let cancel_id, cancel_price, cancel_side = placed.(i - 1) in
          Cancel (cancel_id, cancel_price, cancel_side)
        else
          let is_buy = i mod 4 < 2 in
          let side = if is_buy then Buy else Ask in
          let price_offset = 10 + (i mod 100 * 10) in
          let price =
            if is_buy then mid_price - price_offset else mid_price + price_offset
          in
          let id = i + 1 in
          placed.(i) <- (id, price, side);
          let o = make_order ~id ~side ~price ~qty:20 ~order_type:Limit ~timestamp:0 in
          Submit o)
  in
  EngineFlow actions

let gen_iceberg_replenish_flow n =
  let actions =
    Array.init n (fun i ->
        if i mod 3 = 0 then
          let is_buy = i mod 2 = 0 in
          let side = if is_buy then Buy else Ask in
          let price = if is_buy then mid_price - 20 else mid_price + 20 in
          let o =
            make_order ~id:(i + 1) ~side ~price ~qty:1000
              ~order_type:(Iceberg { visible_qty = 100; total_qty = 1000 })
              ~timestamp:0
          in
          Submit o
        else
          let is_buy = i mod 2 <> 0 in
          let side = if is_buy then Buy else Ask in
          let price = if side = Buy then mid_price + 20 else mid_price - 20 in
          let o =
            make_order ~id:(i + 1) ~side ~price ~qty:100 ~order_type:Limit ~timestamp:0
          in
          Submit o)
  in
  EngineFlow actions

let gen_mixed_realistic_flow n =
  let placed = Array.make n (0, 0, Buy) in
  let actions =
    Array.init n (fun i ->
        let pct = i mod 100 in
        if pct < 45 then (
          let is_buy = i mod 2 = 0 in
          let side = if is_buy then Buy else Ask in
          let offset = 10 + (i * 13 mod 200) in
          let price = if is_buy then mid_price - offset else mid_price + offset in
          let id = i + 1 in
          placed.(i) <- (id, price, side);
          let o = make_order ~id ~side ~price ~qty:50 ~order_type:Limit ~timestamp:0 in
          Submit o)
        else if pct < 70 then
          let target_idx = max 0 (i - ((i mod 30) + 1)) in
          let id, price, side = placed.(target_idx) in
          Cancel (id, price, side)
        else if pct < 85 then (
          let is_buy = i mod 2 = 0 in
          let side = if is_buy then Buy else Ask in
          let price = if is_buy then mid_price + 30 else mid_price - 30 in
          let id = i + 1 in
          placed.(i) <- (id, price, side);
          let o = make_order ~id ~side ~price ~qty:75 ~order_type:Limit ~timestamp:0 in
          Submit o)
        else if pct < 95 then (
          let is_buy = i mod 2 = 0 in
          let side = if is_buy then Buy else Ask in
          let otype = if pct < 90 then IOC else FOK in
          let price = if is_buy then mid_price + 50 else mid_price - 50 in
          let id = i + 1 in
          placed.(i) <- (id, price, side);
          let o = make_order ~id ~side ~price ~qty:40 ~order_type:otype ~timestamp:0 in
          Submit o)
        else
          let is_buy = i mod 2 = 0 in
          let side = if is_buy then Buy else Ask in
          let price = if is_buy then mid_price - 15 else mid_price + 15 in
          let id = i + 1 in
          placed.(i) <- (id, price, side);
          let o =
            make_order ~id ~side ~price ~qty:500
              ~order_type:(Iceberg { visible_qty = 50; total_qty = 500 })
              ~timestamp:0
          in
          Submit o)
  in
  EngineFlow actions

let itch_message_types =
  [|
    ('A', 36);
    ('F', 40);
    ('E', 31);
    ('C', 36);
    ('X', 23);
    ('D', 19);
    ('P', 44);
    ('Q', 40);
    ('S', 12);
    ('R', 39);
  |]

let gen_itch_stream n =
  let buf = Buffer.create (n * 36) in
  let offsets = Array.make n (0, 0) in
  let kinds_len = Array.length itch_message_types in
  for i = 0 to n - 1 do
    let kind, size = itch_message_types.(i mod kinds_len) in
    let off = Buffer.length buf in
    Buffer.add_char buf kind;
    for j = 1 to size - 1 do
      Buffer.add_char buf (Char.chr ((i + j) land 255))
    done;
    offsets.(i) <- (off, size)
  done;
  ProtocolFlow (Buffer.contents buf, offsets, `Itch)

let gen_ouch_stream n =
  let buf = Buffer.create (n * 50) in
  let offsets = Array.make n (0, 0) in
  for i = 0 to n - 1 do
    let phase = i mod 5 in
    let off = Buffer.length buf in
    let size =
      match phase with
      | 0 ->
          Buffer.add_char buf 'O';
          for j = 1 to 44 do
            Buffer.add_char buf (Char.chr ((i + j) land 255))
          done;
          (* Appendage length = 6 *)
          Buffer.add_char buf '\000';
          Buffer.add_char buf '\006';
          (* Tag 2 = Firm, len = 5 (1 byte tag + 4 byte value) *)
          Buffer.add_char buf '\005';
          Buffer.add_char buf '\002';
          Buffer.add_string buf "ABCD";
          53
      | 1 ->
          Buffer.add_char buf 'O';
          for j = 1 to 44 do
            Buffer.add_char buf (Char.chr ((i + j) land 255))
          done;
          Buffer.add_char buf '\000';
          Buffer.add_char buf '\000';
          47
      | 2 ->
          Buffer.add_char buf 'U';
          for j = 1 to 37 do
            Buffer.add_char buf (Char.chr ((i + j) land 255))
          done;
          Buffer.add_char buf '\000';
          Buffer.add_char buf '\000';
          40
      | 3 ->
          Buffer.add_char buf 'X';
          for j = 1 to 8 do
            Buffer.add_char buf (Char.chr ((i + j) land 255))
          done;
          9
      | _ ->
          Buffer.add_char buf 'A';
          for j = 1 to 61 do
            Buffer.add_char buf (Char.chr ((i + j) land 255))
          done;
          Buffer.add_char buf '\000';
          Buffer.add_char buf '\000';
          64
    in
    offsets.(i) <- (off, size)
  done;
  ProtocolFlow (Buffer.contents buf, offsets, `OuchInbound)

let write_be32 buf v =
  Buffer.add_char buf (Char.chr ((v lsr 24) land 255));
  Buffer.add_char buf (Char.chr ((v lsr 16) land 255));
  Buffer.add_char buf (Char.chr ((v lsr 8) land 255));
  Buffer.add_char buf (Char.chr (v land 255))

let write_be64 buf v =
  for shift = 7 downto 0 do
    let byte =
      Int64.to_int (Int64.logand (Int64.shift_right_logical v (shift * 8)) 0xFFL)
    in
    Buffer.add_char buf (Char.chr byte)
  done

let gen_wire_to_engine n =
  let buf = Buffer.create (n * 50) in
  let actions = Array.make n { off = 0; len = 0; price = mid_price; side = Buy } in
  let placed = Array.make n (mid_price, Buy) in
  for i = 0 to n - 1 do
    let off = Buffer.length buf in
    let is_cancel = i mod 4 = 3 && i >= 3 in
    if is_cancel then (
      let target_idx = i - 1 in
      let cancel_price, cancel_side = placed.(target_idx) in
      Buffer.add_char buf 'X';
      write_be32 buf (target_idx + 1);
      write_be32 buf 0;
      actions.(i) <- { off; len = 9; price = cancel_price; side = cancel_side })
    else
      let is_buy = i mod 2 = 0 in
      let side = if is_buy then Buy else Ask in
      let offset = 10 + (i * 11 mod 180) in
      let price_int = if is_buy then mid_price - offset else mid_price + offset in
      placed.(i) <- (price_int, side);

      Buffer.add_char buf 'O';
      write_be32 buf (i + 1);
      Buffer.add_char buf (if is_buy then 'B' else 'S');
      write_be32 buf (25 + (i * 7 mod 75));
      Buffer.add_string buf "AAPL    ";
      write_be64 buf (Int64.of_int price_int);
      Buffer.add_char buf '0';
      Buffer.add_char buf 'Y';
      Buffer.add_char buf 'A';
      Buffer.add_char buf 'N';
      Buffer.add_char buf 'N';
      Buffer.add_string buf "ORD12345678901";
      Buffer.add_char buf '\000';
      Buffer.add_char buf '\000';
      actions.(i) <- { off; len = 47; price = price_int; side }
  done;
  WireToEngineFlow (Buffer.contents buf, actions)

let generate kind ~n =
  match kind with
  | BalancedTwoSided -> gen_balanced_flow n
  | DeepBookLadder -> gen_deep_book_flow n
  | AggressiveSweep -> gen_aggressive_sweep_flow n
  | CancelChurn -> gen_cancel_churn_flow n
  | IcebergReplenish -> gen_iceberg_replenish_flow n
  | MixedRealistic -> gen_mixed_realistic_flow n
  | ItchStream -> gen_itch_stream n
  | OuchStream -> gen_ouch_stream n
  | WireToEngine -> gen_wire_to_engine n
