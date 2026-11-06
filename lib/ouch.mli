type appendages
(** Nasdaq US OUCH 5.0, October 2025 revision, both wire directions. Exactly one unframed
    payload is decoded. Alpha codes remain verbatim; session, business-rule and
    order-entry validation are caller concerns. Text fields are zero-copy immutable
    slices. Prices have 4 decimal places; unsigned 64-bit fields retain all bits (see
    [Wire.u64]). *)

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

val iter_appendages : (appendage -> unit) -> appendages -> unit
(** Visits validated TagValue elements in wire order, preserving duplicates and unknown
    tags. Signed offsets are 32-bit fixed-point integers. *)

module Inbound : sig
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

  val decode : string -> off:int -> len:int -> (t, Wire.error) result
end

module Outbound : sig
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

  val decode : string -> off:int -> len:int -> (t, Wire.error) result
end
