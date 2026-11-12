module s7;

import std::time;

// Test double for Transport: a scripted PLC. Replies are released by the writes of the client: a reply that needs
// `after_writes` writes cannot be read before that many write calls have happened, so the script behaves like a PLC
// that answers each request. Everything the client does is recorded.

const usz MEM_SCRIPT_CAP = 16384;
const usz MEM_WRITTEN_CAP = 16384;
const usz MEM_RECORDS = 128;

struct MemSegment
{
	usz end;               // offset in `script` where the segment ends
	usz after_writes;      // readable once this many write calls have happened
}

struct MemTransport (Transport)
{
	char[MEM_SCRIPT_CAP] script;
	usz script_len;
	MemSegment[64] segments;
	usz segment_count;
	usz read_pos;
	usz chunk;                         // at most this many bytes per read (0 = no limit)
	bool eof_when_exhausted;           // true: CLOSED when the script is used up; false: TIMEOUT
	bool fail_writes;                  // every write faults with CLOSED
	usz early_timeouts;                // this many reads return TIMEOUT at once although data is waiting
	time::Clock* clock_ref;            // a silent PLC: each TIMEOUT moves this clock ahead by `advance`
	time::Duration advance;
	bool read_zero_bytes;              // a misbehaving transport: read returns 0
	bool read_too_many;                // a misbehaving transport: read returns more than the buffer holds

	char[MEM_WRITTEN_CAP] written;
	usz written_len;
	usz[MEM_RECORDS] write_lens;
	usz write_calls;
	usz read_calls;
	usz close_calls;
	time::Duration[MEM_RECORDS] read_timeouts;
	time::Duration[MEM_RECORDS] write_timeouts;
}

// Queues bytes the PLC sends once `after_writes` writes have been made.
fn void MemTransport.reply(&self, String hex, usz after_writes)
{
	Fixture f = fx(hex);
	self.reply_bytes(f.bytes(), after_writes);
}

fn void MemTransport.reply_bytes(&self, char[] bytes, usz after_writes)
{
	assert(self.script_len + bytes.len <= MEM_SCRIPT_CAP && self.segment_count < 64);
	self.script[self.script_len:bytes.len] = bytes[..];
	self.script_len += bytes.len;
	self.segments[self.segment_count] = { self.script_len, after_writes };
	self.segment_count++;
}

// End of the part of the script that may be read now: the segments are released in order.
fn usz MemTransport.available_end(&self)
{
	usz end = 0;
	for (usz i = 0; i < self.segment_count; i++)
	{
		if (self.segments[i].after_writes > self.write_calls) break;
		end = self.segments[i].end;
	}
	return end;
}

fn usz? MemTransport.read(&self, char[] buf, time::Duration timeout) @dynamic
{
	if (self.read_calls < MEM_RECORDS) self.read_timeouts[self.read_calls] = timeout;
	self.read_calls++;
	assert(self.read_calls < 5000, "the client keeps reading a transport that never delivers");
	if (self.read_zero_bytes) return 0;
	if (self.read_too_many) return buf.len + 1;
	if (self.early_timeouts > 0)
	{
		self.early_timeouts--;
		return TIMEOUT~;
	}
	usz end = self.available_end();
	if (self.read_pos >= end)
	{
		// nothing to read: either the stream ended or the PLC stays silent
		if (self.read_pos >= self.script_len && self.eof_when_exhausted) return CLOSED~;
		if (self.clock_ref) *self.clock_ref = (*self.clock_ref).add_duration(self.advance);   // time passes while nothing arrives
		return TIMEOUT~;
	}
	usz n = end - self.read_pos;
	if (n > buf.len) n = buf.len;
	if (self.chunk != 0 && n > self.chunk) n = self.chunk;
	buf[:n] = self.script[self.read_pos:n];
	self.read_pos += n;
	return n;
}

fn void? MemTransport.write(&self, char[] data, time::Duration timeout) @dynamic
{
	if (self.write_calls < MEM_RECORDS) self.write_timeouts[self.write_calls] = timeout;
	if (self.fail_writes) return CLOSED~;
	assert(self.written_len + data.len <= MEM_WRITTEN_CAP && self.write_calls < MEM_RECORDS);
	self.written[self.written_len:data.len] = data[..];
	self.write_lens[self.write_calls] = data.len;
	self.written_len += data.len;
	self.write_calls++;
}

fn void? MemTransport.close(&self) @dynamic
{
	self.close_calls++;
}

// The bytes of write call `k`.
fn char[] MemTransport.write_at(&self, usz k)
{
	usz start = 0;
	for (usz i = 0; i < k; i++) start += self.write_lens[i];
	return self.written[start:self.write_lens[k]];
}

fn void test_mem_transport_releases_replies_after_writes() @test
{
	MemTransport t;
	t.reply("01 02 03", 1);
	t.reply("04 05", 2);
	char[8] buf;
	assert(@catch(t.read(buf[..], (time::Duration)1)) == TIMEOUT);      // nothing is released before a write
	char[1] x = { 9 };
	t.write(x[..], (time::Duration)1)!!;
	assert(t.read(buf[..], (time::Duration)1)!! == 3);
	assert(@catch(t.read(buf[..], (time::Duration)1)) == TIMEOUT);
	t.write(x[..], (time::Duration)1)!!;
	t.chunk = 1;
	assert(t.read(buf[..], (time::Duration)1)!! == 1 && buf[0] == 4);
	t.eof_when_exhausted = true;
	assert(t.read(buf[..], (time::Duration)1)!! == 1 && buf[0] == 5);
	assert(@catch(t.read(buf[..], (time::Duration)1)) == CLOSED);
	assert(t.write_calls == 2 && t.read_calls == 6 && t.write_at(1).len == 1);
	t.close()!!;
	assert(t.close_calls == 1);
}
