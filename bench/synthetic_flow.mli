(** Synthetic order flow generators for exchange benchmarking *)

open Ocaml_lob

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

val flow_name : flow_kind -> string
val flow_description : flow_kind -> string
val all_flows : flow_kind list
val parse_flow : string -> flow_kind option

(** Engine-level synthetic order actions *)
type engine_action = Submit of Types.order | Cancel of int * Types.price * Types.side

type wire_action = { off : int; len : int; price : Types.price; side : Types.side }
(** Wire-to-engine synthetic order action metadata *)

(** Pre-generated synthetic data for a benchmark run *)
type t =
  | EngineFlow of engine_action array
  | ProtocolFlow of string * (int * int) array * [ `Itch | `OuchInbound | `OuchOutbound ]
  | WireToEngineFlow of string * wire_action array

val generate : flow_kind -> n:int -> t
