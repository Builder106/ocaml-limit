(** {1 The Matching Engine Core}

    High-performance exchange-grade matching logic with O(log n) price-level
    access and O(1) FIFO order execution.

    {b Features}:
    - Full Limit Order Book (LOB) maintenance (Bids/Asks).
    - Limit, Iceberg, and Post-Only order types.
    - Zero-allocation hot path (reuses Pool nodes).
    - Price-Time Priority matching algorithm. *)

open Types
module Pool = Pool
module Risk = Risk

(** {2 Pre-Allocated Result Values}

    The matching hot path returns a [(unit, Risk.risk_result) result]
    on every call. Building [Ok ()] / [Error r] fresh per call boxes
    a 1-tuple block (~16B) into the minor heap and is the dominant
    source of GC pressure under bench load (~64 minor collections /
    1M orders). Pre-allocating the four possible return values once
    at module load lets [submit] return a shared reference each time. *)

let r_ok = Ok ()
let r_reject_price_band : (unit, Risk.risk_result) result = Error Risk.Reject_price_band
let r_reject_max_qty : (unit, Risk.risk_result) result = Error Risk.Reject_max_qty
let r_reject_position_limit : (unit, Risk.risk_result) result = Error Risk.Reject_position_limit

(** {2 Engine State} *)

type t = {
    book : order_book;
    pool : Pool.t;
    risk : Risk.position_tracker;
    config : config;
    mutable last_match_price : price;
}

(** Capacity of the per-side [Price_index] hashtable. Bench uses 100
    distinct prices; this allows up to ~16k at a 25% load factor
    without resize (which the table doesn't implement — instead it
    raises [Failure] on overflow per the bounds check in [Price_index]).

    Sized generously because the demo bot ([bin/server.ml]) does a
    random-walk on its mid_price and can accumulate thousands of
    unique price levels over many hours. An earlier 8192 cap brought
    down the live VM after ~3h. 65536 buys orders-of-magnitude more
    runway at ~512 KB per side memory cost. *)
let price_index_capacity = 65536

(** [create config] initializes a fresh matching engine with pre-allocated pools. *)
let create config =
  let pool = Pool.create config.max_orders in
  let mk_side () = {
    levels = Price_index.create price_index_capacity ~empty_value:sentinel_level;
    best_level = sentinel_level;
  } in
  let book = {
    bids = mk_side ();
    asks = mk_side ();
    nodes = pool.nodes;
    next_node = 0;
  } in
  { book; pool; risk = Risk.create_tracker (); config; last_match_price = 0 }

(** {2 Price Level Management} *)

(* Walk worse from [lvl] until the next level would be less aggressive
   than [new_price] (or end-of-list). Lifted to a top-level function
   so the recursive call doesn't allocate a closure capturing [side]
   and [new_price] per [link_level] invocation. *)
let rec find_link_pred side new_price lvl =
  let next = lvl.pl_next_level in
  if next == sentinel_level then lvl
  else
    let new_beats_next =
      match side with
      | Buy -> new_price > next.pl_price
      | Ask -> new_price < next.pl_price
    in
    if new_beats_next then lvl else find_link_pred side new_price next

(* Insert [new_level] into the doubly-linked list of price levels
   for [book_side], sorted by aggressiveness (best at head). Walks
   from head — O(n) in number of distinct price levels but only
   fires on the cold path (first touch of a price), not per order. *)
let link_level side book_side new_level =
  let new_price = new_level.pl_price in
  if book_side.best_level == sentinel_level then begin
    new_level.pl_prev_level <- sentinel_level;
    new_level.pl_next_level <- sentinel_level;
    book_side.best_level <- new_level
  end else
    let new_beats_best =
      match side with
      | Buy -> new_price > book_side.best_level.pl_price
      | Ask -> new_price < book_side.best_level.pl_price
    in
    if new_beats_best then begin
      new_level.pl_prev_level <- sentinel_level;
      new_level.pl_next_level <- book_side.best_level;
      book_side.best_level.pl_prev_level <- new_level;
      book_side.best_level <- new_level
    end else begin
      let pred = find_link_pred side new_price book_side.best_level in
      let succ = pred.pl_next_level in
      new_level.pl_prev_level <- pred;
      new_level.pl_next_level <- succ;
      pred.pl_next_level <- new_level;
      if succ != sentinel_level then
        succ.pl_prev_level <- new_level
    end

(* [Price_index.find] raises [Not_found] on miss (no [Some]/[None]
   allocation) and is alloc-free on hit. The miss path allocates the
   new [price_level] record and links it into the side's DLL — that
   record allocation is unavoidable; everything else here is in-place. *)
let get_or_create_level side book_side price =
  match Price_index.find book_side.levels price with
  | level -> level
  | exception Not_found ->
      let level = {
        pl_price = price;
        pl_total_qty = 0;
        pl_order_count = 0;
        pl_head = -1;
        pl_tail = -1;
        pl_prev_level = sentinel_level;
        pl_next_level = sentinel_level;
      } in
      Price_index.add book_side.levels price level;
      link_level side book_side level;
      level

(** {2 The Matching Loop}

    [fill_loop] is a top-level recursive function rather than a closure
    inside [match_aggressive], so the recursive self-call compiles to a
    jump with no per-submit closure allocation.

    Level exhaustion advances via the doubly-linked list of price levels
    ([pl_next_level]) instead of [PriceMap.max_binding_opt] /
    [min_binding_opt] — those allocate a [Some (k, v)] tuple per call,
    which under bench load (alternating Buy/Ask at the same prices,
    causing one match-and-clear cycle per pair) is a significant
    residual allocator. *)

let rec fill_loop engine order on_fill opposite_book =
  if order.remaining_qty <= 0 then ()
  else if opposite_book.best_level == sentinel_level then ()
  else
    let best_level = opposite_book.best_level in
    let best_price = best_level.pl_price in
    let can_match =
      match order.side with Buy -> order.price >= best_price | Ask -> order.price <= best_price
    in

    if not can_match then ()
    else
      let head_node_idx = best_level.pl_head in

      if head_node_idx = -1 then (
        (* Level exhausted. Advance [best_level] via the DLL but leave
           the empty level in [PriceMap] and untouched in the DLL —
           [PriceMap.remove] would rebuild ~log(n) tree nodes per call,
           ~24KB per 1M orders under bench load. The empty level just
           sits in place; if a new order at that price arrives later,
           [get_or_create_level] returns it and [submit]'s resurrection
           logic re-promotes [best_level] if applicable. The level's
           [pl_prev_level] / [pl_next_level] stay pointing at their
           original neighbors so the DLL doesn't need patching either. *)
        opposite_book.best_level <- best_level.pl_next_level;
        fill_loop engine order on_fill opposite_book)
      else
        let node = Pool.get engine.pool head_node_idx in
        let passive = node.qn_order in
        let match_qty = min order.remaining_qty passive.remaining_qty in

        order.remaining_qty <- order.remaining_qty - match_qty;
        passive.remaining_qty <- passive.remaining_qty - match_qty;
        best_level.pl_total_qty <- best_level.pl_total_qty - match_qty;
        engine.last_match_price <- best_price;
        Risk.update_position engine.risk order.side match_qty;

        on_fill passive.id order.id best_price match_qty order.timestamp;

        if passive.remaining_qty = 0 then (
          passive.status <- Filled;
          best_level.pl_head <- node.qn_next;
          if best_level.pl_head = -1 then best_level.pl_tail <- -1
          else (Pool.get engine.pool best_level.pl_head).qn_prev <- -1;
          best_level.pl_order_count <- best_level.pl_order_count - 1;
          Pool.free engine.pool head_node_idx;

          match passive.order_type with
          | Iceberg { visible_qty; total_qty } ->
              let remaining_hidden = total_qty - passive.original_qty in
              if remaining_hidden > 0 then (
                let reload_qty = min visible_qty remaining_hidden in
                let reloaded_order =
                  {
                    passive with
                    remaining_qty = reload_qty;
                    original_qty = reload_qty;
                    order_type = Iceberg { visible_qty; total_qty = remaining_hidden };
                  }
                in
                let new_idx = Pool.alloc engine.pool reloaded_order in
                let tail_idx = best_level.pl_tail in
                (if tail_idx = -1 then begin
                   best_level.pl_head <- new_idx;
                   best_level.pl_tail <- new_idx
                 end else begin
                   let tail_node = Pool.get engine.pool tail_idx in
                   tail_node.qn_next <- new_idx;
                   (Pool.get engine.pool new_idx).qn_prev <- tail_idx;
                   best_level.pl_tail <- new_idx
                 end);
                best_level.pl_total_qty <- best_level.pl_total_qty + reload_qty;
                best_level.pl_order_count <- best_level.pl_order_count + 1)
              else ()
          | _ -> ())
        else ();
        fill_loop engine order on_fill opposite_book

let[@inline] match_aggressive engine order on_fill =
  let opposite_book = if order.side = Buy then engine.book.asks else engine.book.bids in
  fill_loop engine order on_fill opposite_book

(** {2 Public API} *)

let submit engine order on_fill =
  match Risk.validate engine.config engine.risk order with
  | Risk.Reject_price_band ->
      order.status <- Rejected;
      r_reject_price_band
  | Risk.Reject_max_qty ->
      order.status <- Rejected;
      r_reject_max_qty
  | Risk.Reject_position_limit ->
      order.status <- Rejected;
      r_reject_position_limit
  | Risk.Pass ->
      let opposite_book = if order.side = Buy then engine.book.asks else engine.book.bids in
      let best_opp_level = opposite_book.best_level in
      let would_match =
        if best_opp_level == sentinel_level then false
        else
          let best_opp = best_opp_level.pl_price in
          match order.side with Buy -> order.price >= best_opp | Ask -> order.price <= best_opp
      in

      if order.order_type = Post_only && would_match then (
        order.status <- Rejected;
        r_reject_price_band)
      else (
        match_aggressive engine order on_fill;
        if order.remaining_qty > 0 then (
          let book_side = if order.side = Buy then engine.book.bids else engine.book.asks in
          let level = get_or_create_level order.side book_side order.price in
          let was_empty = level.pl_head = -1 in
          let node_idx = Pool.alloc engine.pool order in
          let tail_idx = level.pl_tail in
          (* begin/end here is load-bearing: without it, OCaml extends
             the else's `let tail_node = ... in <seq>` body to swallow
             every subsequent semicolon-separated statement, so the
             pl_total_qty / pl_order_count updates AND the resurrection
             check below all silently move INTO the else branch and
             never execute on the [tail_idx = -1] path. *)
          (if tail_idx = -1 then begin
             level.pl_head <- node_idx;
             level.pl_tail <- node_idx
           end else begin
             let tail_node = Pool.get engine.pool tail_idx in
             tail_node.qn_next <- node_idx;
             (Pool.get engine.pool node_idx).qn_prev <- tail_idx;
             level.pl_tail <- node_idx
           end);
          level.pl_total_qty <- level.pl_total_qty + order.remaining_qty;
          level.pl_order_count <- level.pl_order_count + 1;
          (* Resurrection: if the level was empty (lazily kept after a
             prior exhaustion) and is now repopulated, [best_level] may
             have moved past it. Promote back if this level is more
             aggressive than the current best. The DLL pointers are
             still valid from the original [link_level] call. *)
          if was_empty then begin
            let cur_best = book_side.best_level in
            let promote =
              cur_best == sentinel_level
              || (match order.side with
                  | Buy -> level.pl_price > cur_best.pl_price
                  | Ask -> level.pl_price < cur_best.pl_price)
            in
            if promote then book_side.best_level <- level
          end)
        else if order.status = Active then order.status <- Filled;
        r_ok)

(** [cancel engine order_id price side] removes an order from the book.
    O(1) average to find the price level via [Price_index], then O(k)
    to scan the level's FIFO queue for the order id. *)
let cancel engine order_id price side =
    let book_side = if side = Buy then engine.book.bids else engine.book.asks in
    match Price_index.find book_side.levels price with
    | exception Not_found -> false
    | level ->
        (* Scan the level (O(k)) — in a production system, we'd use a 
           hash-map of order_id -> node_idx for O(1) cancel. *)
        let rec find_and_remove idx =
            if idx = -1 then false
            else
                let node = Pool.get engine.pool idx in
                if node.qn_order.id = order_id then (
                    let prev_idx = node.qn_prev in
                    let next_idx = node.qn_next in
                    
                    if prev_idx <> -1 then (Pool.get engine.pool prev_idx).qn_next <- next_idx
                    else level.pl_head <- next_idx;
                    
                    if next_idx <> -1 then (Pool.get engine.pool next_idx).qn_prev <- prev_idx
                    else level.pl_tail <- prev_idx;
                    
                    level.pl_total_qty <- level.pl_total_qty - node.qn_order.remaining_qty;
                    level.pl_order_count <- level.pl_order_count - 1;
                    node.qn_order.status <- Cancelled;
                    Pool.free engine.pool idx;
                    true
                ) else find_and_remove node.qn_next
        in
        find_and_remove level.pl_head
