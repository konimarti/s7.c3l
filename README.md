# s7.c3l

Siemens S7comm client library for [C3](http://c3-lang.org) (work in progress).

Scope: TPKT/COTP framing, S7 Setup Communication, Read/Write Var, SZL and clock reads, address parser and
S7 value types. Sans-IO core with a blocking TCP adapter. Writes to a PLC are refused unless explicitly
allowed.

Requires c3c v0.8.6 or newer. Licence: MIT.

## Building blocks

- `parse_address`: `DB1.DBX0.3`, `DB1.DBW2`, `DB10.DBB0[16]` (or `:16`), `MW20`, `I0.1`, `QB4`, `PIW4`, `T5`, `C3`.
- `decode_value` / `encode_value` / `parse_value`: BOOL to DTL, S5TIME and BCD counters, S7 STRING and WSTRING.
- `plan_read` / `plan_write`: cut a list of addresses into request PDUs for the negotiated PDU size (at most 20
  items per PDU, large items cut into byte chunks). `encode_read_request`, `decode_read_response`,
  `encode_write_request` and `decode_write_response` work on one planned PDU; each item of a response carries its
  own fault (`ACCESS_DENIED`, `OBJECT_DOES_NOT_EXIST`, ...) without failing the others.

## Session

`Session` is the sans-IO state machine: it never does I/O and never reads a clock. The adapter gives it received
bytes (`feed`), sends what `pending_output` holds (then `consume_output`), passes the current monotonic time as a
`std::time::Clock` and polls `next_event` (`CONNECTED`, `JOB_DONE`, `JOB_FAILED`, `DISCONNECTED`). `next_deadline`
says when to call `on_timeout`; `on_closed` reports end of stream; `close` queues a Disconnect Request. One job is in
flight at a time. `submit_write` is refused with `WRITE_NOT_ALLOWED` unless `SessionConfig.allow_write` is set.
The strictness switches `lenient_reserved`, `lenient_pdu_ref` and `lenient_dst_ref` default to strict, strict, lenient.

## Known unverified items

- Timers and counters are written as octet strings (transport size 0x09); the receiving side is unverified.
- Continuation SZL request layout (F13): multi-fragment continuation requests echo the sequence number in the parameter; unverified against hardware.

