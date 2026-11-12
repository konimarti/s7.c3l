module s7;

import std::time;

// The only I/O abstraction of the client: a blocking byte stream. The same method shape is used by all plant
// libraries, so one type (for example a TLS transport) can be passed to any of them through an explicit cast:
//
//     Transport t = (Transport)&other_transport;
//
//   read:  returns 1..buf.len bytes; faults TIMEOUT (nothing arrived in time) and CLOSED (the peer ended the stream).
//   write: writes all of `data` or faults (TIMEOUT, CLOSED).
//   close: idempotent.
//
// Timeouts: a negative Duration means no limit, zero means "poll once" (TIMEOUT if nothing is ready), a positive one
// is a bound. The Client never passes a computed non-positive remainder for a bounded wait: it reports the missed
// deadline to the Session instead.
interface Transport
{
	fn usz? read(char[] buf, time::Duration timeout);
	fn void? write(char[] data, time::Duration timeout);
	fn void? close();
}
