module s7;

import std::collections::list;

// Request planning and the Read Var / Write Var codec. Wire form of an item: BIT, BYTE (count = bytes),
// COUNTER or TIMER (see Tsize.wire), so cutting an item into chunks is plain byte arithmetic.
//
// Sizes below count the S7 PDU only (header, parameter, data), not the 7 bytes of TPKT and COTP, like the
// negotiated PDU size does:
//   read request   10 + 2 + 12 n
//   read response  12 + 2 + sum(4 + len + pad)
//   write request  10 + 2 + 12 n + sum(4 + len + pad)
// where pad is one byte after every data item of odd length except the last of the PDU.

const usz S7_JOB_HEADER_LEN = 10;
const usz S7_ACK_HEADER_LEN = 12;
const usz ITEM_PARAM_BASE = 2;             // function code and item count
const usz DATA_ITEM_OVERHEAD = 4;          // return code or reserved byte, transport size, length (2)
const usz MIN_PLAN_PDU_SIZE = 30;          // room for one 2-byte chunk of a write
const usz MAX_ITEMS_PER_PDU = 255;         // the item count is one byte

// Result of one item of a response. `status` is empty on success; `raw_code` is the return code as received
// (0xFF = success); `data` is a slice of the received frame (empty for a failed item and for writes).
struct ItemResult
{
	fault status;
	char raw_code;
	char[] data;
}

// A chunk of a logical item: bytes [offset, offset + length) of its payload. BIT items are one chunk of length 1.
struct Slice
{
	uint item;
	uint offset;
	uint length;
}

// The slices that travel in one request PDU.
struct Pdu
{
	Slice[] slices;
}

struct Plan
{
	Pdu[] pdus;
	Slice[] slices;      // backing storage of the PDUs
	Allocator allocator;
}

fn void Plan.free(&self)
{
	if (self.pdus.len > 0) alloc::free(self.allocator, self.pdus.ptr);
	if (self.slices.len > 0) alloc::free(self.allocator, self.slices.ptr);
	self.pdus = {};
	self.slices = {};
}

// Raw item return code -> fault. 0xFF is success and has no fault: callers test it first.
fn fault rc_to_fault(char rc)
{
	switch (rc)
	{
		case 0x01:
			return HARDWARE_FAULT;
		case 0x03:
			return ACCESS_DENIED;
		case 0x05:
			return ADDRESS_OUT_OF_RANGE;
		case 0x06:
			return DATA_TYPE_UNSUPPORTED;
		case 0x07:
			return TYPE_MISMATCH;
		case 0x0A:
			return OBJECT_DOES_NOT_EXIST;
		default:
			return UNKNOWN_RETURN_CODE;
	}
}

// ---- planner ----

struct PduState
{
	usz n;
	usz data;          // sum(4 + len) plus the pads of all but the last item
	bool last_odd;
}

fn bool PduState.fits(&self, usz len, usz pdu_size, usz max_items, bool write)
{
	if (self.n + 1 > max_items) return false;
	usz pad = (self.n > 0 && self.last_odd) ? 1 : 0;
	usz new_data = self.data + pad + DATA_ITEM_OVERHEAD + len;
	usz params = S7_JOB_HEADER_LEN + ITEM_PARAM_BASE + 12 * (self.n + 1);
	if (write) return params + new_data <= pdu_size;
	return params <= pdu_size && S7_ACK_HEADER_LEN + ITEM_PARAM_BASE + new_data <= pdu_size;
}

fn Plan? plan_items(Address[] items, ushort pdu_size, ushort max_items, uint max_request_bytes, bool write, Allocator allocator)
{
	if (items.len == 0 || max_items == 0 || pdu_size < MIN_PLAN_PDU_SIZE) return INVALID_ARGUMENT~;
	usz limit = max_items < MAX_ITEMS_PER_PDU ? max_items : MAX_ITEMS_PER_PDU;
	usz overhead = write ? 28 : 18;                      // PDU bytes around a lone chunk
	usz max_chunk = ((usz)pdu_size - overhead) & ~(usz)1; // even, so a following item needs no extra care
	ulong total = 0;
	foreach (a : items)
	{
		if (a.count == 0) return INVALID_ARGUMENT~;
		if (a.tsize == BIT && a.count != 1) return INVALID_ARGUMENT~;
		total += a.payload_bytes();
		if (total > max_request_bytes) return INVALID_ARGUMENT~;
	}

	@pool()
	{
		List{Slice} slices;
		slices.tinit();
		List{usz} ends;      // index one past the last slice of each PDU
		ends.tinit();
		PduState st;
		foreach (i, a : items)
		{
			Tsize wire = a.tsize.wire();
			usz remaining = a.payload_bytes();
			usz offset = 0;
			while (remaining > 0)
			{
				usz len = remaining;
				bool alone = false;
				if (wire == BIT)
				{
					len = 1;
				}
				else if (remaining > max_chunk)
				{
					len = max_chunk;
					alone = true;
				}
				// the chunk's start must stay addressable
				if (wire == COUNTER || wire == TIMER)
				{
					if ((usz)a.byte_off + offset / 2 > 0xFFFF) return ADDRESS_RANGE~;
				}
				else if (wire == BYTE && (usz)a.byte_off + offset > MAX_BYTE_OFFSET)
				{
					return ADDRESS_RANGE~;
				}
				if (alone || !st.fits(len, pdu_size, limit, write))
				{
					if (st.n > 0)
					{
						ends.push((usz)slices.len());
						st = {};
					}
				}
				slices.push({ (uint)i, (uint)offset, (uint)len });
				usz pad = (st.n > 0 && st.last_odd) ? 1 : 0;
				st.data += pad + DATA_ITEM_OVERHEAD + len;
				st.n++;
				st.last_odd = (len & 1) == 1;
				if (alone)
				{
					ends.push((usz)slices.len());
					st = {};
				}
				offset += len;
				remaining -= len;
			}
		}
		if (st.n > 0) ends.push((usz)slices.len());

		Plan plan;
		plan.allocator = allocator;
		plan.slices = alloc::new_array(allocator, Slice, (sz)slices.len())[:slices.len()];
		plan.pdus = alloc::new_array(allocator, Pdu, (sz)ends.len())[:ends.len()];
		foreach (k, s : slices) plan.slices[k] = s;
		usz start = 0;
		foreach (k, e : ends)
		{
			plan.pdus[k].slices = plan.slices[start:e - start];
			start = e;
		}
		return plan;
	};
}

// Cuts a read into request PDUs: at most `max_items` items, request and response within `pdu_size` (the
// negotiated PDU size), larger items cut into byte chunks. Pure function of its arguments.
fn Plan? plan_read(Address[] items, ushort pdu_size, ushort max_items, uint max_request_bytes, Allocator allocator)
{
	return plan_items(items, pdu_size, max_items, max_request_bytes, false, allocator);
}

fn Plan? plan_write(Address[] items, ushort pdu_size, ushort max_items, uint max_request_bytes, Allocator allocator)
{
	return plan_items(items, pdu_size, max_items, max_request_bytes, true, allocator);
}

// ---- request encoding ----

// The S7ANY item of one chunk: byte items move their offset, timers and counters count elements.
fn Address chunk_address(Address* a, Slice* s)
{
	Address c = *a;
	Tsize wire = a.tsize.wire();
	c.tsize = wire;
	switch (wire)
	{
		case BIT:
			c.count = 1;
		case COUNTER:
		case TIMER:
			c.byte_off = a.byte_off + s.offset / 2;
			c.count = s.length / 2;
		default:
			c.byte_off = a.byte_off + s.offset;
			c.count = s.length;
	}
	return c;
}

// Writes the frame header (TPKT, DT) and the S7 job header; returns the offset of the parameter block.
fn void? put_job_header(char[] out, ushort pdu_ref, usz param_len, usz data_len)
{
	if (param_len > 0xFFFF || data_len > 0xFFFF) return INVALID_ARGUMENT~;
	out[7] = 0x32;
	out[8] = 0x01;
	put_be16(out, 9, 0)!;
	put_be16(out, 11, pdu_ref)!;
	put_be16(out, 13, (ushort)param_len)!;
	put_be16(out, 15, (ushort)data_len)!;
}

fn void? check_slices(Address[] items, Pdu* pdu)
{
	if (pdu.slices.len == 0 || pdu.slices.len > MAX_ITEMS_PER_PDU) return INVALID_ARGUMENT~;
	foreach (s : pdu.slices)
	{
		if (s.item >= items.len) return INVALID_ARGUMENT~;
	}
}

// One Read Var request frame (TPKT + DT + S7 job) for the slices of `pdu`. Returns the frame length.
fn usz? encode_read_request(ushort pdu_ref, Address[] items, Pdu* pdu, char[] out)
{
	check_slices(items, pdu)!;
	usz n = pdu.slices.len;
	usz param_len = ITEM_PARAM_BASE + 12 * n;
	usz total = DT_HEADER_LEN + S7_JOB_HEADER_LEN + param_len;
	if (out.len < total) return BUFFER_TOO_SMALL~;
	put_job_header(out, pdu_ref, param_len, 0)!;
	out[17] = 0x04;
	out[18] = (char)n;
	usz at = 19;
	foreach (s : pdu.slices)
	{
		Address c = chunk_address(&items[s.item], &s);
		encode_item(&c, out[at:12])!;
		at += 12;
	}
	return encode_dt_header(out, total - DT_HEADER_LEN);
}

// One Write Var request frame. `data[i]` is the whole payload of logical item i; the slices pick their bytes.
// Bit items carry 1 byte (0 or 1). Timers and counters are sent as octet strings (verify against a peer).
fn usz? encode_write_request(ushort pdu_ref, Address[] items, char[][] data, Pdu* pdu, char[] out)
{
	check_slices(items, pdu)!;
	usz n = pdu.slices.len;
	usz param_len = ITEM_PARAM_BASE + 12 * n;
	usz data_len = 0;
	foreach (k, s : pdu.slices)
	{
		if (s.item >= data.len || (usz)s.offset + s.length > data[s.item].len) return INVALID_ARGUMENT~;
		data_len += DATA_ITEM_OVERHEAD + s.length;
		if ((usz)k + 1 < n && (s.length & 1) == 1) data_len += 1;
	}
	usz total = DT_HEADER_LEN + S7_JOB_HEADER_LEN + param_len + data_len;
	if (out.len < total) return BUFFER_TOO_SMALL~;
	put_job_header(out, pdu_ref, param_len, data_len)!;
	out[17] = 0x05;
	out[18] = (char)n;
	usz at = 19;
	foreach (s : pdu.slices)
	{
		Address c = chunk_address(&items[s.item], &s);
		encode_item(&c, out[at:12])!;
		at += 12;
	}
	foreach (k, s : pdu.slices)
	{
		Tsize wire = items[s.item].tsize.wire();
		usz bits_or_bytes;
		char ts;
		if (wire == BIT)
		{
			if (s.length != 1 || data[s.item][s.offset] > 1) return INVALID_ARGUMENT~;
			ts = 0x03;
			bits_or_bytes = 1;
		}
		else if (wire == BYTE)
		{
			if (s.length > 0x1FFF) return INVALID_ARGUMENT~;
			ts = 0x04;
			bits_or_bytes = (usz)s.length * 8;
		}
		else
		{
			ts = 0x09;
			bits_or_bytes = s.length;
		}
		out[at] = 0x00;
		out[at + 1] = ts;
		put_be16(out, at + 2, (ushort)bits_or_bytes)!;
		out[at + 4:s.length] = data[s.item][s.offset:s.length];
		at += DATA_ITEM_OVERHEAD + s.length;
		if ((usz)k + 1 < n && (s.length & 1) == 1)
		{
			out[at] = 0x00;
			at += 1;
		}
	}
	return encode_dt_header(out, total - DT_HEADER_LEN);
}

// ---- response decoding ----

// Common checks of an Ack_Data for function `function` and `count` items: a header error is S7_ERROR (also in a
// plain Ack, which carries no data), a wrong function code or item count is BAD_RESPONSE.
fn void? check_response(S7Header* header, char function, usz count)
{
	if (header == null) return INVALID_ARGUMENT~;
	if (header.rosctr != ACK_DATA && header.rosctr != ACK) return BAD_RESPONSE~;
	if (header.err_class != 0 || header.err_code != 0) return S7_ERROR~;
	if (header.rosctr != ACK_DATA) return BAD_RESPONSE~;
	if (header.param.len != ITEM_PARAM_BASE || header.param[0] != function) return BAD_RESPONSE~;
	if (header.param[1] != count) return BAD_RESPONSE~;
}

// Byte length of a read data item from its transport size and length field: bits for 0x03, 0x04, 0x05 and 0x07
// (a multiple of 8 for 0x04), bytes for 0x09, none for 0x00. Anything else is BAD_RESPONSE.
fn usz? data_item_bytes(char ts, usz len)
{
	switch (ts)
	{
		case 0x00:
			return 0;
		case 0x03:
		case 0x05:
		case 0x07:
			return (len + 7) / 8;
		case 0x04:
			if (len % 8 != 0) return BAD_RESPONSE~;
			return len / 8;
		case 0x09:
			return len;
		default:
			return BAD_RESPONSE~;
	}
}

// Parses a Read Var response into one ItemResult per slice of `pdu`. A successful item must carry exactly the
// number of bytes its slice asked for; failed items carry none. `data` of each result points into the frame.
fn void? decode_read_response(S7Header* header, Pdu* pdu, ItemResult[] results)
{
	if (header == null || pdu == null) return INVALID_ARGUMENT~;
	usz n = pdu.slices.len;
	if (results.len < n) return BUFFER_TOO_SMALL~;
	check_response(header, 0x04, n)!;
	char[] data = header.data;
	usz pos = 0;
	foreach (k, s : pdu.slices)
	{
		if (pos + DATA_ITEM_OVERHEAD > data.len) return BAD_RESPONSE~;
		char rc = data[pos];
		char ts = data[pos + 1];
		usz len = (usz)get_be16(data, pos + 2)!;
		usz bytes = 0;
		if (rc == 0xFF)
		{
			bytes = data_item_bytes(ts, len)!;
			if (bytes != s.length) return BAD_RESPONSE~;
		}
		else if (try declared = data_item_bytes(ts, len))
		{
			bytes = declared;   // a failed item normally declares transport size 0 and length 0
		}
		if (pos + DATA_ITEM_OVERHEAD + bytes > data.len) return BAD_RESPONSE~;
		results[k] = {};
		results[k].raw_code = rc;
		if (rc == 0xFF)
		{
			results[k].data = data[pos + DATA_ITEM_OVERHEAD : bytes];
		}
		else
		{
			results[k].status = rc_to_fault(rc);
		}
		pos += DATA_ITEM_OVERHEAD + bytes;
		if ((usz)k + 1 < n && (bytes & 1) == 1) pos += 1;
	}
	if (pos != data.len) return BAD_RESPONSE~;
}

// Parses a Write Var response: one return code byte per slice.
fn void? decode_write_response(S7Header* header, Pdu* pdu, ItemResult[] results)
{
	if (header == null || pdu == null) return INVALID_ARGUMENT~;
	usz n = pdu.slices.len;
	if (results.len < n) return BUFFER_TOO_SMALL~;
	check_response(header, 0x05, n)!;
	if (header.data.len != n) return BAD_RESPONSE~;
	foreach (k, s : pdu.slices)
	{
		char rc = header.data[k];
		results[k] = {};
		results[k].raw_code = rc;
		if (rc != 0xFF) results[k].status = rc_to_fault(rc);
	}
}
