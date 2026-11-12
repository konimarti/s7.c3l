module s7::sys;

import libc;
import std::net, std::net::os, std::net::tcp, std::time;

// The only platform-specific code of the library, kept in one file. It adds what std::net lacks for a request/response
// protocol: a wait with a timeout (std::net::poll, which is poll on POSIX and WSAPoll on Windows), TCP_NODELAY, and
// sending without SIGPIPE.

const CInt IPPROTO_TCP = 6;          // the same number on Linux, macOS and Windows
const CInt TCP_NODELAY = 1;
const CInt SO_NOSIGPIPE = 0x1022;    // macOS and BSD: a write to a closed socket returns an error instead of a signal

// Wait until the socket is ready for `events`. A negative timeout waits forever, zero polls once, a positive one is a
// bound (rounded up to a whole millisecond). TIMEOUT on expiry; a failure of the wait itself is CLOSED.
fn void? wait_for(NativeSocket sock, PollSubscribe events, time::Duration timeout)
{
	long ms = -1;
	if ((long)timeout >= 0)
	{
		ms = timeout.to_ms();
		if (ms == 0 && (long)timeout > 0) ms = 1;
	}
	Poll[1] polls;
	polls[0].socket = sock;
	polls[0].events = events;
	ulong? ready = net::poll_ms(polls[..], ms);
	if (catch err = ready) return s7::CLOSED~;
	if (ready == 0) return s7::TIMEOUT~;
}

fn void? wait_readable(TcpSocket* socket, time::Duration timeout) => wait_for(socket.sock, PollSubscribe.ANY_READ, timeout);

fn void? wait_writable(TcpSocket* socket, time::Duration timeout) => wait_for(socket.sock, PollSubscribe.ANY_WRITE, timeout);

fn void? set_int_option(TcpSocket* socket, CInt level, CInt name, CInt value)
{
	CInt v = value;
	if (os::setsockopt(socket.sock, level, name, &v, CInt::size) != 0) return s7::CLOSED~;
}

// TCP_NODELAY: every frame is one write, so Nagle's algorithm would only add the delayed-ACK stall.
fn void? set_nodelay(TcpSocket* socket) => set_int_option(socket, IPPROTO_TCP, TCP_NODELAY, 1);

// Makes writes to a closed connection return an error instead of raising SIGPIPE: SO_NOSIGPIPE on macOS and the
// BSDs, nothing to do elsewhere (Linux uses MSG_NOSIGNAL on every send, Windows has no SIGPIPE).
fn void? prepare_sends(TcpSocket* socket)
{
$if env::DARWIN || env::BSD_FAMILY:
	return set_int_option(socket, os::SOL_SOCKET, SO_NOSIGPIPE, 1);
$endif
}

// One send of as much of `data` as the socket takes, without SIGPIPE; returns the bytes sent. A failure (a reset or
// closed connection) is CLOSED.
fn usz? send_nosignal(TcpSocket* socket, char[] data)
{
$if env::WIN32:
	sz n = libc::send(socket.sock, data.ptr, (int)data.len, 0);
$else
$if env::LINUX:
	sz n = libc::send(socket.sock, data.ptr, (usz)data.len, os::MSG_NOSIGNAL);
$else
	sz n = libc::send(socket.sock, data.ptr, (usz)data.len, 0);
$endif
$endif
	if (n < 0) return s7::CLOSED~;
	return (usz)n;
}
