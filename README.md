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

## Client

`Client` runs a `Session` over a `Transport` (a blocking byte stream: `read`, `write`, `close`, each with a
`Duration` timeout; a negative timeout means no limit, zero polls once). Any type with that method shape can be
passed through an explicit cast, for example `(Transport)&tls`. The client reports missed deadlines to the session
instead of starting a read with no time left.

```c3
module app;
import s7;

fn void? read_a_word(Transport transport)
{
	s7::SessionConfig cfg = s7::default_config(s7::tsaps_from_rack_slot(PG, 0, 2)!);
	s7::Client client;
	client.open(transport, cfg, mem)!;
	defer client.close();
	char[] bytes = client.read_bytes(s7::parse_address("DB1.DBW2")!, mem)!;
	defer free(bytes.ptr);
	assert(bytes.len == 2);
}
```

`read`, `read_bytes`, `read_value`, `write` and `write_bytes` (the latter two need `allow_write`), `read_szl`,
`cpu_info`, `cpu_state` and `read_clock` return the PLC's answer or a fault.

## TCP

`tcp_connect(host, port = 102, timeout)` returns a `TcpTransport` for the `Client`: reads and writes wait with `poll`
(`WSAPoll` on Windows) so the timeouts are real, TCP_NODELAY is on, and sends do not raise SIGPIPE (`MSG_NOSIGNAL` on
Linux, `SO_NOSIGPIPE` on macOS and the BSDs). A connection that cannot be established is `CONNECT_REFUSED`.

## Testing against a peer

The tests in `src/test/peer_test.c3` run against the python-snap7 server when `S7_PEER=host:port` is set and are skipped
otherwise (each prints `PEER-RUN <name>` or `PEER-SKIP <name>`); with `S7_PEER_REQUIRED=1` a missing peer is a failure.

```sh
# python-snap7 must be installed for the interpreter; S7_PEER_PYTHON defaults to python3
"${S7_PEER_PYTHON:-python3}" scripts/run_peer.py 10102 &
S7_PEER=127.0.0.1:10102 S7_PEER_REQUIRED=1 c3c test
```

`c3c build peercheck` builds a small runner for the same cases (`S7_PEER=127.0.0.1:10102 build/peercheck`; `--capture`
prints every frame that goes over the wire).

## Known unverified items

- The python-snap7 server answers SZL 0x001C with a record length of 0 (not like a real PLC) and reads a bit as a whole byte;
  it never fragments an SZL answer.
- Timers and counters are written as octet strings (transport size 0x09); the receiving side is unverified.
- Continuation SZL request layout (F13): multi-fragment continuation requests echo the sequence number in the parameter; unverified against hardware.

