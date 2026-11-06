type appendages = Wire.slice

type appendage =
  | Secondary_order_reference of int64
  | Firm of Wire.slice
  | Min_quantity of int64
  | Customer_type of char
  | Max_floor of int64
  | Price_type of char
  | Peg_offset of int32
  | Discretion_price of int64
  | Discretion_price_type of char
  | Discretion_peg_offset of int32
  | Post_only of char
  | Random_reserves of int64
  | Route of Wire.slice
  | Expire_time of int64
  | Trade_now of char
  | Handle_inst of char
  | Bbo_weight_indicator of char
  | Display_quantity of int64
  | Display_price of int64
  | Group_id of int
  | Shares_located of char
  | Locate_broker of Wire.slice
  | Side of char
  | User_ref_index of int
  | Aiq_strategy of char
  | Aiq_group_id of Wire.slice
  | Unknown of { tag : int; value : Wire.slice }

let option_size = function
  | 1 -> 8
  | 2 -> 4
  | 3 -> 4
  | 4 -> 1
  | 5 -> 4
  | 6 -> 1
  | 7 -> 4
  | 9 -> 8
  | 10 -> 1
  | 11 -> 4
  | 12 -> 1
  | 13 -> 4
  | 14 -> 4
  | 15 -> 4
  | 16 -> 1
  | 17 -> 1
  | 18 -> 1
  | 22 -> 4
  | 23 -> 8
  | 24 -> 2
  | 25 -> 1
  | 26 -> 4
  | 27 -> 1
  | 28 -> 1
  | 29 -> 1
  | 30 -> 2
  | _ -> -1

let rec validate_appendages frame pos =
  if pos < frame.Wire.len then begin
    if frame.len - pos < 2 then raise (Wire.Decode_error (Wire.Invalid_appendage pos));
    let length = Wire.u8 frame pos in
    let tag = Wire.u8 frame (pos + 1) in
    let expected = option_size tag in
    if
      length < 1
      || length > frame.len - pos - 1
      || (expected >= 0 && length <> expected + 1)
    then raise (Wire.Decode_error (Wire.Invalid_appendage pos));
    validate_appendages frame (pos + length + 1)
  end

let parse_appendages frame ~base ~optional =
  if optional && frame.Wire.len = base then Wire.sub frame ~off:base ~len:0
  else begin
    if frame.len < base + 2 then
      raise
        (Wire.Decode_error (Wire.Truncated { needed = base + 2; available = frame.len }));
    let length = Wire.u16 frame base in
    Wire.require_length frame (base + 2 + length);
    validate_appendages frame (base + 2);
    Wire.sub frame ~off:(base + 2) ~len:length
  end

let rec iter_at f appendages pos =
  if pos < appendages.Wire.len then begin
    let length = Wire.u8 appendages pos in
    let tag = Wire.u8 appendages (pos + 1) in
    let value = Wire.sub appendages ~off:(pos + 2) ~len:(length - 1) in
    let attribute =
      match tag with
      | 1 -> Secondary_order_reference (Wire.u64 value 0)
      | 2 -> Firm value
      | 3 -> Min_quantity (Wire.u32 value 0)
      | 4 -> Customer_type (Wire.char value 0)
      | 5 -> Max_floor (Wire.u32 value 0)
      | 6 -> Price_type (Wire.char value 0)
      | 7 -> Peg_offset (Wire.i32 value 0)
      | 9 -> Discretion_price (Wire.u64 value 0)
      | 10 -> Discretion_price_type (Wire.char value 0)
      | 11 -> Discretion_peg_offset (Wire.i32 value 0)
      | 12 -> Post_only (Wire.char value 0)
      | 13 -> Random_reserves (Wire.u32 value 0)
      | 14 -> Route value
      | 15 -> Expire_time (Wire.u32 value 0)
      | 16 -> Trade_now (Wire.char value 0)
      | 17 -> Handle_inst (Wire.char value 0)
      | 18 -> Bbo_weight_indicator (Wire.char value 0)
      | 22 -> Display_quantity (Wire.u32 value 0)
      | 23 -> Display_price (Wire.u64 value 0)
      | 24 -> Group_id (Wire.u16 value 0)
      | 25 -> Shares_located (Wire.char value 0)
      | 26 -> Locate_broker value
      | 27 -> Side (Wire.char value 0)
      | 28 -> User_ref_index (Wire.u8 value 0)
      | 29 -> Aiq_strategy (Wire.char value 0)
      | 30 -> Aiq_group_id value
      | _ -> Unknown { tag; value }
    in
    f attribute;
    iter_at f appendages (pos + length + 1)
  end

let iter_appendages f appendages = iter_at f appendages 0

module Inbound = struct
  type t =
    | Enter_order of {
        user_ref : int64;
        side : char;
        quantity : int64;
        symbol : Wire.slice;
        price : int64;
        time_in_force : char;
        display : char;
        capacity : char;
        intermarket_sweep : char;
        cross_type : char;
        cl_ord_id : Wire.slice;
        appendages : appendages;
      }
    | Replace_order of {
        original_user_ref : int64;
        user_ref : int64;
        quantity : int64;
        price : int64;
        time_in_force : char;
        display : char;
        intermarket_sweep : char;
        cl_ord_id : Wire.slice;
        appendages : appendages;
      }
    | Cancel_order of { user_ref : int64; quantity : int64; appendages : appendages }
    | Modify_order of {
        user_ref : int64;
        side : char;
        quantity : int64;
        appendages : appendages;
      }
    | Mass_cancel of {
        user_ref : int64;
        firm : Wire.slice;
        symbol : Wire.slice;
        appendages : appendages;
      }
    | Disable_order_entry of {
        user_ref : int64;
        firm : Wire.slice;
        appendages : appendages;
      }
    | Enable_order_entry of {
        user_ref : int64;
        firm : Wire.slice;
        appendages : appendages;
      }
    | Account_query of { appendages : appendages }

  let decode buffer ~off ~len =
    try
      let frame = Wire.slice buffer ~off ~len in
      if len = 0 then
        raise (Wire.Decode_error (Wire.Truncated { needed = 1; available = 0 }));
      let body =
        match Wire.char frame 0 with
        | 'O' ->
            let appendages = parse_appendages frame ~base:45 ~optional:false in
            Enter_order
              {
                user_ref = Wire.u32 frame 1;
                side = Wire.char frame 5;
                quantity = Wire.u32 frame 6;
                symbol = Wire.sub frame ~off:10 ~len:8;
                price = Wire.u64 frame 18;
                time_in_force = Wire.char frame 26;
                display = Wire.char frame 27;
                capacity = Wire.char frame 28;
                intermarket_sweep = Wire.char frame 29;
                cross_type = Wire.char frame 30;
                cl_ord_id = Wire.sub frame ~off:31 ~len:14;
                appendages;
              }
        | 'U' ->
            let appendages = parse_appendages frame ~base:38 ~optional:false in
            Replace_order
              {
                original_user_ref = Wire.u32 frame 1;
                user_ref = Wire.u32 frame 5;
                quantity = Wire.u32 frame 9;
                price = Wire.u64 frame 13;
                time_in_force = Wire.char frame 21;
                display = Wire.char frame 22;
                intermarket_sweep = Wire.char frame 23;
                cl_ord_id = Wire.sub frame ~off:24 ~len:14;
                appendages;
              }
        | 'X' ->
            let appendages = parse_appendages frame ~base:9 ~optional:true in
            Cancel_order
              { user_ref = Wire.u32 frame 1; quantity = Wire.u32 frame 5; appendages }
        | 'M' ->
            let appendages = parse_appendages frame ~base:10 ~optional:true in
            Modify_order
              {
                user_ref = Wire.u32 frame 1;
                side = Wire.char frame 5;
                quantity = Wire.u32 frame 6;
                appendages;
              }
        | 'C' ->
            let appendages = parse_appendages frame ~base:17 ~optional:false in
            Mass_cancel
              {
                user_ref = Wire.u32 frame 1;
                firm = Wire.sub frame ~off:5 ~len:4;
                symbol = Wire.sub frame ~off:9 ~len:8;
                appendages;
              }
        | 'D' ->
            let appendages = parse_appendages frame ~base:9 ~optional:false in
            Disable_order_entry
              {
                user_ref = Wire.u32 frame 1;
                firm = Wire.sub frame ~off:5 ~len:4;
                appendages;
              }
        | 'E' ->
            let appendages = parse_appendages frame ~base:9 ~optional:false in
            Enable_order_entry
              {
                user_ref = Wire.u32 frame 1;
                firm = Wire.sub frame ~off:5 ~len:4;
                appendages;
              }
        | 'Q' ->
            let appendages = parse_appendages frame ~base:1 ~optional:true in
            Account_query { appendages }
        | kind -> raise (Wire.Decode_error (Wire.Unknown_type kind))
      in
      Ok body
    with Wire.Decode_error error -> Error error
end

module Outbound = struct
  type t =
    | System_event of { timestamp : int64; event_code : char }
    | Order_accepted of {
        timestamp : int64;
        user_ref : int64;
        side : char;
        quantity : int64;
        symbol : Wire.slice;
        price : int64;
        time_in_force : char;
        display : char;
        order_reference : int64;
        capacity : char;
        intermarket_sweep : char;
        cross_type : char;
        order_state : char;
        cl_ord_id : Wire.slice;
        appendages : appendages;
      }
    | Order_replaced of {
        timestamp : int64;
        original_user_ref : int64;
        user_ref : int64;
        side : char;
        quantity : int64;
        symbol : Wire.slice;
        price : int64;
        time_in_force : char;
        display : char;
        order_reference : int64;
        capacity : char;
        intermarket_sweep : char;
        cross_type : char;
        order_state : char;
        cl_ord_id : Wire.slice;
        appendages : appendages;
      }
    | Order_canceled of {
        timestamp : int64;
        user_ref : int64;
        quantity : int64;
        reason : char;
        appendages : appendages;
      }
    | Aiq_canceled of {
        timestamp : int64;
        user_ref : int64;
        decrement_shares : int64;
        reason : char;
        prevented_quantity : int64;
        execution_price : int64;
        liquidity_flag : char;
        aiq_strategy : char;
        appendages : appendages;
      }
    | Order_executed of {
        timestamp : int64;
        user_ref : int64;
        quantity : int64;
        price : int64;
        liquidity_flag : char;
        match_number : int64;
        appendages : appendages;
      }
    | Broken_trade of {
        timestamp : int64;
        user_ref : int64;
        match_number : int64;
        reason : char;
        cl_ord_id : Wire.slice;
        appendages : appendages;
      }
    | Rejected of {
        timestamp : int64;
        user_ref : int64;
        reason : int;
        cl_ord_id : Wire.slice;
        appendages : appendages;
      }
    | Cancel_pending of { timestamp : int64; user_ref : int64; appendages : appendages }
    | Cancel_reject of { timestamp : int64; user_ref : int64; appendages : appendages }
    | Order_priority_update of {
        timestamp : int64;
        user_ref : int64;
        price : int64;
        display : char;
        order_reference : int64;
        appendages : appendages;
      }
    | Order_modified of {
        timestamp : int64;
        user_ref : int64;
        side : char;
        quantity : int64;
        appendages : appendages;
      }
    | Order_restated of {
        timestamp : int64;
        user_ref : int64;
        reason : char;
        appendages : appendages;
      }
    | Mass_cancel_response of {
        timestamp : int64;
        user_ref : int64;
        firm : Wire.slice;
        symbol : Wire.slice;
        appendages : appendages;
      }
    | Disable_order_entry_response of {
        timestamp : int64;
        user_ref : int64;
        firm : Wire.slice;
        appendages : appendages;
      }
    | Enable_order_entry_response of {
        timestamp : int64;
        user_ref : int64;
        firm : Wire.slice;
        appendages : appendages;
      }
    | Account_query_response of {
        timestamp : int64;
        next_user_ref : int64;
        appendages : appendages;
      }

  let decode buffer ~off ~len =
    try
      let frame = Wire.slice buffer ~off ~len in
      if len = 0 then
        raise (Wire.Decode_error (Wire.Truncated { needed = 1; available = 0 }));
      let body =
        match Wire.char frame 0 with
        | 'S' ->
            Wire.require_length frame 10;
            System_event { timestamp = Wire.u64 frame 1; event_code = Wire.char frame 9 }
        | 'A' ->
            let appendages = parse_appendages frame ~base:62 ~optional:false in
            Order_accepted
              {
                timestamp = Wire.u64 frame 1;
                user_ref = Wire.u32 frame 9;
                side = Wire.char frame 13;
                quantity = Wire.u32 frame 14;
                symbol = Wire.sub frame ~off:18 ~len:8;
                price = Wire.u64 frame 26;
                time_in_force = Wire.char frame 34;
                display = Wire.char frame 35;
                order_reference = Wire.u64 frame 36;
                capacity = Wire.char frame 44;
                intermarket_sweep = Wire.char frame 45;
                cross_type = Wire.char frame 46;
                order_state = Wire.char frame 47;
                cl_ord_id = Wire.sub frame ~off:48 ~len:14;
                appendages;
              }
        | 'U' ->
            let appendages = parse_appendages frame ~base:66 ~optional:false in
            Order_replaced
              {
                timestamp = Wire.u64 frame 1;
                original_user_ref = Wire.u32 frame 9;
                user_ref = Wire.u32 frame 13;
                side = Wire.char frame 17;
                quantity = Wire.u32 frame 18;
                symbol = Wire.sub frame ~off:22 ~len:8;
                price = Wire.u64 frame 30;
                time_in_force = Wire.char frame 38;
                display = Wire.char frame 39;
                order_reference = Wire.u64 frame 40;
                capacity = Wire.char frame 48;
                intermarket_sweep = Wire.char frame 49;
                cross_type = Wire.char frame 50;
                order_state = Wire.char frame 51;
                cl_ord_id = Wire.sub frame ~off:52 ~len:14;
                appendages;
              }
        | 'C' ->
            let appendages = parse_appendages frame ~base:18 ~optional:true in
            Order_canceled
              {
                timestamp = Wire.u64 frame 1;
                user_ref = Wire.u32 frame 9;
                quantity = Wire.u32 frame 13;
                reason = Wire.char frame 17;
                appendages;
              }
        | 'D' ->
            let appendages = parse_appendages frame ~base:32 ~optional:true in
            Aiq_canceled
              {
                timestamp = Wire.u64 frame 1;
                user_ref = Wire.u32 frame 9;
                decrement_shares = Wire.u32 frame 13;
                reason = Wire.char frame 17;
                prevented_quantity = Wire.u32 frame 18;
                execution_price = Wire.u64 frame 22;
                liquidity_flag = Wire.char frame 30;
                aiq_strategy = Wire.char frame 31;
                appendages;
              }
        | 'E' ->
            let appendages = parse_appendages frame ~base:34 ~optional:false in
            Order_executed
              {
                timestamp = Wire.u64 frame 1;
                user_ref = Wire.u32 frame 9;
                quantity = Wire.u32 frame 13;
                price = Wire.u64 frame 17;
                liquidity_flag = Wire.char frame 25;
                match_number = Wire.u64 frame 26;
                appendages;
              }
        | 'B' ->
            let appendages = parse_appendages frame ~base:36 ~optional:true in
            Broken_trade
              {
                timestamp = Wire.u64 frame 1;
                user_ref = Wire.u32 frame 9;
                match_number = Wire.u64 frame 13;
                reason = Wire.char frame 21;
                cl_ord_id = Wire.sub frame ~off:22 ~len:14;
                appendages;
              }
        | 'J' ->
            let appendages = parse_appendages frame ~base:29 ~optional:true in
            Rejected
              {
                timestamp = Wire.u64 frame 1;
                user_ref = Wire.u32 frame 9;
                reason = Wire.u16 frame 13;
                cl_ord_id = Wire.sub frame ~off:15 ~len:14;
                appendages;
              }
        | 'P' ->
            let appendages = parse_appendages frame ~base:13 ~optional:true in
            Cancel_pending
              { timestamp = Wire.u64 frame 1; user_ref = Wire.u32 frame 9; appendages }
        | 'I' ->
            let appendages = parse_appendages frame ~base:13 ~optional:true in
            Cancel_reject
              { timestamp = Wire.u64 frame 1; user_ref = Wire.u32 frame 9; appendages }
        | 'T' ->
            let appendages = parse_appendages frame ~base:30 ~optional:true in
            Order_priority_update
              {
                timestamp = Wire.u64 frame 1;
                user_ref = Wire.u32 frame 9;
                price = Wire.u64 frame 13;
                display = Wire.char frame 21;
                order_reference = Wire.u64 frame 22;
                appendages;
              }
        | 'M' ->
            let appendages = parse_appendages frame ~base:18 ~optional:true in
            Order_modified
              {
                timestamp = Wire.u64 frame 1;
                user_ref = Wire.u32 frame 9;
                side = Wire.char frame 13;
                quantity = Wire.u32 frame 14;
                appendages;
              }
        | 'R' ->
            let appendages = parse_appendages frame ~base:14 ~optional:false in
            Order_restated
              {
                timestamp = Wire.u64 frame 1;
                user_ref = Wire.u32 frame 9;
                reason = Wire.char frame 13;
                appendages;
              }
        | 'X' ->
            let appendages = parse_appendages frame ~base:25 ~optional:false in
            Mass_cancel_response
              {
                timestamp = Wire.u64 frame 1;
                user_ref = Wire.u32 frame 9;
                firm = Wire.sub frame ~off:13 ~len:4;
                symbol = Wire.sub frame ~off:17 ~len:8;
                appendages;
              }
        | 'G' ->
            let appendages = parse_appendages frame ~base:17 ~optional:false in
            Disable_order_entry_response
              {
                timestamp = Wire.u64 frame 1;
                user_ref = Wire.u32 frame 9;
                firm = Wire.sub frame ~off:13 ~len:4;
                appendages;
              }
        | 'K' ->
            let appendages = parse_appendages frame ~base:17 ~optional:false in
            Enable_order_entry_response
              {
                timestamp = Wire.u64 frame 1;
                user_ref = Wire.u32 frame 9;
                firm = Wire.sub frame ~off:13 ~len:4;
                appendages;
              }
        | 'Q' ->
            let appendages = parse_appendages frame ~base:13 ~optional:true in
            Account_query_response
              {
                timestamp = Wire.u64 frame 1;
                next_user_ref = Wire.u32 frame 9;
                appendages;
              }
        | kind -> raise (Wire.Decode_error (Wire.Unknown_type kind))
      in
      Ok body
    with Wire.Decode_error error -> Error error
end
