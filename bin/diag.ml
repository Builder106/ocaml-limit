open Ocaml_lob
open Types
module Engine = Engine

let measure name num_orders =
  let engine = Engine.create default_config in
  let pool = Array.init num_orders (fun i ->
    let side = if i mod 2 = 0 then Buy else Ask in
    let price = 100_000 + (i mod 100) in
    make_order ~id:i ~side ~price ~qty:10 ~order_type:Limit ~timestamp:0)
  in
  let dummy_on_fill _ _ _ _ _ = () in
  (* Use only Gc.minor_words — Gc.stat allocates a 17-field record and
     triggers minor collections, contaminating measurement. *)
  let mw_before = Gc.minor_words () in
  for i = 0 to num_orders - 1 do
    ignore (Engine.submit engine pool.(i) dummy_on_fill)
  done;
  let mw_after = Gc.minor_words () in
  let words = mw_after -. mw_before in
  Printf.printf "%s: %d orders -> %.0f minor words (%.4f bytes/order)\n"
    name num_orders words (words *. 8.0 /. float_of_int (max 1 num_orders))

let () =
  measure "0" 0;
  measure "10k" 10_000;
  measure "100k" 100_000;
  measure "1M" 1_000_000
