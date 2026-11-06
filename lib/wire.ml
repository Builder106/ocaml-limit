type error =
  | Invalid_bounds
  | Truncated of { needed : int; available : int }
  | Invalid_length of { expected : int; actual : int }
  | Unknown_type of char
  | Invalid_appendage of int

exception Decode_error of error

type slice = { buffer : string; off : int; len : int }

let check_bounds size off len =
  if off < 0 || len < 0 || off > size || len > size - off then
    raise (Decode_error Invalid_bounds)

let slice buffer ~off ~len =
  check_bounds (String.length buffer) off len;
  { buffer; off; len }

let sub s ~off ~len =
  check_bounds s.len off len;
  { buffer = s.buffer; off = s.off + off; len }

let to_string s = String.sub s.buffer s.off s.len

let require_length s expected =
  if s.len < expected then
    raise (Decode_error (Truncated { needed = expected; available = s.len }))
  else if s.len > expected then
    raise (Decode_error (Invalid_length { expected; actual = s.len }))

let char s off =
  check_bounds s.len off 1;
  String.get s.buffer (s.off + off)

let u8 s off = Char.code (char s off)

let u16 s off =
  check_bounds s.len off 2;
  String.get_uint16_be s.buffer (s.off + off)

let i32 s off =
  check_bounds s.len off 4;
  String.get_int32_be s.buffer (s.off + off)

let u32 s off = Int64.logand (Int64.of_int32 (i32 s off)) 0xffff_ffffL

let u48 s off =
  check_bounds s.len off 6;
  Int64.logor (Int64.shift_left (Int64.of_int (u16 s off)) 32) (u32 s (off + 2))

let u64 s off =
  check_bounds s.len off 8;
  String.get_int64_be s.buffer (s.off + off)
