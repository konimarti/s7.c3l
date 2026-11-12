module s7;

import std::time;

// The sans-IO core: a protocol state machine that turns received bytes into events and requests into bytes. It does
// no I/O, reads no clock (the caller passes `now`), spawns no threads and keeps no global state.
//
//   IDLE --connect--> COTP_SENT --CC--> SETUP_SENT --setup answer--> READY --submit--> JOB_IN_FLIGHT --last answer--> READY
//   framing violation, connect-phase failure, timeout --> FAILED        on_closed, close, peer disconnect --> CLOSED
//
// One job is in flight at a time (BUSY otherwise). A job that fails inside a well-formed frame (header error, wrong
// function or item count) is reported with JOB_FAILED and leaves the session READY; anything that can desynchronise
// the stream moves it to FAILED.

const ushort OUR_SRC_REF = 1;      // COTP source reference of our Connection Request
const usz EVENT_CAP = 8;
const usz MAX_ACTIVE_SLICES = 255;

struct SessionConfig
{
	Tsaps tsaps;
	Limits limits;
	time::Duration response_timeout;   // per request PDU
	time::Duration connect_timeout;    // for the whole connect phase
	bool allow_write;                  // submit_write is refused unless set
	// Interop leniency. Defaults: strict reserved byte, strict pdu_ref, lenient DST-REF.
	bool lenient_reserved;             // accept a TPKT reserved byte other than 0
	bool lenient_pdu_ref;              // accept a response whose pdu_ref differs from the request
	bool lenient_dst_ref;              // accept a CC whose DST-REF is not our SRC-REF
}

// DEFAULT_LIMITS, 5 s timeouts, writes refused, strictness as described above.
fn SessionConfig default_config(Tsaps tsaps) => { tsaps, DEFAULT_LIMITS, time::sec(5), time::sec(5), false, false, false, true };

enum SessionState : char
{
	IDLE,
	COTP_SENT,
	SETUP_SENT,
	READY,
	JOB_IN_FLIGHT,
	CLOSED,
	FAILED,
}

typedef RequestId = uint;

enum EventKind : char
{
	CONNECTED,
	JOB_DONE,
	JOB_FAILED,
	DISCONNECTED,
}

// The result of a finished job; owned by the caller after next_event (release with Completion.free).
struct Completion
{
	RequestId id;
	Address[] items;           // copy of the request
	ItemResult[] results;      // one per logical item
	char[] payload;            // backing storage of the item data; for an SZL read the reassembled records
	Allocator allocator;
	JobKind kind;              // READ, WRITE, SZL or CLOCK
	ushort szl_id;             // SZL: the answered list
	ushort szl_index;
	ushort rec_len;            // SZL: record length and the number of records in `payload`
	ushort rec_count;
	Dtl clock;                 // CLOCK: the PLC's time
}

fn void Completion.free(&self)
{
	if (self.items.len > 0) alloc::free(self.allocator, self.items.ptr);
	if (self.results.len > 0) alloc::free(self.allocator, self.results.ptr);
	if (self.payload.len > 0) alloc::free(self.allocator, self.payload.ptr);
	*self = {};
}

struct Event
{
	EventKind kind;
	RequestId id;              // JOB_DONE, JOB_FAILED
	fault error;               // JOB_FAILED, DISCONNECTED
	ushort pdu_size;           // CONNECTED: negotiated
	ushort max_calling;        // CONNECTED
	ushort max_called;         // CONNECTED
	Completion completion;     // JOB_DONE
}

enum JobKind : char
{
	READ,
	WRITE,
	SZL,
	CLOCK,
}

// The job in flight (internal).
struct Job
{
	bool active;
	JobKind kind;
	RequestId id;
	Address[] items;
	Plan plan;
	ItemResult[] results;
	char[] payload;            // read: result bytes; write: copy of the data to send
	usz[] starts;              // offset of every item in `payload`
	char[][] item_data;        // write: per-item views of `payload`
	usz next_pdu;              // next PDU of the plan to send
	ushort szl_id;             // SZL jobs: what is asked and the fragments collected so far
	ushort szl_index;
	SzlAssembler reassembly;
	ushort ref;                // pdu_ref of the PDU in flight
	Slice[MAX_ACTIVE_SLICES] active_slices;   // slices of the PDU in flight (items that already failed are left out)
	usz active_n;
}

fn void Job.release(&self, Allocator allocator)
{
	if (self.items.len > 0) alloc::free(allocator, self.items.ptr);
	if (self.results.len > 0) alloc::free(allocator, self.results.ptr);
	if (self.payload.len > 0) alloc::free(allocator, self.payload.ptr);
	if (self.starts.len > 0) alloc::free(allocator, self.starts.ptr);
	if (self.item_data.len > 0) alloc::free(allocator, self.item_data.ptr);
	self.plan.free();
	self.reassembly.free();
	self.reassembly = {};
	self.active = false;
	self.items = {};
	self.results = {};
	self.payload = {};
	self.starts = {};
	self.item_data = {};
	self.active_n = 0;
}

struct Session
{
	SessionConfig cfg;
	SessionState state;
	Allocator allocator;
	char[] inbuf;              // received bytes not yet consumed, bounded by limits.max_frame
	usz in_len;
	char[] outbuf;             // bytes the adapter must send
	usz out_len;
	ushort pdu_size;           // negotiated
	ushort max_calling;
	ushort max_called;
	ushort next_ref;
	ushort setup_ref;
	ushort peer_ref;           // the CC's SRC-REF, used in our Disconnect Request
	RequestId next_id;
	time::Clock deadline;      // (Clock)0 = none
	char err_class;            // last S7 header error (S7_ERROR)
	char err_code;
	Job job;
	Event[EVENT_CAP] events;
	usz ev_head;
	usz ev_len;
}

// Rejects limits that cannot work: max_pdu + 7 > max_frame, min_pdu > max_pdu, max_items 0.
fn void? Session.init(&self, SessionConfig cfg, Allocator allocator)
{
	Limits l = cfg.limits;
	if ((uint)l.max_pdu + 7 > l.max_frame || l.min_pdu > l.max_pdu || l.max_items == 0) return INVALID_ARGUMENT~;
	if (l.max_pdu < MIN_PLAN_PDU_SIZE) return INVALID_ARGUMENT~;
	*self = {};
	self.cfg = cfg;
	self.allocator = allocator;
	self.inbuf = alloc::new_array(allocator, char, (sz)l.max_frame)[:l.max_frame];
	self.outbuf = alloc::new_array(allocator, char, (sz)l.max_frame)[:l.max_frame];
	self.state = IDLE;
	self.next_ref = 1;
}

fn void Session.free(&self)
{
	self.job.release(self.allocator);
	while (self.ev_len > 0)
	{
		Event e = self.pop_event();
		e.completion.free();
	}
	if (self.inbuf.len > 0) alloc::free(self.allocator, self.inbuf.ptr);
	if (self.outbuf.len > 0) alloc::free(self.allocator, self.outbuf.ptr);
	self.inbuf = {};
	self.outbuf = {};
	self.in_len = 0;
	self.out_len = 0;
	self.state = CLOSED;
}

// ---- events ----

fn void Session.push_event(&self, Event e)
{
	if (self.ev_len == EVENT_CAP)
	{
		// unreachable with one job at a time; never lose a completion silently
		e.completion.free();
		return;
	}
	self.events[(self.ev_head + self.ev_len) % EVENT_CAP] = e;
	self.ev_len++;
}

fn Event Session.pop_event(&self)
{
	Event e = self.events[self.ev_head];
	self.events[self.ev_head] = {};
	self.ev_head = (self.ev_head + 1) % EVENT_CAP;
	self.ev_len--;
	return e;
}

// The next event, or NO_EVENT. A JOB_DONE completion belongs to the caller.
fn Event? Session.next_event(&self)
{
	if (self.ev_len == 0) return NO_EVENT~;
	return self.pop_event();
}

// ---- output ----

// Bytes waiting to be sent; call consume_output(n) once the transport has taken n of them.
fn char[] Session.pending_output(&self) => self.outbuf[:self.out_len];

fn void Session.consume_output(&self, usz n)
{
	if (n >= self.out_len)
	{
		self.out_len = 0;
		return;
	}
	for (usz i = n; i < self.out_len; i++) self.outbuf[i - n] = self.outbuf[i];
	self.out_len -= n;
}

fn ushort Session.alloc_ref(&self)
{
	if (self.next_ref == 0) self.next_ref = 1;
	ushort r = self.next_ref;
	self.next_ref = r == 0xFFFF ? 0 : r + 1;
	return r;
}

fn bool Session.is_down(&self) => self.state == IDLE || self.state == CLOSED || self.state == FAILED;

// ---- time ----

// Absolute deadline of the pending response or connect step; (Clock)0 when nothing is pending.
fn time::Clock Session.next_deadline(&self) => self.deadline;

// The adapter reports a missed deadline: the job in flight fails with TIMEOUT and the session is FAILED (a late
// answer would desynchronise the stream); during connect the connect fails.
fn void Session.on_timeout(&self, time::Clock now)
{
	if (self.state == COTP_SENT || self.state == SETUP_SENT || self.state == JOB_IN_FLIGHT) self.fail(TIMEOUT);
}

// ---- failure and shutdown ----

fn void Session.job_failed(&self, fault error)
{
	if (!self.job.active) return;
	Event e = { .kind = JOB_FAILED, .id = self.job.id, .error = error };
	self.job.release(self.allocator);
	self.push_event(e);
}

// Protocol failure: fails the job in flight, then reports DISCONNECTED(error); the adapter closes the transport.
fn void Session.fail(&self, fault error)
{
	if (self.state == FAILED || self.state == CLOSED) return;
	self.job_failed(error);
	self.state = FAILED;
	self.in_len = 0;
	self.deadline = (time::Clock)0;
	Event e = { .kind = DISCONNECTED, .error = error };
	self.push_event(e);
}

// The peer closed: like fail, but an orderly end of the connection.
fn void Session.on_closed(&self, fault reason, time::Clock now)
{
	if (self.state == IDLE || self.state == FAILED || self.state == CLOSED) return;
	self.job_failed(reason);
	self.state = CLOSED;
	self.in_len = 0;
	self.deadline = (time::Clock)0;
	Event e = { .kind = DISCONNECTED, .error = reason };
	self.push_event(e);
}

// Orderly shutdown from our side: queues a Disconnect Request (replacing unsent output) and moves to CLOSED. A job
// in flight fails with CLOSED; no DISCONNECTED event is queued for a close the caller asked for.
fn void Session.close(&self, time::Clock now)
{
	if (self.state == IDLE || self.state == FAILED || self.state == CLOSED) return;
	self.job_failed(CLOSED);
	self.out_len = 0;
	usz? n = encode_dr(self.peer_ref, OUR_SRC_REF, self.outbuf);
	if (try len = n) self.out_len = len;
	self.state = CLOSED;
	self.in_len = 0;
	self.deadline = (time::Clock)0;
}

// ---- connect ----

// Starts the connection: queues the COTP Connection Request.
fn void? Session.connect(&self, time::Clock now)
{
	if (self.state != IDLE) return BUSY~;
	self.out_len = encode_cr(self.cfg.tsaps, OUR_SRC_REF, self.outbuf)!;
	self.state = COTP_SENT;
	self.deadline = now.add_duration(self.cfg.connect_timeout);
}

fn void? Session.on_cc(&self, CotpPdu* cotp, time::Clock now)
{
	if (cotp.kind == DR || cotp.kind == ER) return CONNECT_REFUSED~;
	if (cotp.kind != CC) return UNEXPECTED_PDU~;
	if (!self.cfg.lenient_dst_ref && cotp.dst_ref != OUR_SRC_REF) return BAD_COTP~;
	self.peer_ref = cotp.src_ref;
	self.setup_ref = self.alloc_ref();
	usz n = encode_setup_request(self.setup_ref, self.cfg.limits.max_pdu, self.outbuf[self.out_len..])!;
	self.out_len += n;
	self.state = SETUP_SENT;
}

fn void? Session.on_setup_answer(&self, CotpPdu* cotp, time::Clock now)
{
	if (cotp.kind == DR || cotp.kind == ER) return CONNECT_REFUSED~;
	if (cotp.kind != DT) return UNEXPECTED_PDU~;
	S7Header h = decode_s7_header(cotp.payload)!;
	if (h.pdu_ref != self.setup_ref && !self.cfg.lenient_pdu_ref) return PDU_REF_MISMATCH~;
	if (h.err_class != 0 || h.err_code != 0)
	{
		self.err_class = h.err_class;
		self.err_code = h.err_code;
		return S7_ERROR~;
	}
	SetupParams p = decode_setup_response(&h)!;
	ushort pdu = p.pdu < self.cfg.limits.max_pdu ? p.pdu : self.cfg.limits.max_pdu;   // never above our offer
	if (p.pdu == 0 || pdu < self.cfg.limits.min_pdu) return NEGOTIATION_FAILED~;
	self.pdu_size = pdu;
	self.max_calling = p.amq_calling;
	self.max_called = p.amq_called;
	self.state = READY;
	self.deadline = (time::Clock)0;
	Event e = { .kind = CONNECTED, .pdu_size = pdu, .max_calling = p.amq_calling, .max_called = p.amq_called };
	self.push_event(e);
}

// ---- jobs ----

fn RequestId? Session.start_job(&self, JobKind kind, Address[] items, char[][] data, time::Clock now)
{
	if (self.state == JOB_IN_FLIGHT) return BUSY~;
	if (self.state != READY) return NOT_CONNECTED~;
	if (items.len == 0) return INVALID_ARGUMENT~;
	if (kind == WRITE)
	{
		if (data.len != items.len) return INVALID_ARGUMENT~;
		foreach (i, a : items)
		{
			if (data[i].len != a.payload_bytes()) return INVALID_ARGUMENT~;
		}
	}
	Limits l = self.cfg.limits;
	Plan plan = (kind == READ ? plan_read(items, self.pdu_size, l.max_items, l.max_request_bytes, self.allocator) : plan_write(items, self.pdu_size, l.max_items, l.max_request_bytes, self.allocator))!;

	Job* job = &self.job;
	usz n = items.len;
	job.plan = plan;
	job.kind = kind;
	job.items = alloc::new_array(self.allocator, Address, (sz)n)[:n];
	job.results = alloc::new_array(self.allocator, ItemResult, (sz)n)[:n];
	job.starts = alloc::new_array(self.allocator, usz, (sz)n)[:n];
	usz total = 0;
	foreach (i, a : items)
	{
		job.items[i] = a;
		job.starts[i] = total;
		total += a.payload_bytes();
		job.results[i].raw_code = 0xFF;
	}
	job.payload = alloc::new_array(self.allocator, char, (sz)total)[:total];
	if (kind == WRITE)
	{
		job.item_data = alloc::new_array(self.allocator, char[], (sz)n)[:n];
		foreach (i, a : items)
		{
			usz len = a.payload_bytes();
			job.payload[job.starts[i]:len] = data[i][..];
			job.item_data[i] = job.payload[job.starts[i]:len];
		}
	}
	self.next_id++;
	job.id = (RequestId)self.next_id;
	job.active = true;
	job.next_pdu = 0;
	self.state = JOB_IN_FLIGHT;
	if (catch err = self.send_next_pdu(now))
	{
		job.release(self.allocator);
		self.state = READY;
		return err~;
	}
	return job.id;
}

// Sends the next PDU of the plan, leaving out the slices of items that already failed; completes the job when no PDU
// is left.
fn void? Session.send_next_pdu(&self, time::Clock now)
{
	Job* job = &self.job;
	while (job.next_pdu < job.plan.pdus.len)
	{
		Pdu planned = job.plan.pdus[job.next_pdu];
		job.next_pdu++;
		usz n = 0;
		foreach (s : planned.slices)
		{
			if (!job.results[s.item].status)
			{
				job.active_slices[n] = s;
				n++;
			}
		}
		if (n == 0) continue;
		job.active_n = n;
		Pdu pdu = { job.active_slices[:n] };
		job.ref = self.alloc_ref();
		char[] out = self.outbuf[self.out_len..];
		usz len;
		if (job.kind == READ)
		{
			len = encode_read_request(job.ref, job.items, &pdu, out)!;
		}
		else
		{
			len = encode_write_request(job.ref, job.items, job.item_data, &pdu, out)!;
		}
		self.out_len += len;
		self.deadline = now.add_duration(self.cfg.response_timeout);
		return;
	}
	self.complete_job();
}

fn void Session.complete_job(&self)
{
	Job* job = &self.job;
	foreach (i, a : job.items)
	{
		if (job.kind == READ && !job.results[i].status)
		{
			job.results[i].data = job.payload[job.starts[i]:a.payload_bytes()];
		}
	}
	Event e = { .kind = JOB_DONE, .id = job.id };
	e.completion.id = job.id;
	e.completion.items = job.items;
	e.completion.results = job.results;
	e.completion.payload = job.payload;
	e.completion.allocator = self.allocator;
	e.completion.kind = job.kind;
	job.plan.free();
	if (job.starts.len > 0) alloc::free(self.allocator, job.starts.ptr);
	if (job.item_data.len > 0) alloc::free(self.allocator, job.item_data.ptr);
	*job = {};
	self.state = READY;
	self.deadline = (time::Clock)0;
	self.push_event(e);
}

fn void? Session.on_job_answer(&self, CotpPdu* cotp, time::Clock now)
{
	Job* job = &self.job;
	S7Header h = decode_s7_header(cotp.payload)!;
	if (h.pdu_ref != job.ref && !self.cfg.lenient_pdu_ref) return PDU_REF_MISMATCH~;
	if (job.kind == SZL) return self.on_szl_answer(&h, now);
	if (job.kind == CLOCK) return self.on_clock_answer(&h);
	Pdu pdu = { job.active_slices[:job.active_n] };
	ItemResult[MAX_ACTIVE_SLICES] res;
	fault failure;
	if (job.kind == READ)
	{
		if (catch err = decode_read_response(&h, &pdu, res[..])) failure = err;
	}
	else
	{
		if (catch err = decode_write_response(&h, &pdu, res[..])) failure = err;
	}
	if (failure)
	{
		// the frame itself was well formed: the job fails, the stream is still in step
		if (failure == S7_ERROR)
		{
			self.err_class = h.err_class;
			self.err_code = h.err_code;
		}
		self.job_failed(failure);
		self.state = READY;
		self.deadline = (time::Clock)0;
		return;
	}
	foreach (k, s : pdu.slices)
	{
		ItemResult* item = &job.results[s.item];
		if (res[k].status)
		{
			if (!item.status)
			{
				item.status = res[k].status;
				item.raw_code = res[k].raw_code;
			}
		}
		else if (job.kind == READ && !item.status)
		{
			job.payload[job.starts[s.item] + s.offset:s.length] = res[k].data[..];
		}
	}
	self.send_next_pdu(now)!;
}

// The job failed inside a well-formed frame: report it, keep the session READY.
fn void Session.reject_job(&self, fault failure)
{
	self.job_failed(failure);
	self.state = READY;
	self.deadline = (time::Clock)0;
}

// Sends an SZL request for the job in flight: the first one (`seq` 0) or a continuation echoing `seq`.
fn void? Session.send_szl_request(&self, char seq, time::Clock now)
{
	Job* job = &self.job;
	job.ref = self.alloc_ref();
	char[] out = self.outbuf[self.out_len..];
	usz len;
	if (seq == 0)
	{
		len = encode_szl_request(job.ref, job.szl_id, job.szl_index, 0, out)!;
	}
	else
	{
		len = encode_szl_continuation_request(job.ref, job.szl_id, job.szl_index, seq, out)!;
	}
	self.out_len += len;
	self.deadline = now.add_duration(self.cfg.response_timeout);
}

fn void? Session.on_szl_answer(&self, S7Header* h, time::Clock now)
{
	Job* job = &self.job;
	SzlPart? part = decode_szl_response(h);
	if (catch err = part)
	{
		self.reject_job(err);
		return;
	}
	if (catch err = job.reassembly.push(&part))
	{
		self.reject_job(err);
		return;
	}
	if (part.more)
	{
		// the next fragment: a continuation request inside the same job
		if (catch err = self.send_szl_request(part.seq, now))
		{
			self.reject_job(err);
		}
		return;
	}
	Event e = { .kind = JOB_DONE, .id = job.id };
	e.completion.id = job.id;
	e.completion.allocator = self.allocator;
	e.completion.kind = SZL;
	e.completion.szl_id = part.szl_id;
	e.completion.szl_index = part.index;
	e.completion.rec_len = part.rec_len;
	e.completion.rec_count = part.rec_len > 0 ? (ushort)(job.reassembly.buffer.len / part.rec_len) : part.rec_count;
	e.completion.payload = job.reassembly.buffer;
	job.reassembly.buffer = {};      // the completion owns the records now
	job.release(self.allocator);
	self.state = READY;
	self.deadline = (time::Clock)0;
	self.push_event(e);
}

fn void? Session.on_clock_answer(&self, S7Header* h)
{
	Job* job = &self.job;
	Dtl? time = decode_clock_response(h);
	if (catch err = time)
	{
		self.reject_job(err);
		return;
	}
	Event e = { .kind = JOB_DONE, .id = job.id };
	e.completion.id = job.id;
	e.completion.allocator = self.allocator;
	e.completion.kind = CLOCK;
	e.completion.clock = time;
	job.release(self.allocator);
	self.state = READY;
	self.deadline = (time::Clock)0;
	self.push_event(e);
}

fn void? Session.start_userdata_job(&self, JobKind kind)
{
	if (self.state == JOB_IN_FLIGHT) return BUSY~;
	if (self.state != READY) return NOT_CONNECTED~;
	self.job = {};
	self.job.kind = kind;
	self.job.reassembly = szl_assembler_init(self.cfg.limits, self.allocator);
	self.next_id++;
	self.job.id = (RequestId)self.next_id;
	self.job.active = true;
	self.state = JOB_IN_FLIGHT;
}

// Reads the system status list `szl_id` / `index` (module identification 0x0011, component identification 0x001C,
// CPU state 0x0424). A list that comes in several fragments is collected with continuation requests inside the same
// job; the completion carries the records in `payload` with `rec_len` and `rec_count`.
fn RequestId? Session.submit_szl(&self, ushort szl_id, ushort index, time::Clock now)
{
	self.start_userdata_job(SZL)!;
	Job* job = &self.job;
	job.szl_id = szl_id;
	job.szl_index = index;
	if (catch err = self.send_szl_request(0, now))
	{
		job.release(self.allocator);
		self.state = READY;
		return err~;
	}
	return job.id;
}

// Reads the PLC's clock; the completion carries it in `clock`.
fn RequestId? Session.submit_read_clock(&self, time::Clock now)
{
	self.start_userdata_job(CLOCK)!;
	Job* job = &self.job;
	job.ref = self.alloc_ref();
	usz? n = encode_clock_request(job.ref, self.outbuf[self.out_len..]);
	if (catch err = n)
	{
		job.release(self.allocator);
		self.state = READY;
		return err~;
	}
	self.out_len += n;
	self.deadline = now.add_duration(self.cfg.response_timeout);
	return job.id;
}

// A read of one or more addresses, cut into PDUs as needed. Returns the id that the completion carries.
fn RequestId? Session.submit_read(&self, Address[] items, time::Clock now)
{
	return self.start_job(READ, items, {}, now);
}

// A write; `data[i]` is the whole payload of items[i]. Refused unless `allow_write` is set, before any byte is produced.
fn RequestId? Session.submit_write(&self, Address[] items, char[][] data, time::Clock now)
{
	if (!self.cfg.allow_write) return WRITE_NOT_ALLOWED~;
	return self.start_job(WRITE, items, data, now);
}

// ---- input ----

fn void? Session.on_frame(&self, char[] frame, time::Clock now)
{
	CotpPdu cotp = decode_cotp(frame)!;
	switch (self.state)
	{
		case COTP_SENT:
			return self.on_cc(&cotp, now);
		case SETUP_SENT:
			return self.on_setup_answer(&cotp, now);
		case READY:
		case JOB_IN_FLIGHT:
			if (cotp.kind == DR || cotp.kind == ER)
			{
				// the peer ended the connection
				self.on_closed(CLOSED, now);
				return;
			}
			if (cotp.kind != DT || self.state == READY) return UNEXPECTED_PDU~;
			return self.on_job_answer(&cotp, now);
		default:
			return NOT_CONNECTED~;
	}
}

// Parses every complete frame in the buffer. A framing violation fails the session.
fn void? Session.process(&self, time::Clock now)
{
	while (self.in_len >= TPKT_HEADER_LEN && !self.is_down())
	{
		usz? t = decode_tpkt_header(self.inbuf[:TPKT_HEADER_LEN], self.cfg.limits.max_frame, !self.cfg.lenient_reserved);
		if (catch e = t)
		{
			self.fail(e);
			return e~;
		}
		if (self.in_len < t) break;
		usz? r = self.on_frame_checked(t, now);
		if (catch e = r)
		{
			self.fail(e);
			return e~;
		}
		if (self.is_down()) return;
		for (usz i = t; i < self.in_len; i++) self.inbuf[i - t] = self.inbuf[i];
		self.in_len -= t;
	}
}

fn usz? Session.on_frame_checked(&self, usz total, time::Clock now)
{
	self.on_frame(self.inbuf[:total], now)!;
	return total;
}

// Hands received bytes in, in any chunking. A violation of the protocol faults and moves the session to FAILED; the
// adapter closes the transport. Bytes that arrive after the session went down are ignored.
fn void? Session.feed(&self, char[] bytes, time::Clock now)
{
	if (self.is_down()) return NOT_CONNECTED~;
	usz at = 0;
	while (at < bytes.len)
	{
		usz space = self.inbuf.len - self.in_len;
		usz n = bytes.len - at < space ? bytes.len - at : space;
		self.inbuf[self.in_len:n] = bytes[at:n];
		self.in_len += n;
		at += n;
		self.process(now)!;
		if (self.is_down()) return;
	}
}
