module s7;

// S7 value types, big-endian on the wire. Decoders never read beyond the given bytes.

enum ValueKind : char
{
	BOOL,
	BYTE,
	WORD,
	DWORD,
	INT,
	DINT,
	REAL,
	LREAL,
	CHAR,
	STRING,
	WSTRING,
	DATE,
	TIME,
	TOD,
	DATE_AND_TIME,
	DTL,
	S5TIME,        // time base + 3 BCD digits, decoded to milliseconds
	COUNTER_BCD,   // 3 BCD digits 0..999
}

// DTL: 12 bytes, year u16, month, day, weekday (1 = Sunday), hour, minute, second, nanosecond u32.
struct Dtl
{
	ushort year;
	char month;
	char day;
	char weekday;
	char hour;
	char minute;
	char second;
	uint nanosecond;
}

// A decoded value. Only CHAR, STRING and WSTRING own memory (`str`, UTF-8, allocated by the allocator given to
// decode_value / parse_value; release it with Value.free).
struct Value
{
	ValueKind kind;
	union
	{
		bool b;        // BOOL
		ulong u;       // BYTE WORD DWORD, DATE (days since 1990-01-01), TOD (ms), S5TIME (ms), COUNTER_BCD
		long i;        // INT DINT TIME (ms)
		double f;      // REAL LREAL
		Dtl dtl;       // DTL and DATE_AND_TIME (nanosecond = milliseconds * 1000000)
		String str;    // CHAR STRING WSTRING
	}
}

const uint MAX_DATE_DAYS = 65378;          // 2168-12-31
const uint MS_PER_DAY = 86400000;
const uint MAX_DTL_YEAR = 2262;
const uint MIN_DTL_YEAR = 1970;

// Fixed wire size of a kind; 0 for STRING and WSTRING (their own length bytes drive it).
fn uint ValueKind.wire_size(self)
{
	switch (self)
	{
		case BOOL:
		case BYTE:
		case CHAR:
			return 1;
		case WORD:
		case INT:
		case DATE:
		case S5TIME:
		case COUNTER_BCD:
			return 2;
		case DWORD:
		case DINT:
		case REAL:
		case TIME:
		case TOD:
			return 4;
		case LREAL:
		case DATE_AND_TIME:
			return 8;
		case DTL:
			return 12;
		default:
			return 0;
	}
}

// Bit `bit` (0..7) of `b`.
fn bool decode_bool(char b, char bit) => ((b >> bit) & 1) != 0;

// ---- calendar and BCD helpers ----

fn bool is_leap(uint year) => (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;

fn uint days_in_month(uint year, uint month)
{
	switch (month)
	{
		case 2:
			return is_leap(year) ? 29 : 28;
		case 4:
		case 6:
		case 9:
		case 11:
			return 30;
		default:
			return 31;
	}
}

// Two BCD digits -> 0..99; a nibble above 9 is INVALID_VALUE.
fn uint? bcd(char b)
{
	if ((b >> 4) > 9 || (b & 0x0F) > 9) return INVALID_VALUE~;
	return (uint)(b >> 4) * 10 + (uint)(b & 0x0F);
}

fn char to_bcd(uint v) => (char)(((v / 10) << 4) | (v % 10));

fn void? check_dtl(Dtl* d, uint min_year, uint max_year)
{
	if (d.year < min_year || d.year > max_year) return INVALID_VALUE~;
	if (d.month < 1 || d.month > 12) return INVALID_VALUE~;
	if (d.day < 1 || d.day > days_in_month(d.year, d.month)) return INVALID_VALUE~;
	if (d.weekday < 1 || d.weekday > 7) return INVALID_VALUE~;
	if (d.hour > 23 || d.minute > 59 || d.second > 59) return INVALID_VALUE~;
	if (d.nanosecond >= 1000000000) return INVALID_VALUE~;
}

// ---- text conversion ----

// ISO 8859-1 bytes -> UTF-8 (every byte is a code point).
fn String latin1_to_utf8(char[] bytes, Allocator allocator)
{
	usz n = 0;
	foreach (c : bytes) n += c < 0x80 ? 1 : 2;
	if (n == 0) return "";
	char[] out = alloc::new_array(allocator, char, (sz)n);
	usz at = 0;
	foreach (c : bytes)
	{
		if (c < 0x80)
		{
			out[at++] = c;
		}
		else
		{
			out[at++] = 0xC0 | (c >> 6);
			out[at++] = 0x80 | (c & 0x3F);
		}
	}
	return (String)out;
}

// Next code point of a UTF-8 string at `*pos`. Overlong forms, surrogates and truncated sequences are INVALID_VALUE.
fn uint? next_code_point(String s, usz* pos)
{
	char c = s[*pos];
	*pos += 1;
	if (c < 0x80) return c;
	usz extra;
	uint cp;
	uint min;
	if ((c & 0xE0) == 0xC0)
	{
		extra = 1;
		cp = c & 0x1F;
		min = 0x80;
	}
	else if ((c & 0xF0) == 0xE0)
	{
		extra = 2;
		cp = c & 0x0F;
		min = 0x800;
	}
	else if ((c & 0xF8) == 0xF0)
	{
		extra = 3;
		cp = c & 0x07;
		min = 0x10000;
	}
	else
	{
		return INVALID_VALUE~;
	}
	if (*pos + extra > s.len) return INVALID_VALUE~;
	for (usz k = 0; k < extra; k++)
	{
		char d = s[*pos + k];
		if ((d & 0xC0) != 0x80) return INVALID_VALUE~;
		cp = (cp << 6) | (d & 0x3F);
	}
	*pos += extra;
	if (cp < min || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) return INVALID_VALUE~;
	return cp;
}

// Appends a code point as UTF-8 at out[at..]; returns the new position.
fn usz put_utf8(char[] out, usz at, uint cp)
{
	if (cp < 0x80)
	{
		out[at++] = (char)cp;
	}
	else if (cp < 0x800)
	{
		out[at++] = (char)(0xC0 | (cp >> 6));
		out[at++] = (char)(0x80 | (cp & 0x3F));
	}
	else if (cp < 0x10000)
	{
		out[at++] = (char)(0xE0 | (cp >> 12));
		out[at++] = (char)(0x80 | ((cp >> 6) & 0x3F));
		out[at++] = (char)(0x80 | (cp & 0x3F));
	}
	else
	{
		out[at++] = (char)(0xF0 | (cp >> 18));
		out[at++] = (char)(0x80 | ((cp >> 12) & 0x3F));
		out[at++] = (char)(0x80 | ((cp >> 6) & 0x3F));
		out[at++] = (char)(0x80 | (cp & 0x3F));
	}
	return at;
}

fn usz utf8_len(uint cp) => cp < 0x80 ? 1 : (cp < 0x800 ? 2 : (cp < 0x10000 ? 3 : 4));

// UTF-16BE units -> UTF-8; an unpaired surrogate is INVALID_VALUE.
fn String? utf16be_to_utf8(char[] bytes, usz units, Allocator allocator)
{
	usz n = 0;
	for (usz pass = 0; pass < 2; pass++)
	{
		char[] out;
		if (pass == 1)
		{
			if (n == 0) return "";
			out = alloc::new_array(allocator, char, (sz)n);
		}
		usz at = 0;
		usz i = 0;
		while (i < units)
		{
			uint u = (uint)get_be16(bytes, i * 2)!;
			i++;
			uint cp = u;
			if (u >= 0xD800 && u <= 0xDBFF)
			{
				if (i >= units) return INVALID_VALUE~;
				uint low = (uint)get_be16(bytes, i * 2)!;
				if (low < 0xDC00 || low > 0xDFFF) return INVALID_VALUE~;
				i++;
				cp = 0x10000 + ((u - 0xD800) << 10) + (low - 0xDC00);
			}
			else if (u >= 0xDC00 && u <= 0xDFFF)
			{
				return INVALID_VALUE~;
			}
			if (pass == 0)
			{
				n += utf8_len(cp);
			}
			else
			{
				at = put_utf8(out, at, cp);
			}
		}
		if (pass == 1) return (String)out;
	}
	return "";
}

// ---- decode ----

fn Value? decode_string(char[] bytes, Allocator allocator)
{
	if (bytes.len < 2) return VALUE_TOO_SHORT~;
	usz max = bytes[0];
	usz cur = bytes[1];
	if (cur > max) return INVALID_VALUE~;
	if (bytes.len < 2 + cur) return VALUE_TOO_SHORT~;
	Value v = { .kind = STRING };
	v.str = latin1_to_utf8(bytes[2:cur], allocator);
	return v;
}

fn Value? decode_wstring(char[] bytes, Allocator allocator)
{
	if (bytes.len < 4) return VALUE_TOO_SHORT~;
	usz max = (usz)get_be16(bytes, 0)!;
	usz cur = (usz)get_be16(bytes, 2)!;
	if (cur > max) return INVALID_VALUE~;
	if (bytes.len < 4 + 2 * cur) return VALUE_TOO_SHORT~;
	Value v = { .kind = WSTRING };
	v.str = utf16be_to_utf8(bytes[4:2 * cur], cur, allocator)!;
	return v;
}

fn Value? decode_date_and_time(char[] b)
{
	Dtl d;
	uint yy = bcd(b[0])!;
	d.year = (ushort)(yy >= 90 ? 1900 + yy : 2000 + yy);
	d.month = (char)bcd(b[1])!;
	d.day = (char)bcd(b[2])!;
	d.hour = (char)bcd(b[3])!;
	d.minute = (char)bcd(b[4])!;
	d.second = (char)bcd(b[5])!;
	if ((b[7] >> 4) > 9 || (b[6] >> 4) > 9 || (b[6] & 0x0F) > 9) return INVALID_VALUE~;
	uint ms = (uint)(b[6] >> 4) * 100 + (uint)(b[6] & 0x0F) * 10 + (uint)(b[7] >> 4);
	d.weekday = b[7] & 0x0F;
	d.nanosecond = ms * 1000000;
	check_dtl(&d, 1990, 2089)!;
	Value v = { .kind = DATE_AND_TIME };
	v.dtl = d;
	return v;
}

fn Value? decode_dtl(char[] b)
{
	Dtl d;
	d.year = get_be16(b, 0)!;
	d.month = b[2];
	d.day = b[3];
	d.weekday = b[4];
	d.hour = b[5];
	d.minute = b[6];
	d.second = b[7];
	d.nanosecond = get_be32(b, 8)!;
	check_dtl(&d, MIN_DTL_YEAR, MAX_DTL_YEAR)!;
	Value v = { .kind = DTL };
	v.dtl = d;
	return v;
}

// Time bases of S5TIME in milliseconds, index = bits 13-12.
const uint[4] S5_BASE_MS = { 10, 100, 1000, 10000 };

// Decode `bytes` (big-endian) as `kind`. Extra bytes after a fixed-size value are ignored. A short buffer is
// VALUE_TOO_SHORT, an impossible content (BCD nibble, date out of range, string length) is INVALID_VALUE.
// BOOL is bit 0 of bytes[0]; use decode_bool for another bit.
fn Value? decode_value(ValueKind kind, char[] bytes, Allocator allocator)
{
	if (kind == STRING) return decode_string(bytes, allocator);
	if (kind == WSTRING) return decode_wstring(bytes, allocator);
	if (bytes.len < kind.wire_size()) return VALUE_TOO_SHORT~;
	Value v = { .kind = kind };
	switch (kind)
	{
		case BOOL:
			v.b = decode_bool(bytes[0], 0);
		case BYTE:
			v.u = bytes[0];
		case WORD:
			v.u = get_be16(bytes, 0)!;
		case DWORD:
			v.u = get_be32(bytes, 0)!;
		case INT:
			v.i = (short)get_be16(bytes, 0)!;
		case DINT:
			v.i = (int)get_be32(bytes, 0)!;
		case REAL:
			v.f = bitcast(get_be32(bytes, 0)!, float);
		case LREAL:
			ulong bits = ((ulong)get_be32(bytes, 0)! << 32) | (ulong)get_be32(bytes, 4)!;
			v.f = bitcast(bits, double);
		case CHAR:
			v.str = latin1_to_utf8(bytes[:1], allocator);
		case DATE:
			uint days = get_be16(bytes, 0)!;
			if (days > MAX_DATE_DAYS) return INVALID_VALUE~;
			v.u = days;
		case TIME:
			v.i = (int)get_be32(bytes, 0)!;
		case TOD:
			uint ms = get_be32(bytes, 0)!;
			if (ms >= MS_PER_DAY) return INVALID_VALUE~;
			v.u = ms;
		case DATE_AND_TIME:
			return decode_date_and_time(bytes);
		case DTL:
			return decode_dtl(bytes);
		case S5TIME:
			uint w = get_be16(bytes, 0)!;
			uint hundreds = (w >> 8) & 0x0F;
			uint tens = (w >> 4) & 0x0F;
			uint ones = w & 0x0F;
			if (hundreds > 9 || tens > 9 || ones > 9) return INVALID_VALUE~;
			v.u = (ulong)(hundreds * 100 + tens * 10 + ones) * S5_BASE_MS[(w >> 12) & 3];
		case COUNTER_BCD:
			uint w = get_be16(bytes, 0)!;
			uint hundreds = (w >> 8) & 0x0F;
			uint tens = (w >> 4) & 0x0F;
			uint ones = w & 0x0F;
			if (hundreds > 9 || tens > 9 || ones > 9) return INVALID_VALUE~;
			v.u = (ulong)(hundreds * 100 + tens * 10 + ones);
		default:
			return INVALID_VALUE~;
	}
	return v;
}

// ---- encode ----

fn usz? encode_string(Value* value, char[] out, uint max_len)
{
	if (max_len > 255) return INVALID_VALUE~;
	usz total = 2 + (usz)max_len;
	if (out.len < total) return BUFFER_TOO_SMALL~;
	String s = value.str;
	usz cur = 0;
	usz pos = 0;
	while (pos < s.len)
	{
		uint cp = next_code_point(s, &pos)!;
		if (cp > 0xFF || cur >= (usz)max_len) return INVALID_VALUE~;
		out[2 + cur] = (char)cp;
		cur++;
	}
	out[0] = (char)max_len;
	out[1] = (char)cur;
	for (usz k = 2 + cur; k < total; k++) out[k] = 0;
	return total;
}

fn usz? encode_wstring(Value* value, char[] out, uint max_len)
{
	if (max_len > 0xFFFF) return INVALID_VALUE~;
	usz total = 4 + 2 * (usz)max_len;
	if (out.len < total) return BUFFER_TOO_SMALL~;
	String s = value.str;
	usz cur = 0;
	usz pos = 0;
	while (pos < s.len)
	{
		uint cp = next_code_point(s, &pos)!;
		usz need = cp >= 0x10000 ? 2 : 1;
		if (cur + need > (usz)max_len) return INVALID_VALUE~;
		if (cp >= 0x10000)
		{
			uint c = cp - 0x10000;
			put_be16(out, 4 + cur * 2, (ushort)(0xD800 + (c >> 10)))!;
			put_be16(out, 4 + cur * 2 + 2, (ushort)(0xDC00 + (c & 0x3FF)))!;
		}
		else
		{
			put_be16(out, 4 + cur * 2, (ushort)cp)!;
		}
		cur += need;
	}
	put_be16(out, 0, (ushort)max_len)!;
	put_be16(out, 2, (ushort)cur)!;
	for (usz k = 4 + cur * 2; k < total; k++) out[k] = 0;
	return total;
}

fn usz? encode_date_and_time(Dtl* d, char[] out)
{
	if (d.year < 1990 || d.year > 2089) return INVALID_VALUE~;
	check_dtl(d, 1990, 2089)!;
	uint ms = d.nanosecond / 1000000;
	out[0] = to_bcd(d.year % 100);
	out[1] = to_bcd(d.month);
	out[2] = to_bcd(d.day);
	out[3] = to_bcd(d.hour);
	out[4] = to_bcd(d.minute);
	out[5] = to_bcd(d.second);
	out[6] = (char)(((ms / 100) << 4) | ((ms / 10) % 10));
	out[7] = (char)(((ms % 10) << 4) | d.weekday);
	return 8;
}

// Encode into `out`: the exact wire size for fixed kinds; STRING 2 + max_len and WSTRING 4 + 2 * max_len bytes
// (padded with zeros; `max_len` is the declared capacity, 254 for a plain STRING, ignored for other kinds).
// A value that does not fit its kind (INT 40000, a character above U+00FF in a STRING, a string longer than
// max_len, S5TIME not representable) is INVALID_VALUE. Returns the bytes written.
fn usz? encode_value(Value* value, char[] out, uint max_len)
{
	ValueKind kind = value.kind;
	if (kind == STRING) return encode_string(value, out, max_len);
	if (kind == WSTRING) return encode_wstring(value, out, max_len);
	usz size = kind.wire_size();
	if (out.len < size) return BUFFER_TOO_SMALL~;
	switch (kind)
	{
		case BOOL:
			out[0] = value.b ? 1 : 0;
		case BYTE:
			if (value.u > 0xFF) return INVALID_VALUE~;
			out[0] = (char)value.u;
		case WORD:
			if (value.u > 0xFFFF) return INVALID_VALUE~;
			put_be16(out, 0, (ushort)value.u)!;
		case DWORD:
			if (value.u > 0xFFFFFFFF) return INVALID_VALUE~;
			put_be32(out, 0, (uint)value.u)!;
		case INT:
			if (value.i < -32768 || value.i > 32767) return INVALID_VALUE~;
			put_be16(out, 0, (ushort)(short)value.i)!;
		case DINT:
		case TIME:
			if (value.i < -2147483648 || value.i > 2147483647) return INVALID_VALUE~;
			put_be32(out, 0, (uint)(int)value.i)!;
		case REAL:
			put_be32(out, 0, bitcast((float)value.f, uint))!;
		case LREAL:
			ulong bits = bitcast(value.f, ulong);
			put_be32(out, 0, (uint)(bits >> 32))!;
			put_be32(out, 4, (uint)bits)!;
		case CHAR:
			usz pos = 0;
			if (value.str.len == 0) return INVALID_VALUE~;
			uint cp = next_code_point(value.str, &pos)!;
			if (pos != value.str.len || cp > 0xFF) return INVALID_VALUE~;
			out[0] = (char)cp;
		case DATE:
			if (value.u > MAX_DATE_DAYS) return INVALID_VALUE~;
			put_be16(out, 0, (ushort)value.u)!;
		case TOD:
			if (value.u >= MS_PER_DAY) return INVALID_VALUE~;
			put_be32(out, 0, (uint)value.u)!;
		case DATE_AND_TIME:
			return encode_date_and_time(&value.dtl, out);
		case DTL:
			check_dtl(&value.dtl, MIN_DTL_YEAR, MAX_DTL_YEAR)!;
			put_be16(out, 0, value.dtl.year)!;
			out[2] = value.dtl.month;
			out[3] = value.dtl.day;
			out[4] = value.dtl.weekday;
			out[5] = value.dtl.hour;
			out[6] = value.dtl.minute;
			out[7] = value.dtl.second;
			put_be32(out, 8, value.dtl.nanosecond)!;
		case S5TIME:
			bool found = false;
			for (uint base = 0; base < 4; base++)
			{
				uint unit = S5_BASE_MS[base];
				if (value.u % unit == 0 && value.u / unit <= 999)
				{
					uint n = (uint)(value.u / unit);
					put_be16(out, 0, (ushort)((base << 12) | ((n / 100) << 8) | (((n / 10) % 10) << 4) | (n % 10)))!;
					found = true;
					break;
				}
			}
			if (!found) return INVALID_VALUE~;
		case COUNTER_BCD:
			if (value.u > 999) return INVALID_VALUE~;
			uint n = (uint)value.u;
			put_be16(out, 0, (ushort)(((n / 100) << 8) | (((n / 10) % 10) << 4) | (n % 10)))!;
		default:
			return INVALID_VALUE~;
	}
	return size;
}

// Release the string of a CHAR, STRING or WSTRING value (a no-op for other kinds).
fn void Value.free(&self, Allocator allocator)
{
	if ((self.kind == CHAR || self.kind == STRING || self.kind == WSTRING) && self.str.len > 0)
	{
		alloc::free(allocator, self.str.ptr);
	}
	self.str = "";
}

// ---- CLI literals ----

fn bool lower_eq(String s, String word)
{
	if (s.len != word.len) return false;
	foreach (i, c : s)
	{
		char d = (c >= 'A' && c <= 'Z') ? c + 32 : c;
		if (d != word[i]) return false;
	}
	return true;
}

// Strict integer: optional sign (when `signed`), decimal digits, or 0x hex for unsigned kinds. No spaces.
fn long? parse_integer(String text, bool signed)
{
	if (text.len == 0) return INVALID_VALUE~;
	usz i = 0;
	bool neg = false;
	if (text[0] == '-' || text[0] == '+')
	{
		if (!signed) return INVALID_VALUE~;
		neg = text[0] == '-';
		i = 1;
	}
	uint base = 10;
	if (!signed && text.len > 2 && text[0] == '0' && (text[1] == 'x' || text[1] == 'X'))
	{
		base = 16;
		i = 2;
	}
	if (i >= text.len) return INVALID_VALUE~;
	ulong v = 0;
	for (; i < text.len; i++)
	{
		char c = text[i];
		uint d;
		if (c >= '0' && c <= '9')
		{
			d = c - '0';
		}
		else if (base == 16 && c >= 'a' && c <= 'f')
		{
			d = c - 'a' + 10;
		}
		else if (base == 16 && c >= 'A' && c <= 'F')
		{
			d = c - 'A' + 10;
		}
		else
		{
			return INVALID_VALUE~;
		}
		v = v * base + d;
		if (v > 0x7FFFFFFFFFFFFFFF) return INVALID_VALUE~;
	}
	return neg ? -(long)v : (long)v;
}

fn double? parse_float(String text)
{
	if (text.len == 0) return INVALID_VALUE~;
	bool digit = false;
	foreach (c : text)
	{
		if (c >= '0' && c <= '9')
		{
			digit = true;
		}
		else if (c != '+' && c != '-' && c != '.' && c != 'e' && c != 'E')
		{
			return INVALID_VALUE~;
		}
	}
	if (!digit) return INVALID_VALUE~;
	double? d = text.to_double();
	if (catch d) return INVALID_VALUE~;
	return d;
}

// Text between matching single or double quotes (no escapes), or INVALID_VALUE.
fn String? unquote(String text)
{
	if (text.len < 2) return INVALID_VALUE~;
	char q = text[0];
	if ((q != '\'' && q != '"') || text[text.len - 1] != q) return INVALID_VALUE~;
	return text[1..text.len - 2];
}

// Literals of the CLI "write" command: true/false/1/0 for BOOL, decimal (or 0x hex for unsigned kinds) integers,
// floats, quoted text for CHAR/STRING/WSTRING ('abc' or "abc", no escapes) and plain integers for DATE (days),
// TIME, TOD and S5TIME (milliseconds) and COUNTER_BCD. DATE_AND_TIME and DTL literals are not supported in v1
// (INVALID_VALUE). The result is range checked like encode_value does.
fn Value? parse_value(ValueKind kind, String text, Allocator allocator)
{
	Value v = { .kind = kind };
	switch (kind)
	{
		case BOOL:
			if (lower_eq(text, "true") || text == "1")
			{
				v.b = true;
			}
			else if (lower_eq(text, "false") || text == "0")
			{
				v.b = false;
			}
			else
			{
				return INVALID_VALUE~;
			}
		case BYTE:
		case WORD:
		case DWORD:
		case DATE:
		case TOD:
		case S5TIME:
		case COUNTER_BCD:
			long n = parse_integer(text, false)!;
			v.u = (ulong)n;
		case INT:
		case DINT:
		case TIME:
			v.i = parse_integer(text, true)!;
		case REAL:
		case LREAL:
			v.f = parse_float(text)!;
		case CHAR:
		case STRING:
		case WSTRING:
			String inner = unquote(text)!;
			if (inner.len > 0) v.str = inner.copy(allocator);
		default:
			return INVALID_VALUE~;
	}
	// range check through the encoder
	char[1100] scratch;
	Value probe = v;
	if (!@ok(encode_value(&probe, scratch[..], 254)))
	{
		v.free(allocator);
		return INVALID_VALUE~;
	}
	return v;
}
