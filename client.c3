module s7;

import std::time;

// The blocking adapter: drives a Session over a Transport. It owns no protocol logic; it only moves bytes between the
// Session and the transport, tells the Session what time it is and when the transport failed, and turns events into
// return values. Not thread-safe: use one Client per thread.

// A monotonic clock; the Client takes it as a parameter so tests can control time.
alias ClockFn = fn time::Clock();

fn time::Clock default_clock() => time::clock::now();

struct Client
{
	Session session;
	Transport transport;
	ClockFn clock;
	Allocator allocator;
	time::Duration write_timeout;   // bound for a write when no response deadline is pending
	bool attached;
	bool transport_closed;
}

// Connects over `transport` (already connected at the TCP level): runs the COTP connect and the Setup Communication.
// On a fault the transport is left to the caller. Pass null as `clock` for the default monotonic clock.
fn void? Client.open(&self, Transport transport, SessionConfig cfg, Allocator allocator, ClockFn clock = null)
{
	*self = {};
	self.session.init(cfg, allocator)!;
	self.transport = transport;
	self.clock = clock ? clock : &default_clock;
	self.allocator = allocator;
	self.write_timeout = cfg.response_timeout;
	self.attached = true;
	if (catch err = self.connect())
	{
		self.session.free();
		self.attached = false;
		return err~;
	}
}

fn void? Client.connect(&self)
{
	self.session.connect(self.clock())!;
	Event e = self.wait_event()!;
	if (e.kind != CONNECTED) return e.error ? e.error~ : UNEXPECTED_PDU~;
}

// Sends a Disconnect Request (best effort), closes the transport once and releases the session. Idempotent.
fn void Client.close(&self)
{
	if (!self.attached) return;
	self.session.close(self.clock());
	self.flush();
	if (!self.transport_closed)
	{
		self.transport_closed = true;
		if (catch err = self.transport.close()) {}
	}
	self.session.free();
	self.attached = false;
}

// The PDU size the PLC agreed to.
fn ushort Client.pdu_size(&self) => self.session.pdu_size;

// ---- the loop ----

// How long a wait may take: a positive Duration until the deadline, a negative one when none is pending. False when the
// deadline has already passed.
fn bool Client.timeout_until(&self, time::Clock now, time::Duration* timeout)
{
	time::Clock deadline = self.session.next_deadline();
	if (deadline == (time::Clock)0)
	{
		*timeout = (time::Duration)-1;
		return true;
	}
	if (deadline <= now) return false;
	time::Duration left = deadline.nano_diff(now).to_duration();
	*timeout = (long)left > 0 ? left : (time::Duration)1;
	return true;
}

// Hands everything the session wants to send to the transport in one write. A fault ends the connection; a missed
// deadline is reported to the session before anything is written.
fn void Client.flush(&self)
{
	char[] out = self.session.pending_output();
	if (out.len == 0) return;
	time::Clock now = self.clock();
	time::Duration timeout;
	if (self.session.next_deadline() == (time::Clock)0)
	{
		timeout = self.write_timeout;
	}
	else if (!self.timeout_until(now, &timeout))
	{
		self.session.on_timeout(now);
		return;
	}
	if (catch err = self.transport.write(out, timeout))
	{
		self.report(err);
		return;
	}
	self.session.consume_output(out.len);
}

// A transport fault: a timeout is a missed deadline, anything else ends the stream.
fn void Client.report(&self, fault err)
{
	time::Clock now = self.clock();
	if (err == TIMEOUT)
	{
		// the transport says time is up: if the clock disagrees (it is slightly behind) the deadline counts as reached
		time::Clock deadline = self.session.next_deadline();
		self.session.on_timeout(deadline != (time::Clock)0 && now < deadline ? deadline : now);
	}
	else
	{
		self.session.on_closed(err == CLOSED ? CLOSED : err, now);
	}
}

// Runs the session until it has an event to report: sends output, reads input, feeds it, watches the deadline. A
// deadline that has passed is reported to the session before any read, so a read never gets a non-positive bound.
fn Event? Client.wait_event(&self)
{
	while (true)
	{
		self.flush();
		Event? ev = self.session.next_event();
		if (try e = ev) return e;
		if (self.session.state != COTP_SENT && self.session.state != SETUP_SENT && self.session.state != JOB_IN_FLIGHT)
		{
			return NOT_CONNECTED~;
		}
		time::Clock now = self.clock();
		time::Duration timeout;
		if (!self.timeout_until(now, &timeout))
		{
			self.session.on_timeout(now);
			continue;
		}
		char[2048] buf;
		usz? n = self.transport.read(buf[..], timeout);
		if (catch err = n)
		{
			self.report(err);
			continue;
		}
		// a protocol violation fails the session; its events are picked up at the top of the loop
		if (catch err = self.session.feed(buf[:n], self.clock())) {}
	}
}

fn Completion? Client.await_completion(&self)
{
	Event e = self.wait_event()!;
	switch (e.kind)
	{
		case JOB_DONE:
			return e.completion;
		case JOB_FAILED:
		case DISCONNECTED:
			return e.error~;
		default:
			return UNEXPECTED_PDU~;
	}
}

// ---- reading ----

// Reads several addresses at once, cut into as many PDUs as needed. `results[i].status` tells per item what the PLC
// said; a fault of the whole request is the return value. Release the completion with Completion.free.
fn Completion? Client.read(&self, Address[] items)
{
	self.session.submit_read(items, self.clock())!;
	return self.await_completion();
}

// One address -> its bytes, copied with `allocator` (release with alloc::free(allocator, bytes.ptr)). An item the PLC
// refused is returned as that fault.
fn char[]? Client.read_bytes(&self, Address addr, Allocator allocator)
{
	Address[1] items = { addr };
	Completion c = self.read(items[..])!;
	defer c.free();
	if (c.results[0].status) return c.results[0].status~;
	usz n = c.results[0].data.len;
	char[] out = alloc::new_array(allocator, char, (sz)n)[:n];
	out[..] = c.results[0].data[..];
	return out;
}

// One address read and decoded as `kind`; the address must cover the size of the kind (the size of the whole object for
// STRING and WSTRING). Strings are allocated with `allocator` (Value.free).
fn Value? Client.read_value(&self, Address addr, ValueKind kind, Allocator allocator)
{
	Address[1] items = { addr };
	Completion c = self.read(items[..])!;
	defer c.free();
	if (c.results[0].status) return c.results[0].status~;
	return decode_value(kind, c.results[0].data, allocator);
}

// ---- writing (needs SessionConfig.allow_write, else WRITE_NOT_ALLOWED) ----

// Writes several addresses; `data[i]` is the whole payload of items[i].
fn Completion? Client.write(&self, Address[] items, char[][] data)
{
	self.session.submit_write(items, data, self.clock())!;
	return self.await_completion();
}

fn void? Client.write_bytes(&self, Address addr, char[] data)
{
	Address[1] items = { addr };
	char[][1] payload = { data };
	Completion c = self.write(items[..], payload[..])!;
	defer c.free();
	if (c.results[0].status) return c.results[0].status~;
}

// ---- system status and clock ----

fn Completion? Client.read_szl(&self, ushort szl_id, ushort index)
{
	self.session.submit_szl(szl_id, index, self.clock())!;
	return self.await_completion();
}

// Component identification (SZL 0x001C): names, serial number, type. Release with CpuInfo.free(allocator).
fn CpuInfo? Client.cpu_info(&self, Allocator allocator)
{
	Completion c = self.read_szl(0x001C, 0)!;
	defer c.free();
	return decode_component_id(c.payload, c.rec_len, allocator);
}

// Operating mode (SZL 0x0424).
fn CpuState? Client.cpu_state(&self)
{
	Completion c = self.read_szl(0x0424, 0)!;
	defer c.free();
	return decode_cpu_state(c.payload, c.rec_len);
}

fn Dtl? Client.read_clock(&self)
{
	self.session.submit_read_clock(self.clock())!;
	Completion c = self.await_completion()!;
	defer c.free();
	return c.clock;
}
