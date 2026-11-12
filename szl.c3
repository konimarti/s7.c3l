module s7;

// ---- SZL types (Dtl and the calendar helpers live in value.c3) ----

struct ModuleId
{
	ushort index;
	String order_number;
	ushort module_type;
	ushort version;
}

fn void ModuleId.free(&self, Allocator allocator)
{
	self.order_number.free(allocator);
}

struct CpuInfo
{
	String module_name;
	String plant_id;
	String copyright;
	String serial;
	String module_type_name;
	String order_number;
}

fn void CpuInfo.free(&self, Allocator allocator)
{
	self.module_name.free(allocator);
	self.plant_id.free(allocator);
	self.copyright.free(allocator);
	self.serial.free(allocator);
	self.module_type_name.free(allocator);
	self.order_number.free(allocator);
}

enum CpuState : char
{
	UNKNOWN,
	STOP,
	RUN,
	STARTUP,
}

struct SzlPart
{
	ushort szl_id;
	ushort index;
	ushort rec_len;
	ushort rec_count;
	char   seq;
	bool   more;
	char[] records;
}

// Bounded reassembler for multi-fragment SZL responses.
struct SzlAssembler
{
	Limits    limits;
	ushort    szl_id;
	ushort    index;
	ushort    rec_len;
	ushort    rec_count;
	char      expected_seq;
	ushort    fragments;
	char[]    buffer;
	Allocator allocator;
}

fn SzlAssembler szl_assembler_init(Limits limits = DEFAULT_LIMITS, Allocator allocator = mem)
{
	SzlAssembler a;
	a.limits = limits;
	a.allocator = allocator;
	return a;
}

fn void? SzlAssembler.push(&self, SzlPart* part)
{
	if (self.fragments == 0)
	{
		self.szl_id = part.szl_id;
		self.index = part.index;
		self.rec_len = part.rec_len;
		self.rec_count = part.rec_count;
		self.expected_seq = part.seq;
	}
	else
	{
		if (part.seq != self.expected_seq)
		{
			return UNEXPECTED_PDU~;
		}
	}

	if (self.fragments >= self.limits.max_szl_fragments)
	{
		return BAD_RESPONSE~;
	}

	usz new_len = self.buffer.len + part.records.len;
	if (new_len > self.limits.max_request_bytes)
	{
		return INVALID_ARGUMENT~;
	}

	if (part.records.len > 0)
	{
		char[] new_buf = alloc::alloc_array(self.allocator, char, (sz)new_len);
		if (self.buffer.len > 0)
		{
			new_buf[:self.buffer.len] = self.buffer[..];
			alloc::free(self.allocator, self.buffer.ptr);
		}
		new_buf[self.buffer.len:part.records.len] = part.records[..];
		self.buffer = new_buf;
	}

	self.fragments++;
	self.expected_seq = (char)(part.seq + 1);
}

fn bool SzlAssembler.is_done(&self, SzlPart* last_part)
{
	return self.fragments > 0 && !last_part.more;
}

fn char[] SzlAssembler.records(&self)
{
	return self.buffer;
}

fn void SzlAssembler.free(&self)
{
	if (self.buffer.len > 0)
	{
		alloc::free(self.allocator, self.buffer.ptr);
		self.buffer = {};
	}
}

// ---- SZL request and response codec ----

const usz SZL_REQUEST_FRAME_LEN = 33;
const usz CLOCK_REQUEST_FRAME_LEN = 29;

// Encodes an SZL read request (TPKT + COTP DT + S7 Userdata).
// When seq == 0 this is the initial request; when seq != 0 this is a continuation request.
fn usz? encode_szl_request(ushort pdu_ref, ushort szl_id, ushort index, char seq, char[] out)
{
	if (out.len < SZL_REQUEST_FRAME_LEN) return BUFFER_TOO_SMALL~;

	// S7 Header (10 bytes) at out[7..16]
	out[7] = 0x32;
	out[8] = 0x07; // USERDATA
	put_be16(out, 9, 0)!;
	put_be16(out, 11, pdu_ref)!;
	put_be16(out, 13, 8)!; // param_len = 8
	put_be16(out, 15, 8)!; // data_len = 8

	// Userdata Parameter (8 bytes) at out[17..24]
	out[17] = 0x00;
	out[18] = 0x01;
	out[19] = 0x12;
	out[20] = 0x04; // plen = 4
	out[21] = 0x11; // method: request
	out[22] = 0x44; // function group: CPU functions
	out[23] = 0x01; // subfunction: read SZL
	out[24] = seq;

	// Userdata Data (8 bytes) at out[25..32]
	out[25] = 0xFF; // return code
	out[26] = 0x09; // transport size: octet string
	put_be16(out, 27, 4)!; // data length
	put_be16(out, 29, szl_id)!;
	put_be16(out, 31, index)!;

	return encode_dt_header(out, 26);
}

// Helper for continuation requests echoing the received sequence number.
fn usz? encode_szl_continuation_request(ushort pdu_ref, ushort szl_id, ushort index, char seq, char[] out)
{
	return encode_szl_request(pdu_ref, szl_id, index, seq, out);
}

// Decodes an SZL response (ROSCTR USERDATA).
fn SzlPart? decode_szl_response(S7Header* header)
{
	if (header.rosctr != USERDATA) return BAD_RESPONSE~;

	if (header.param.len < 12) return BAD_RESPONSE~;
	if (header.param[0] != 0x00 || header.param[1] != 0x01 || header.param[2] != 0x12) return BAD_RESPONSE~;
	if (header.param[3] != 0x08) return BAD_RESPONSE~;
	if (header.param[4] != 0x12) return BAD_RESPONSE~; // method: response
	if (header.param[5] != 0x84) return BAD_RESPONSE~; // CPU functions response
	if (header.param[6] != 0x01) return BAD_RESPONSE~; // subfunction: read SZL

	char seq = header.param[7];
	// param[8] is the data unit reference number; only param[9] (last data unit) says that more fragments follow
	char last_unit = header.param[9] != 0 ? (char)1 : (char)0;
	ushort param_err = get_be16(header.param, 10)!;

	if (param_err == 0xD401) return NOT_SUPPORTED~;
	if (param_err != 0) return NOT_SUPPORTED~;

	if (header.data.len < 4) return BAD_RESPONSE~;
	if ((char)header.data[0] == 0x0A) return NOT_SUPPORTED~;
	if ((char)header.data[0] != 0xFF) return BAD_RESPONSE~;
	if ((char)header.data[1] != 0x09) return BAD_RESPONSE~;

	ushort data_len = get_be16(header.data, 2)!;
	if ((usz)data_len != header.data.len - 4) return BAD_RESPONSE~;
	if (data_len < 8) return BAD_RESPONSE~;

	ushort szl_id = get_be16(header.data, 4)!;
	ushort index = get_be16(header.data, 6)!;
	ushort rec_len = get_be16(header.data, 8)!;
	ushort rec_count = get_be16(header.data, 10)!;

	usz total_records = (usz)rec_len * (usz)rec_count;
	usz available = (usz)data_len - 8;
	if (total_records > available) return BAD_RESPONSE~;

	SzlPart part;
	part.szl_id = szl_id;
	part.index = index;
	part.rec_len = rec_len;
	part.rec_count = rec_count;
	part.seq = seq;
	part.more = (last_unit == 1);
	part.records = header.data[12:total_records];
	return part;
}

// ---- Clock request and response codec ----

// Encodes a read clock request (TPKT + COTP DT + S7 Userdata).
fn usz? encode_clock_request(ushort pdu_ref, char[] out)
{
	if (out.len < CLOCK_REQUEST_FRAME_LEN) return BUFFER_TOO_SMALL~;

	// S7 Header (10 bytes) at out[7..16]
	out[7] = 0x32;
	out[8] = 0x07; // USERDATA
	put_be16(out, 9, 0)!;
	put_be16(out, 11, pdu_ref)!;
	put_be16(out, 13, 8)!; // param_len = 8
	put_be16(out, 15, 4)!; // data_len = 4

	// Userdata Parameter (8 bytes) at out[17..24]
	out[17] = 0x00;
	out[18] = 0x01;
	out[19] = 0x12;
	out[20] = 0x04; // plen = 4
	out[21] = 0x11; // method: request
	out[22] = 0x47; // function group: time functions
	out[23] = 0x01; // subfunction: read clock
	out[24] = 0x00; // seq = 0

	// Userdata Data (4 bytes) at out[25..28]
	out[25] = 0x0A;
	out[26] = 0x00;
	out[27] = 0x00;
	out[28] = 0x00;

	return encode_dt_header(out, 22);
}

fn char? bcd_to_bin(char b)
{
	char hi = (char)(((uint)b >> 4) & 0x0F);
	char lo = (char)((uint)b & 0x0F);
	if (hi > 9 || lo > 9) return INVALID_VALUE~;
	return (char)(hi * 10 + lo);
}

// Decodes a read clock response into Dtl.
fn Dtl? decode_clock_response(S7Header* header)
{
	if (header.rosctr != USERDATA) return BAD_RESPONSE~;

	if (header.param.len < 12) return BAD_RESPONSE~;
	if (header.param[0] != 0x00 || header.param[1] != 0x01 || header.param[2] != 0x12) return BAD_RESPONSE~;
	if (header.param[3] != 0x08) return BAD_RESPONSE~;
	if (header.param[4] != 0x12) return BAD_RESPONSE~;
	if (header.param[5] != 0x87) return BAD_RESPONSE~; // time functions response
	if (header.param[6] != 0x01) return BAD_RESPONSE~; // read clock

	ushort param_err = get_be16(header.param, 10)!;
	if (param_err != 0) return BAD_RESPONSE~;

	if (header.data.len < 14) return BAD_RESPONSE~;
	if ((char)header.data[0] != 0xFF) return BAD_RESPONSE~;
	if ((char)header.data[1] != 0x09) return BAD_RESPONSE~;

	ushort data_len = get_be16(header.data, 2)!;
	if (data_len < 10) return BAD_RESPONSE~;
	if ((usz)data_len != header.data.len - 4) return BAD_RESPONSE~;

	// 10 bytes: reserved(1), century(1), year(1), month(1), day(1), hour(1), min(1), sec(1), ms_hi(1), ms_lo_and_weekday(1)
	char cent_bcd = header.data[5];
	char yr_bcd = header.data[6];
	char cent = bcd_to_bin(cent_bcd)!;
	char yr = bcd_to_bin(yr_bcd)!;

	ushort year;
	if (cent > 0)
	{
		year = (ushort)((uint)cent * 100 + (uint)yr);
	}
	else
	{
		// Year pivot 90: 90..99 -> 1990..1999, 00..89 -> 2000..2089
		year = (ushort)((yr >= 90) ? (1900 + (uint)yr) : (2000 + (uint)yr));
	}

	char month = bcd_to_bin(header.data[7])!;
	if (month < 1 || month > 12) return INVALID_VALUE~;

	char day = bcd_to_bin(header.data[8])!;
	if (day < 1 || day > days_in_month(year, month)) return INVALID_VALUE~;

	char hour = bcd_to_bin(header.data[9])!;
	if (hour > 23) return INVALID_VALUE~;

	char minute = bcd_to_bin(header.data[10])!;
	if (minute > 59) return INVALID_VALUE~;

	char second = bcd_to_bin(header.data[11])!;
	if (second > 59) return INVALID_VALUE~;

	char ms_hi = bcd_to_bin(header.data[12])!;
	char last_byte = header.data[13];
	char ms_lo_nibble = (char)(((uint)last_byte >> 4) & 0x0F);
	char weekday = (char)((uint)last_byte & 0x0F);

	if (ms_lo_nibble > 9) return INVALID_VALUE~;
	if (weekday < 1 || weekday > 7) return INVALID_VALUE~;

	uint ms = (uint)ms_hi * 10 + (uint)ms_lo_nibble;
	if (ms > 999) return INVALID_VALUE~;

	Dtl d;
	d.year = year;
	d.month = month;
	d.day = day;
	d.weekday = weekday;
	d.hour = hour;
	d.minute = minute;
	d.second = second;
	d.nanosecond = ms * 1_000_000;
	return d;
}

// ---- Record decoders ----

fn String trim_and_clone(char[] raw, Allocator allocator)
{
	usz start = 0;
	usz end = raw.len;
	while (start < end && (raw[start] == ' ' || raw[start] == 0))
	{
		start++;
	}
	while (end > start && (raw[end - 1] == ' ' || raw[end - 1] == 0))
	{
		end--;
	}
	if (end <= start)
	{
		return "";
	}
	usz len = end - start;
	return ((String)raw[start:len]).copy(allocator);
}

// Decodes one 28-byte record of SZL 0x0011 (Module identification).
fn ModuleId? decode_module_id(char[] record, Allocator allocator = mem)
{
	if (record.len < 28) return BAD_RESPONSE~;

	ModuleId m;
	m.index = get_be16(record, 0)!;
	m.order_number = trim_and_clone(record[2:20], allocator);
	m.module_type = get_be16(record, 22)!;
	m.version = get_be16(record, 24)!;
	return m;
}

// Decodes records of SZL 0x001C (Component identification).
fn CpuInfo? decode_component_id(char[] records, ushort rec_len, Allocator allocator = mem)
{
	if (rec_len < 2) return BAD_RESPONSE~;
	if (records.len == 0 || records.len % rec_len != 0) return BAD_RESPONSE~;

	CpuInfo info;
	usz text_len = (usz)rec_len - 2;
	usz off = 0;

	while (off + rec_len <= records.len)
	{
		ushort idx = get_be16(records, off)!;
		char[] text_slice = records[off + 2:text_len];
		String str = trim_and_clone(text_slice, allocator);

		switch (idx)
		{
			case 1:
				if (info.module_name.len == 0)
				{
					info.module_name = str;
				}
				else if (str.len > 0)
				{
					str.free(allocator);
				}
			case 2:
				if (info.module_name.len > 0)
				{
					info.module_name.free(allocator);
				}
				info.module_name = str;
			case 3:
				info.plant_id = str;
			case 4:
				info.copyright = str;
			case 5:
				info.serial = str;
			case 6:
				info.order_number = str;
			case 7:
				info.module_type_name = str;
			default:
				if (str.len > 0)
				{
					str.free(allocator);
				}
		}
		off += rec_len;
	}

	return info;
}

// Decodes records of SZL 0x0424 (CPU state).
fn CpuState? decode_cpu_state(char[] records, ushort rec_len)
{
	if (rec_len < 4 || records.len < 4) return BAD_RESPONSE~;

	char status = records[3];
	switch (status)
	{
		case 0x08:
			return CpuState.RUN;
		case 0x04:
			return CpuState.STOP;
		case 0x01:
		case 0x02:
		case 0x03:
			return CpuState.STARTUP;
		default:
			return CpuState.UNKNOWN;
	}
}
