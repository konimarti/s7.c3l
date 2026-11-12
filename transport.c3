module s7;

import std::net::tcp, std::time;
import s7::sys;

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

// ---- TCP ----

// A TCP connection to a PLC (port 102, or another one for a test peer). Reads and writes wait with poll (WSAPoll on
// Windows), so the timeouts of the contract are real; writes go out without SIGPIPE.
struct TcpTransport (Transport)
{
	tcp::TcpSocket socket;
	bool open;
}

// Connects with a bound on the connect itself and turns TCP_NODELAY on. Any failure to establish the connection is
// CONNECT_REFUSED.
fn TcpTransport? tcp_connect(String host, int port = 102, time::Duration timeout = time::sec(5))
{
	tcp::TcpSocket? socket = tcp::connect(host, port, timeout);
	if (catch err = socket) return CONNECT_REFUSED~;
	TcpTransport t;
	t.socket = socket;
	if (catch err = sys::set_nodelay(&t.socket))
	{
		if (catch closing = t.socket.close()) {}   // the error to report is the one that made us give up
		return err~;
	}
	if (catch err = sys::prepare_sends(&t.socket))
	{
		if (catch closing = t.socket.close()) {}   // the error to report is the one that made us give up
		return err~;
	}
	t.open = true;
	return t;
}

fn usz? TcpTransport.read(&self, char[] buf, time::Duration timeout) @dynamic
{
	if (!self.open) return CLOSED~;
	if (buf.len == 0) return INVALID_ARGUMENT~;
	sys::wait_readable(&self.socket, timeout)!;
	sz? n = self.socket.read(buf);
	if (catch err = n) return CLOSED~;
	if (n == 0) return CLOSED~;      // the peer ended the stream
	return (usz)n;
}

// Writes all of `data` or faults; `timeout` bounds the whole write.
fn void? TcpTransport.write(&self, char[] data, time::Duration timeout) @dynamic
{
	if (!self.open) return CLOSED~;
	bool bounded = (long)timeout >= 0;
	time::Clock deadline = bounded ? time::clock::now().add_duration(timeout) : (time::Clock)0;
	usz sent = 0;
	while (sent < data.len)
	{
		time::Duration left = timeout;
		if (bounded)
		{
			time::Clock now = time::clock::now();
			if (sent > 0 && now >= deadline) return TIMEOUT~;
			left = now >= deadline ? (time::Duration)0 : deadline.nano_diff(now).to_duration();
		}
		sys::wait_writable(&self.socket, left)!;
		sent += sys::send_nosignal(&self.socket, data[sent..])!;
	}
}

fn void? TcpTransport.close(&self) @dynamic
{
	if (!self.open) return;
	self.open = false;
	self.socket.close()!;
}
