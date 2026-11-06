(** Shared binary payload primitives. No I/O or floating-point conversion. *)
type error =
  | Invalid_bounds
  | Truncated of { needed : int; available : int }
  | Invalid_length of { expected : int; actual : int }
  | Unknown_type of char
  | Invalid_appendage of int

exception Decode_error of error

type slice = private { buffer : string; off : int; len : int }
(** Immutable, zero-copy view retaining its source string. *)

val slice : string -> off:int -> len:int -> slice
(** Bounds-checked operations raise [Decode_error]. Offsets are slice-relative. *)

val sub : slice -> off:int -> len:int -> slice
val to_string : slice -> string
val require_length : slice -> int -> unit
val char : slice -> int -> char
val u8 : slice -> int -> int
val u16 : slice -> int -> int
val u32 : slice -> int -> int64
val i32 : slice -> int -> int32
val u48 : slice -> int -> int64

val u64 : slice -> int -> int64
(** All 64 wire bits are preserved. Use [Int64.unsigned_compare] for unsigned identifiers,
    quantities and prices. *)
