(** Nasdaq TotalView-ITCH 5.0 payloads. Text retains the immutable input string. Prices
    use 4 decimal places, except MWCB levels which use 8. Timestamps are nanoseconds since
    midnight; 64-bit unsigned fields retain their raw bits. Alpha codes are preserved
    verbatim; business-rule validation is separate. *)
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

val decode : string -> off:int -> len:int -> (t, Wire.error) result
(** Decode exactly one payload within the supplied window. Framing (including BinaryFILE
    length prefixes, SoupBinTCP and MoldUDP64) belongs to the caller. Malformed input
    returns [Error]; no reads extend beyond the window. *)
