# Binary payload decoders

The v1.2 parser milestone covers standalone, synchronous decoding of Nasdaq US
TotalView-ITCH 5.0 and OUCH 5.0 payloads. It does not require feed connectivity,
transport framing, an encoder, matching-engine integration, or dashboard changes.
The existing integer-price engine and OCaml standard library are sufficient;
there are no new runtime dependencies.

## Specification sources

The layouts follow Nasdaq's official specifications, retrieved on 2026-11-06:

- [TotalView-ITCH 5.0](https://www.nasdaqtrader.com/content/technicalsupport/specifications/dataproducts/NQTVITCHspecification.pdf),
  SHA-256 `45e0531d1b4b3beb886e9618b2ab824a5aa9bda3a99c0dff03509306e68aacc3`.
- [OUCH 5.0](https://www.nasdaqtrader.com/content/technicalsupport/specifications/TradingProducts/OUCH5.0.pdf),
  October 2025 revision 1.05, SHA-256
  `ae4a1d3d1614753a55453df52f84f09adf80b38b8fee86c920e7d7ce491e087e`.

These identify the reference revisions; the exchange can change the documents
at these URLs. Nordic OUCH is a separate protocol.

## API and ownership

`Ocaml_lob.Itch.decode`, `Ocaml_lob.Ouch.Inbound.decode`, and
`Ocaml_lob.Ouch.Outbound.decode` take an immutable `string` and a window specified
by `~off` and `~len`. They return a typed message or `Error Wire.error`.
The window must contain exactly one payload, beginning at its message type byte.
Remove BinaryFILE length prefixes, SoupBinTCP headers, or MoldUDP64 envelopes
before calling these functions. For a partial frame, retain the bytes and retry
after completing it at the transport layer. The decoder keeps no streaming state.

```ocaml
match Ocaml_lob.Itch.decode buffer ~off:payload_offset ~len:payload_length with
| Ok { body = Ocaml_lob.Itch.Add_order order; _ } ->
    let symbol = Ocaml_lob.Wire.to_string order.stock in
    Printf.printf "%s: %Ld shares at %Ld ticks\n" symbol order.shares order.price
| Ok _ -> ()
| Error _ -> () (* The transport layer decides how to report or discard the frame. *)
```

Text fields are `Wire.slice` values that retain the original string, including
right-padding spaces. `Wire.to_string` explicitly copies a field. Callers that
retain a small field from a large input buffer should copy it to release the
large buffer. Do not mutate a buffer through an unsafe bytes/string alias while
messages refer to it.

Numeric reads use big-endian standard-library primitives. All unsigned 32-bit
fields widen to `int64`, so high-bit quantities never become negative. Unsigned
64-bit fields retain their exact bit pattern in `int64`; use
`Int64.unsigned_compare` for ordering and `Printf.sprintf "%Lu"` for decimal text.
ITCH timestamps are unsigned 48-bit nanoseconds; OUCH timestamps are 64-bit
nanoseconds. Prices retain their wire integer scale: four decimal places except
ITCH MWCB decline levels, which have eight. Signed OUCH peg offsets use `int32`
with four implied decimal places. No float conversion occurs.

Alpha codes remain raw characters, including ASCII time-in-force codes. The
decoders check binary structure, not exchange business rules: side values,
trading states, order-size limits, valid prices, session sequencing, and whether
an optional attribute is permitted on a particular message belong to the caller.

## Coverage

ITCH has typed variants for all 23 message types:
`S R H Y L V W K J h A F E C X D U P Q B I N O`. Each variant exposes every
specified field; the shared header exposes stock locate, tracking number, and
timestamp.

OUCH inbound has all eight request types: `O U X M C D E Q`.
OUCH outbound has all 17 response types: `S A U C D E B J P I T M R X G K Q`.
Direction is explicit because several type bytes have different layouts in the
two directions. OUCH 5.0 uses four-byte user references, eight-byte prices, and
14-byte client order identifiers.

Optional OUCH appendages remain zero-copy views during payload decoding.
`Ouch.iter_appendages` produces typed values in wire order on demand. All 26
specified tags are supported. Duplicate attributes retain their ordering;
unknown tags are preserved as `Unknown { tag; value }` for forward compatibility.
TagValue lengths count the tag and value, excluding the length byte. Known tags
must have the specified width. Empty unknown values are structurally valid.
Malformed tag boundaries and mismatched appendage lengths are rejected.

The appendage length and appendage may both be absent on inbound `X M Q` and
outbound `C D B J P I T M Q`, as the specification permits. Other messages require
the two-byte appendage length even when it is zero; outbound `S` has no appendage.

## Acceptance and verification

- Every specified message decodes into a distinct typed variant; golden vectors
  check field offsets, fixed-point values, unsigned boundaries, and direction.
- Invalid windows, unsupported types, short payloads, excess bytes, malformed
  appendages, and incomplete length words return structured errors. No reads
  extend beyond the supplied window, even when backing bytes are available.
- Deterministic tests exercise every ITCH truncation point and every OUCH header
  truncation point, both appendage forms where permitted, all optional tags,
  duplicates, and unknown tags. QCheck runs 10,000 arbitrary buffer/window cases.
- Valid-path decoding does not copy text or eagerly allocate optional-field
  lists. A regression guard caps representative add/enter record decoding at
  512 bytes per payload and prints throughput as a local diagnostic. This is a
  bounded-allocation record API; the matching engine's zero-allocation guarantee
  is unchanged. Statistical latency benchmarking remains a separate milestone.
- `dune build @fmt @check @all`, `dune runtest --force`, strict opam lint, and the
  existing browser smoke checks must pass. CI also runs the deterministic
  protocol tests under Bisect, retaining 100% library line coverage.

Run just the protocol suite with `dune exec test/test_protocols.exe`.
