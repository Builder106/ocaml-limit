(** {1 Pre-Allocated Open-Addressing Hashtable: int → 'a}

    Used in place of stdlib [Map.Make(Int)] for [book_side.levels].

    {b Why}: stdlib [Map.add] rebuilds ~log(n) tree-spine nodes per call. Under bench's
    first-100-prices warmup that allocates ~36 KB and accounts for the bulk of cold-path
    GC pressure. This module trades the Map's O(log n) ordered access (which the
    price-level DLL on each [book_side] already provides via [pl_next_level]) for O(1)
    average-case unordered lookup with zero heap allocation in [find] and [add].

    {b Design}: open addressing with linear probing. Keys and values live in two parallel
    pre-allocated arrays. [empty_key = min_int] is the sentinel for unused slots; real
    prices are bounded [≥ config.min_price] (≥1 by default) by the risk-band check, so
    [min_int] cannot collide with a live key.

    {b Sizing}: capacity is fixed at create time and rounded up to a power of two (so
    [hash mod capacity] becomes a single [land mask]). There is no resize path — once the
    table is full, [add] raises [Failure]. Choose
    [capacity ≥ 4 × expected_distinct_prices] for a ≤25% load factor and minimal probing.

    Pitfall ([2026-05-10]): a prior version omitted the bounds check and looped forever on
    a full table, pegging CPU at 100% and freezing the Lwt scheduler. The demo bot's
    drifting mid_price slowly produces unique prices over hours; on the deployed VM the
    server hung after ~3h once accumulated levels approached the 8192-slot cap.

    {b Not supported}: removal — the engine's lazy-keep policy never removes levels from
    the index; exhausted levels stay resident for later resurrection. Iteration — use the
    [book_side.best_level] DLL via [pl_next_level] instead. *)

type 'a t = { keys : int array; values : 'a array; mask : int }

let empty_key = min_int

(** [create min_capacity ~empty_value] returns a fresh table whose capacity is the
    smallest power of two ≥ [max 16 min_capacity]. [empty_value] fills the values array
    initially; it is overwritten on every [add] before being read, so any well-typed
    placeholder works. *)
let create min_capacity ~empty_value =
  let rec next_pow2 n = if n >= min_capacity then n else next_pow2 (n * 2) in
  let cap = next_pow2 16 in
  { keys = Array.make cap empty_key; values = Array.make cap empty_value; mask = cap - 1 }

(* Knuth's multiplicative hash. Constant is the closest int to
   [golden_ratio * 2^32]; works well even for sequential integer keys
   like ours (prices clustered in a small range). *)
let[@inline] hash key mask = key * 2654435769 land mask

(* [probes] is bounded by [capacity] to prevent an infinite loop on a
   full or wholly-collided table — see the pitfall note in the module
   docstring. Bounded recursion costs nothing on the hot (≤1-probe)
   path. *)
let rec find_aux t key idx probes =
  if probes > t.mask then raise Not_found
  else
    let k = t.keys.(idx) in
    if k = key then t.values.(idx)
    else if k = empty_key then raise Not_found
    else find_aux t key ((idx + 1) land t.mask) (probes + 1)

(** Raises [Not_found] if [key] is not present. *)
let find t key = find_aux t key (hash key t.mask) 0

let rec add_aux t key value idx probes =
  if probes > t.mask then
    failwith "Price_index: capacity exceeded — increase price_index_capacity"
  else
    let k = t.keys.(idx) in
    if k = empty_key then (
      t.keys.(idx) <- key;
      t.values.(idx) <- value)
    else if k = key then t.values.(idx) <- value
    else add_aux t key value ((idx + 1) land t.mask) (probes + 1)

(** Inserts or overwrites. No allocation. Raises [Failure] if the table is full (every
    slot probed without finding empty/match). *)
let add t key value = add_aux t key value (hash key t.mask) 0
