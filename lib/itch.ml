type body =
  | System_event of { event_code : char }
  | Stock_directory of {
      stock : Wire.slice;
      market_category : char;
      financial_status : char;
      round_lot_size : int64;
      round_lots_only : char;
      issue_classification : char;
      issue_sub_type : Wire.slice;
      authenticity : char;
      short_sale_threshold : char;
      ipo_flag : char;
      luld_reference : char;
      etp_flag : char;
      etp_leverage : int64;
      inverse_indicator : char;
    }
  | Stock_trading_action of {
      stock : Wire.slice;
      trading_state : char;
      reserved : char;
      reason : Wire.slice;
    }
  | Reg_sho_restriction of { stock : Wire.slice; action : char }
  | Market_participant_position of {
      mpid : Wire.slice;
      stock : Wire.slice;
      primary_market_maker : char;
      market_maker_mode : char;
      participant_state : char;
    }
  | Mwcb_decline_levels of { level_1 : int64; level_2 : int64; level_3 : int64 }
  | Mwcb_status of { breached_level : char }
  | Ipo_quoting_period of {
      stock : Wire.slice;
      release_time : int64;
      release_qualifier : char;
      ipo_price : int64;
    }
  | Luld_auction_collar of {
      stock : Wire.slice;
      reference_price : int64;
      upper_price : int64;
      lower_price : int64;
      extension : int64;
    }
  | Operational_halt of { stock : Wire.slice; market_code : char; action : char }
  | Add_order of {
      order_reference : int64;
      side : char;
      shares : int64;
      stock : Wire.slice;
      price : int64;
    }
  | Add_order_attributed of {
      order_reference : int64;
      side : char;
      shares : int64;
      stock : Wire.slice;
      price : int64;
      attribution : Wire.slice;
    }
  | Order_executed of {
      order_reference : int64;
      executed_shares : int64;
      match_number : int64;
    }
  | Order_executed_with_price of {
      order_reference : int64;
      executed_shares : int64;
      match_number : int64;
      printable : char;
      execution_price : int64;
    }
  | Order_cancel of { order_reference : int64; cancelled_shares : int64 }
  | Order_delete of { order_reference : int64 }
  | Order_replace of {
      original_reference : int64;
      new_reference : int64;
      shares : int64;
      price : int64;
    }
  | Trade of {
      order_reference : int64;
      side : char;
      shares : int64;
      stock : Wire.slice;
      price : int64;
      match_number : int64;
    }
  | Cross_trade of {
      shares : int64;
      stock : Wire.slice;
      cross_price : int64;
      match_number : int64;
      cross_type : char;
    }
  | Broken_trade of { match_number : int64 }
  | Net_order_imbalance of {
      paired_shares : int64;
      imbalance_shares : int64;
      imbalance_direction : char;
      stock : Wire.slice;
      far_price : int64;
      near_price : int64;
      reference_price : int64;
      cross_type : char;
      price_variation : char;
    }
  | Retail_price_improvement of { stock : Wire.slice; interest_flag : char }
  | Direct_listing_price_discovery of {
      stock : Wire.slice;
      eligibility : char;
      minimum_price : int64;
      maximum_price : int64;
      near_execution_price : int64;
      near_execution_time : int64;
      lower_collar : int64;
      upper_collar : int64;
    }

type t = { stock_locate : int; tracking_number : int; timestamp : int64; body : body }

let decode buffer ~off ~len =
  try
    let frame = Wire.slice buffer ~off ~len in
    if len = 0 then
      raise (Wire.Decode_error (Wire.Truncated { needed = 1; available = 0 }));
    let body =
      match Wire.char frame 0 with
      | 'S' ->
          Wire.require_length frame 12;
          System_event { event_code = Wire.char frame 11 }
      | 'R' ->
          Wire.require_length frame 39;
          Stock_directory
            {
              stock = Wire.sub frame ~off:11 ~len:8;
              market_category = Wire.char frame 19;
              financial_status = Wire.char frame 20;
              round_lot_size = Wire.u32 frame 21;
              round_lots_only = Wire.char frame 25;
              issue_classification = Wire.char frame 26;
              issue_sub_type = Wire.sub frame ~off:27 ~len:2;
              authenticity = Wire.char frame 29;
              short_sale_threshold = Wire.char frame 30;
              ipo_flag = Wire.char frame 31;
              luld_reference = Wire.char frame 32;
              etp_flag = Wire.char frame 33;
              etp_leverage = Wire.u32 frame 34;
              inverse_indicator = Wire.char frame 38;
            }
      | 'H' ->
          Wire.require_length frame 25;
          Stock_trading_action
            {
              stock = Wire.sub frame ~off:11 ~len:8;
              trading_state = Wire.char frame 19;
              reserved = Wire.char frame 20;
              reason = Wire.sub frame ~off:21 ~len:4;
            }
      | 'Y' ->
          Wire.require_length frame 20;
          Reg_sho_restriction
            { stock = Wire.sub frame ~off:11 ~len:8; action = Wire.char frame 19 }
      | 'L' ->
          Wire.require_length frame 26;
          Market_participant_position
            {
              mpid = Wire.sub frame ~off:11 ~len:4;
              stock = Wire.sub frame ~off:15 ~len:8;
              primary_market_maker = Wire.char frame 23;
              market_maker_mode = Wire.char frame 24;
              participant_state = Wire.char frame 25;
            }
      | 'V' ->
          Wire.require_length frame 35;
          Mwcb_decline_levels
            {
              level_1 = Wire.u64 frame 11;
              level_2 = Wire.u64 frame 19;
              level_3 = Wire.u64 frame 27;
            }
      | 'W' ->
          Wire.require_length frame 12;
          Mwcb_status { breached_level = Wire.char frame 11 }
      | 'K' ->
          Wire.require_length frame 28;
          Ipo_quoting_period
            {
              stock = Wire.sub frame ~off:11 ~len:8;
              release_time = Wire.u32 frame 19;
              release_qualifier = Wire.char frame 23;
              ipo_price = Wire.u32 frame 24;
            }
      | 'J' ->
          Wire.require_length frame 35;
          Luld_auction_collar
            {
              stock = Wire.sub frame ~off:11 ~len:8;
              reference_price = Wire.u32 frame 19;
              upper_price = Wire.u32 frame 23;
              lower_price = Wire.u32 frame 27;
              extension = Wire.u32 frame 31;
            }
      | 'h' ->
          Wire.require_length frame 21;
          Operational_halt
            {
              stock = Wire.sub frame ~off:11 ~len:8;
              market_code = Wire.char frame 19;
              action = Wire.char frame 20;
            }
      | 'A' ->
          Wire.require_length frame 36;
          Add_order
            {
              order_reference = Wire.u64 frame 11;
              side = Wire.char frame 19;
              shares = Wire.u32 frame 20;
              stock = Wire.sub frame ~off:24 ~len:8;
              price = Wire.u32 frame 32;
            }
      | 'F' ->
          Wire.require_length frame 40;
          Add_order_attributed
            {
              order_reference = Wire.u64 frame 11;
              side = Wire.char frame 19;
              shares = Wire.u32 frame 20;
              stock = Wire.sub frame ~off:24 ~len:8;
              price = Wire.u32 frame 32;
              attribution = Wire.sub frame ~off:36 ~len:4;
            }
      | 'E' ->
          Wire.require_length frame 31;
          Order_executed
            {
              order_reference = Wire.u64 frame 11;
              executed_shares = Wire.u32 frame 19;
              match_number = Wire.u64 frame 23;
            }
      | 'C' ->
          Wire.require_length frame 36;
          Order_executed_with_price
            {
              order_reference = Wire.u64 frame 11;
              executed_shares = Wire.u32 frame 19;
              match_number = Wire.u64 frame 23;
              printable = Wire.char frame 31;
              execution_price = Wire.u32 frame 32;
            }
      | 'X' ->
          Wire.require_length frame 23;
          Order_cancel
            { order_reference = Wire.u64 frame 11; cancelled_shares = Wire.u32 frame 19 }
      | 'D' ->
          Wire.require_length frame 19;
          Order_delete { order_reference = Wire.u64 frame 11 }
      | 'U' ->
          Wire.require_length frame 35;
          Order_replace
            {
              original_reference = Wire.u64 frame 11;
              new_reference = Wire.u64 frame 19;
              shares = Wire.u32 frame 27;
              price = Wire.u32 frame 31;
            }
      | 'P' ->
          Wire.require_length frame 44;
          Trade
            {
              order_reference = Wire.u64 frame 11;
              side = Wire.char frame 19;
              shares = Wire.u32 frame 20;
              stock = Wire.sub frame ~off:24 ~len:8;
              price = Wire.u32 frame 32;
              match_number = Wire.u64 frame 36;
            }
      | 'Q' ->
          Wire.require_length frame 40;
          Cross_trade
            {
              shares = Wire.u64 frame 11;
              stock = Wire.sub frame ~off:19 ~len:8;
              cross_price = Wire.u32 frame 27;
              match_number = Wire.u64 frame 31;
              cross_type = Wire.char frame 39;
            }
      | 'B' ->
          Wire.require_length frame 19;
          Broken_trade { match_number = Wire.u64 frame 11 }
      | 'I' ->
          Wire.require_length frame 50;
          Net_order_imbalance
            {
              paired_shares = Wire.u64 frame 11;
              imbalance_shares = Wire.u64 frame 19;
              imbalance_direction = Wire.char frame 27;
              stock = Wire.sub frame ~off:28 ~len:8;
              far_price = Wire.u32 frame 36;
              near_price = Wire.u32 frame 40;
              reference_price = Wire.u32 frame 44;
              cross_type = Wire.char frame 48;
              price_variation = Wire.char frame 49;
            }
      | 'N' ->
          Wire.require_length frame 20;
          Retail_price_improvement
            { stock = Wire.sub frame ~off:11 ~len:8; interest_flag = Wire.char frame 19 }
      | 'O' ->
          Wire.require_length frame 48;
          Direct_listing_price_discovery
            {
              stock = Wire.sub frame ~off:11 ~len:8;
              eligibility = Wire.char frame 19;
              minimum_price = Wire.u32 frame 20;
              maximum_price = Wire.u32 frame 24;
              near_execution_price = Wire.u32 frame 28;
              near_execution_time = Wire.u64 frame 32;
              lower_collar = Wire.u32 frame 40;
              upper_collar = Wire.u32 frame 44;
            }
      | kind -> raise (Wire.Decode_error (Wire.Unknown_type kind))
    in
    Ok
      {
        stock_locate = Wire.u16 frame 1;
        tracking_number = Wire.u16 frame 3;
        timestamp = Wire.u48 frame 5;
        body;
      }
  with Wire.Decode_error error -> Error error
