open Ocaml_lob

let ok = function Ok value -> value | Error _ -> Alcotest.fail "decode failed"
let check_i64 = Alcotest.(check int64)
let check_int = Alcotest.(check int)
let check_char = Alcotest.(check char)

let check_text label expected value =
  Alcotest.(check string) label expected (Wire.to_string value)

let check_error expected = function
  | Error actual -> Alcotest.(check bool) "error kind" true (expected = actual)
  | Ok _ -> Alcotest.fail "malformed input accepted"

let rejects = function Error _ -> () | Ok _ -> Alcotest.fail "malformed input accepted"
let decode f s = f s ~off:0 ~len:(String.length s)

let hex s =
  let compact = String.concat "" (String.split_on_char ' ' s) in
  String.init
    (String.length compact / 2)
    (fun i -> Char.chr (int_of_string ("0x" ^ String.sub compact (i * 2) 2)))

let sample kind size =
  String.init size (fun i -> if i = 0 then kind else Char.chr (i land 255))

let itch_layouts =
  [
    ('S', 12);
    ('R', 39);
    ('H', 25);
    ('Y', 20);
    ('L', 26);
    ('V', 35);
    ('W', 12);
    ('K', 28);
    ('J', 35);
    ('h', 21);
    ('A', 36);
    ('F', 40);
    ('E', 31);
    ('C', 36);
    ('X', 23);
    ('D', 19);
    ('U', 35);
    ('P', 44);
    ('Q', 40);
    ('B', 19);
    ('I', 50);
    ('N', 20);
    ('O', 48);
  ]

let itch_kind (message : Itch.t) =
  match message.body with
  | System_event _ -> 'S'
  | Stock_directory _ -> 'R'
  | Stock_trading_action _ -> 'H'
  | Reg_sho_restriction _ -> 'Y'
  | Market_participant_position _ -> 'L'
  | Mwcb_decline_levels _ -> 'V'
  | Mwcb_status _ -> 'W'
  | Ipo_quoting_period _ -> 'K'
  | Luld_auction_collar _ -> 'J'
  | Operational_halt _ -> 'h'
  | Add_order _ -> 'A'
  | Add_order_attributed _ -> 'F'
  | Order_executed _ -> 'E'
  | Order_executed_with_price _ -> 'C'
  | Order_cancel _ -> 'X'
  | Order_delete _ -> 'D'
  | Order_replace _ -> 'U'
  | Trade _ -> 'P'
  | Cross_trade _ -> 'Q'
  | Broken_trade _ -> 'B'
  | Net_order_imbalance _ -> 'I'
  | Retail_price_improvement _ -> 'N'
  | Direct_listing_price_discovery _ -> 'O'

let test_itch_layouts () =
  List.iter
    (fun (kind, size) ->
      let payload = sample kind size in
      let buffer = "prefix" ^ payload ^ "suffix" in
      let message = ok (Itch.decode buffer ~off:6 ~len:size) in
      check_char "message kind" kind (itch_kind message);
      check_int "stock locate" 0x0102 message.stock_locate;
      check_int "tracking" 0x0304 message.tracking_number;
      check_i64 "48-bit timestamp" 0x05060708090aL message.timestamp;
      for len = 0 to size - 1 do
        rejects (Itch.decode buffer ~off:6 ~len)
      done;
      check_error
        (Wire.Invalid_length { expected = size; actual = size + 1 })
        (Itch.decode buffer ~off:6 ~len:(size + 1)))
    itch_layouts

let test_itch_order_lifecycle () =
  let header = hex "0001 0002 010203040506" in
  let body kind tail =
    (ok (decode Itch.decode (String.make 1 kind ^ header ^ hex tail))).body
  in
  (match body 'A' "fedcba9876543210 42 ffffffff 4141504c20202020 000f4240" with
  | Add_order r ->
      check_i64 "unsigned reference bits" 0xfedcba9876543210L r.order_reference;
      check_char "buy" 'B' r.side;
      check_i64 "unsigned shares" 4_294_967_295L r.shares;
      check_text "padded symbol" "AAPL    " r.stock;
      check_i64 "integer price" 1_000_000L r.price
  | _ -> Alcotest.fail "add variant");
  (match body 'F' "0000000000000001 53 00000064 4d53465420202020 000f4240 41424344" with
  | Add_order_attributed r -> check_text "MPID" "ABCD" r.attribution
  | _ -> Alcotest.fail "attributed add variant");
  (match body 'E' "0000000000000001 00000032 ffffffffffffffff" with
  | Order_executed r ->
      check_i64 "executed shares" 50L r.executed_shares;
      check_i64 "match bits" (-1L) r.match_number
  | _ -> Alcotest.fail "execution variant");
  (match body 'C' "0000000000000001 00000032 0000000000000002 59 000f4241" with
  | Order_executed_with_price r ->
      check_char "printable" 'Y' r.printable;
      check_i64 "execution price" 1_000_001L r.execution_price
  | _ -> Alcotest.fail "priced execution variant");
  (match body 'X' "0000000000000001 00000019" with
  | Order_cancel r -> check_i64 "cancel shares" 25L r.cancelled_shares
  | _ -> Alcotest.fail "cancel variant");
  (match body 'D' "0000000000000001" with
  | Order_delete r -> check_i64 "deleted reference" 1L r.order_reference
  | _ -> Alcotest.fail "delete variant");
  match body 'U' "0000000000000001 0000000000000002 0000004b 000f4242" with
  | Order_replace r ->
      check_i64 "old reference" 1L r.original_reference;
      check_i64 "new reference" 2L r.new_reference;
      check_i64 "replacement shares" 75L r.shares;
      check_i64 "replacement price" 1_000_002L r.price
  | _ -> Alcotest.fail "replace variant"

let test_itch_reference_and_auction () =
  let body kind size = (ok (decode Itch.decode (sample kind size))).body in
  (match body 'R' 39 with
  | Stock_directory r ->
      check_text "symbol" (hex "0b0c0d0e0f101112") r.stock;
      check_char "financial status" '\020' r.financial_status;
      check_i64 "lot size" 0x15161718L r.round_lot_size;
      check_text "subtype" (hex "1b1c") r.issue_sub_type;
      check_char "short sale threshold" '\030' r.short_sale_threshold;
      check_i64 "leverage" 0x22232425L r.etp_leverage
  | _ -> Alcotest.fail "directory variant");
  (match body 'V' 35 with
  | Mwcb_decline_levels r ->
      check_i64 "level 1, eight decimals" 0x0b0c0d0e0f101112L r.level_1;
      check_i64 "level 2" 0x131415161718191aL r.level_2;
      check_i64 "level 3" 0x1b1c1d1e1f202122L r.level_3
  | _ -> Alcotest.fail "MWCB variant");
  (match body 'P' 44 with
  | Trade r -> check_i64 "trade match" 0x2425262728292a2bL r.match_number
  | _ -> Alcotest.fail "trade variant");
  (match body 'Q' 40 with
  | Cross_trade r ->
      check_i64 "64-bit cross shares" 0x0b0c0d0e0f101112L r.shares;
      check_i64 "cross price" 0x1b1c1d1eL r.cross_price;
      check_char "cross type" '\039' r.cross_type
  | _ -> Alcotest.fail "cross variant");
  (match body 'I' 50 with
  | Net_order_imbalance r ->
      check_i64 "paired" 0x0b0c0d0e0f101112L r.paired_shares;
      check_i64 "imbalance" 0x131415161718191aL r.imbalance_shares;
      check_i64 "near price" 0x28292a2bL r.near_price;
      check_char "variation" '\049' r.price_variation
  | _ -> Alcotest.fail "NOII variant");
  match body 'O' 48 with
  | Direct_listing_price_discovery r ->
      check_i64 "execution time" 0x2021222324252627L r.near_execution_time;
      check_i64 "upper collar" 0x2c2d2e2fL r.upper_collar
  | _ -> Alcotest.fail "direct listing variant"

let inbound_layouts =
  [
    ('O', 45, false);
    ('U', 38, false);
    ('X', 9, true);
    ('M', 10, true);
    ('C', 17, false);
    ('D', 9, false);
    ('E', 9, false);
    ('Q', 1, true);
  ]

let outbound_layouts =
  [
    ('A', 62, false);
    ('U', 66, false);
    ('C', 18, true);
    ('D', 32, true);
    ('E', 34, false);
    ('B', 36, true);
    ('J', 29, true);
    ('P', 13, true);
    ('I', 13, true);
    ('T', 30, true);
    ('M', 18, true);
    ('R', 14, false);
    ('X', 25, false);
    ('G', 17, false);
    ('K', 17, false);
    ('Q', 13, true);
  ]

let inbound_kind : Ouch.Inbound.t -> char = function
  | Enter_order _ -> 'O'
  | Replace_order _ -> 'U'
  | Cancel_order _ -> 'X'
  | Modify_order _ -> 'M'
  | Mass_cancel _ -> 'C'
  | Disable_order_entry _ -> 'D'
  | Enable_order_entry _ -> 'E'
  | Account_query _ -> 'Q'

let outbound_kind : Ouch.Outbound.t -> char = function
  | System_event _ -> 'S'
  | Order_accepted _ -> 'A'
  | Order_replaced _ -> 'U'
  | Order_canceled _ -> 'C'
  | Aiq_canceled _ -> 'D'
  | Order_executed _ -> 'E'
  | Broken_trade _ -> 'B'
  | Rejected _ -> 'J'
  | Cancel_pending _ -> 'P'
  | Cancel_reject _ -> 'I'
  | Order_priority_update _ -> 'T'
  | Order_modified _ -> 'M'
  | Order_restated _ -> 'R'
  | Mass_cancel_response _ -> 'X'
  | Disable_order_entry_response _ -> 'G'
  | Enable_order_entry_response _ -> 'K'
  | Account_query_response _ -> 'Q'

let ouch_packet kind base appendages =
  let length = String.length appendages in
  sample kind base
  ^ String.init 2 (function
    | 0 -> Char.chr (length lsr 8)
    | _ -> Char.chr (length land 255))
  ^ appendages

let check_ouch_layouts decoder kind_of layouts =
  List.iter
    (fun (kind, base, optional) ->
      let packet = ouch_packet kind base "" in
      let buffer = "prefix" ^ packet ^ "suffix" in
      let message = ok (decoder buffer ~off:6 ~len:(base + 2)) in
      check_char "direction-specific kind" kind (kind_of message);
      for len = 0 to base + 1 do
        if optional && len = base then ignore (ok (decoder buffer ~off:6 ~len))
        else rejects (decoder buffer ~off:6 ~len)
      done;
      rejects (decoder buffer ~off:6 ~len:(base + 3));
      let packet = ouch_packet kind base (hex "021c07") in
      ignore (ok (decode decoder packet)))
    layouts

let test_ouch_layouts () =
  check_ouch_layouts Ouch.Inbound.decode inbound_kind inbound_layouts;
  check_ouch_layouts Ouch.Outbound.decode outbound_kind outbound_layouts;
  let system = ok (decode Ouch.Outbound.decode (hex "53 0102030405060708 53")) in
  check_char "system kind" 'S' (outbound_kind system);
  (match system with
  | System_event r ->
      check_i64 "64-bit timestamp" 0x0102030405060708L r.timestamp;
      check_char "start of day" 'S' r.event_code
  | _ -> Alcotest.fail "system variant");
  for len = 0 to 9 do
    rejects (Ouch.Outbound.decode (sample 'S' 11) ~off:0 ~len)
  done;
  rejects (decode Ouch.Outbound.decode (sample 'S' 11))

let test_ouch_order_fields () =
  let payload =
    hex
      "4f ffffffff 54 fffffffe 4141504c20202020 00000000000f4240 33 59 41 4e 4e \
       636c69656e742d6f726465722020 0000"
  in
  (match ok (decode Ouch.Inbound.decode payload) with
  | Enter_order r ->
      check_i64 "user reference" 4_294_967_295L r.user_ref;
      check_char "short sell" 'T' r.side;
      check_i64 "quantity unsigned" 4_294_967_294L r.quantity;
      check_text "symbol" "AAPL    " r.symbol;
      check_i64 "eight-byte price, four decimals" 1_000_000L r.price;
      check_char "IOC code is ASCII" '3' r.time_in_force;
      check_char "display" 'Y' r.display;
      check_char "capacity" 'A' r.capacity;
      check_char "sweep" 'N' r.intermarket_sweep;
      check_char "cross" 'N' r.cross_type;
      check_text "client id" "client-order  " r.cl_ord_id;
      Alcotest.(check bool) "zero-copy source" true (r.symbol.buffer == payload)
  | _ -> Alcotest.fail "enter variant");
  (match ok (decode Ouch.Inbound.decode (ouch_packet 'U' 38 "")) with
  | Replace_order r ->
      check_i64 "original user" 0x01020304L r.original_user_ref;
      check_i64 "new user" 0x05060708L r.user_ref;
      check_i64 "replace price" 0x0d0e0f1011121314L r.price
  | _ -> Alcotest.fail "replace variant");
  (match ok (decode Ouch.Outbound.decode (ouch_packet 'A' 62 "")) with
  | Order_accepted r ->
      check_i64 "accepted timestamp" 0x0102030405060708L r.timestamp;
      check_i64 "accepted user" 0x090a0b0cL r.user_ref;
      check_i64 "accepted price" 0x1a1b1c1d1e1f2021L r.price;
      check_i64 "exchange reference" 0x2425262728292a2bL r.order_reference;
      check_char "state" '\047' r.order_state
  | _ -> Alcotest.fail "accepted variant");
  (match ok (decode Ouch.Outbound.decode (ouch_packet 'U' 66 "")) with
  | Order_replaced r ->
      check_i64 "original user" 0x090a0b0cL r.original_user_ref;
      check_i64 "new user" 0x0d0e0f10L r.user_ref;
      check_i64 "exchange reference" 0x28292a2b2c2d2e2fL r.order_reference
  | _ -> Alcotest.fail "replaced variant");
  (match ok (decode Ouch.Outbound.decode (ouch_packet 'D' 32 "")) with
  | Aiq_canceled r ->
      check_i64 "prevented shares" 0x12131415L r.prevented_quantity;
      check_i64 "prevented price" 0x161718191a1b1c1dL r.execution_price;
      check_char "AIQ strategy" '\031' r.aiq_strategy
  | _ -> Alcotest.fail "AIQ variant");
  (match ok (decode Ouch.Outbound.decode (ouch_packet 'E' 34 "")) with
  | Order_executed r ->
      check_i64 "executed price" 0x1112131415161718L r.price;
      check_i64 "match" 0x1a1b1c1d1e1f2021L r.match_number
  | _ -> Alcotest.fail "execution variant");
  (match ok (decode Ouch.Outbound.decode (ouch_packet 'J' 29 "")) with
  | Rejected r -> check_int "two-byte reject reason" 0x0d0e r.reason
  | _ -> Alcotest.fail "rejected variant");
  rejects (decode Ouch.Inbound.decode (ouch_packet 'A' 62 ""));
  rejects (decode Ouch.Outbound.decode payload)

let query_appendages data =
  match ok (decode Ouch.Inbound.decode (ouch_packet 'Q' 1 data)) with
  | Account_query r -> r.appendages
  | _ -> Alcotest.fail "query variant"

let collect appendages =
  let items = ref [] in
  Ouch.iter_appendages (fun value -> items := value :: !items) appendages;
  List.rev !items

let test_appendages () =
  let data =
    hex
      "0901ffffffffffffffff 050241424344 0503ffffffff 020441 0505ffffffff 02064c \
       0507ffffffff 09090000000000000001 020a4d 050b80000000 020c50 050dffffffff \
       050e524f5554 050fffffffff 021059 021149 021253 0516ffffffff 09170000000000000002 \
       0318ffff 021959 051a4c4f4341 021b54 021cff 021d44 031e4142 03fa0102 01fb 021c01"
  in
  let items = collect (query_appendages data) in
  let text = function
    | Ouch.Firm s | Route s | Locate_broker s | Aiq_group_id s -> Some (Wire.to_string s)
    | _ -> None
  in
  Alcotest.(check (list string))
    "text options"
    [ "ABCD"; "ROUT"; "LOCA"; "AB" ]
    (List.filter_map text items);
  let numeric =
    List.filter
      (function
        | Ouch.Firm _ | Route _ | Locate_broker _ | Aiq_group_id _ | Unknown _ -> false
        | _ -> true)
      items
  in
  let expected =
    Ouch.
      [
        Secondary_order_reference (-1L);
        Min_quantity 4_294_967_295L;
        Customer_type 'A';
        Max_floor 4_294_967_295L;
        Price_type 'L';
        Peg_offset (-1l);
        Discretion_price 1L;
        Discretion_price_type 'M';
        Discretion_peg_offset Int32.min_int;
        Post_only 'P';
        Random_reserves 4_294_967_295L;
        Expire_time 4_294_967_295L;
        Trade_now 'Y';
        Handle_inst 'I';
        Bbo_weight_indicator 'S';
        Display_quantity 4_294_967_295L;
        Display_price 2L;
        Group_id 65535;
        Shares_located 'Y';
        Side 'T';
        User_ref_index 255;
        Aiq_strategy 'D';
        User_ref_index 1;
      ]
  in
  Alcotest.(check bool) "typed values, wire order and duplicates" true (expected = numeric);
  let unknown =
    List.filter_map
      (function Ouch.Unknown r -> Some (r.tag, Wire.to_string r.value) | _ -> None)
      items
  in
  Alcotest.(check (list (pair int string)))
    "unknown options retained"
    [ (250, hex "0102"); (251, "") ]
    unknown;
  Alcotest.(check int) "empty options" 0 (List.length (collect (query_appendages "")));
  let maximum =
    String.init 65_532 (fun i -> if i mod 2 = 0 then '\001' else '\250') ^ hex "021cff"
  in
  let count = ref 0 in
  let last = ref (Ouch.User_ref_index 0) in
  Ouch.iter_appendages
    (fun value ->
      incr count;
      last := value)
    (query_appendages maximum);
  check_int "maximum uint16 appendage, tail-recursive traversal" 32_767 !count;
  Alcotest.(check bool)
    "last tag in maximum appendage" true
    (!last = Ouch.User_ref_index 255)

let test_malformed_appendages () =
  List.iter
    (fun data ->
      check_error (Wire.Invalid_appendage 3)
        (decode Ouch.Inbound.decode (ouch_packet 'Q' 1 (hex data))))
    [ "00"; "001c"; "011c"; "031c01"; "021c"; "020100"; "01"; "ff1c00" ];
  check_error (Wire.Invalid_appendage 6)
    (decode Ouch.Inbound.decode (ouch_packet 'Q' 1 (hex "021c01 00")));
  check_error
    (Wire.Truncated { needed = 8; available = 4 })
    (decode Ouch.Inbound.decode (hex "51 0005 00"));
  check_error
    (Wire.Invalid_length { expected = 3; actual = 4 })
    (decode Ouch.Inbound.decode (hex "51 0000 00"));
  check_error
    (Wire.Truncated { needed = 3; available = 2 })
    (decode Ouch.Inbound.decode (hex "51 00"))

let test_wire_and_bounds () =
  let s =
    Wire.slice (hex "ff ffff ffffffff ffffffffffff ffffffffffffffff") ~off:0 ~len:21
  in
  check_int "u8" 255 (Wire.u8 s 0);
  check_int "u16" 65535 (Wire.u16 s 1);
  check_i64 "u32" 4_294_967_295L (Wire.u32 s 3);
  check_i64 "u48" 281_474_976_710_655L (Wire.u48 s 7);
  check_i64 "u64 bits" (-1L) (Wire.u64 s 13);
  Wire.require_length s 21;
  let check_raises f =
    try
      f ();
      Alcotest.fail "invalid bounds accepted"
    with Wire.Decode_error Wire.Invalid_bounds -> ()
  in
  check_raises (fun () -> ignore (Wire.sub s ~off:20 ~len:2));
  check_raises (fun () -> ignore (Wire.u64 s 14));
  check_raises (fun () -> ignore (Wire.i32 s 18));
  check_raises (fun () -> ignore (Wire.u48 s 16));
  check_raises (fun () -> ignore (Wire.u16 s 20));
  check_raises (fun () -> ignore (Wire.char s (-1)));
  let check_decoder decoder =
    List.iter
      (fun (off, len) -> check_error Wire.Invalid_bounds (decoder "abc" ~off ~len))
      [ (-1, 1); (0, -1); (4, 0); (2, 2); (max_int, 1); (1, max_int) ];
    check_error
      (Wire.Truncated { needed = 1; available = 0 })
      (decoder "abc" ~off:3 ~len:0);
    check_error (Wire.Unknown_type '?') (decoder "?" ~off:0 ~len:1)
  in
  check_decoder Itch.decode;
  check_decoder Ouch.Inbound.decode;
  check_decoder Ouch.Outbound.decode

let test_bounded_allocation () =
  let itch = sample 'A' 36 in
  let ouch = ouch_packet 'O' 45 "" in
  let check label decoder payload =
    let decode_one () = ignore (Sys.opaque_identity (ok (decode decoder payload))) in
    decode_one ();
    let start = Unix.gettimeofday () in
    let before = Gc.minor_words () in
    for _ = 1 to 100_000 do
      decode_one ()
    done;
    let bytes =
      (Gc.minor_words () -. before) *. float_of_int (Sys.word_size / 8) /. 100_000.
    in
    let elapsed = Unix.gettimeofday () -. start in
    Printf.printf "%s: %.1f bytes/payload, %.2f M payloads/s\n%!" label bytes
      (0.1 /. elapsed);
    Alcotest.(check bool)
      "bounded record allocation (<=512 bytes/payload)" true (bytes <= 512.)
  in
  check "ITCH add" Itch.decode itch;
  check "OUCH enter" Ouch.Inbound.decode ouch

let fuzz_no_exceptions =
  let gen =
    QCheck.Gen.(
      triple (string_size (int_bound 200)) (int_range (-2) 205) (int_range (-2) 205))
  in
  QCheck.Test.make ~name:"arbitrary buffers and windows return results" ~count:10_000
    (QCheck.make gen) (fun (buffer, off, len) ->
      ignore (Itch.decode buffer ~off ~len);
      ignore (Ouch.Inbound.decode buffer ~off ~len);
      ignore (Ouch.Outbound.decode buffer ~off ~len);
      true)

let () =
  Alcotest.run "binary protocols"
    [
      ( "itch",
        [
          Alcotest.test_case "all layouts and truncations" `Quick test_itch_layouts;
          Alcotest.test_case "order lifecycle vectors" `Quick test_itch_order_lifecycle;
          Alcotest.test_case "reference and auction fields" `Quick
            test_itch_reference_and_auction;
        ] );
      ( "ouch",
        [
          Alcotest.test_case "both directions and appendage forms" `Quick
            test_ouch_layouts;
          Alcotest.test_case "order field vectors" `Quick test_ouch_order_fields;
          Alcotest.test_case "all typed appendages" `Quick test_appendages;
          Alcotest.test_case "malformed appendages" `Quick test_malformed_appendages;
        ] );
      ( "wire",
        [
          Alcotest.test_case "unsigned primitives and bounds" `Quick test_wire_and_bounds;
          Alcotest.test_case "bounded allocation" `Quick test_bounded_allocation;
          QCheck_alcotest.to_alcotest fuzz_no_exceptions;
        ] );
    ]
