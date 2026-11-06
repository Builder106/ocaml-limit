(** Benchmarking suite and statistical latency percentile runner *)

open Ocaml_lob

type flow_result = {
  flow : Synthetic_flow.flow_kind;
  summary : Stats.summary;
  bytes_per_op : float;
  minor_words : float;
  minor_collections : int;
  major_collections : int;
}

type suite_result = {
  results : flow_result list;
  total_orders : int;
  elapsed_sec : float;
}

val run_flow : Synthetic_flow.flow_kind -> n:int -> warmup:int -> flow_result

val run_suite :
  ?flows:Synthetic_flow.flow_kind list -> n:int -> warmup:int -> unit -> suite_result

val print_table : suite_result -> unit
val print_markdown : suite_result -> unit
val to_json : suite_result -> string
val main : unit -> unit
