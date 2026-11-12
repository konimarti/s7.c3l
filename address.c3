module s7;

// S7 addresses: text form ("DB1.DBX0.3", "MW20", "T5") and the 12-byte S7ANY item of Read/Write Var.

enum Area : char (char code)
{
	PERIPHERY { 0x80 },   // P: PIB/PIW/PID and PQB/PQW/PQD, direct peripheral access
	INPUTS    { 0x81 },   // I / E
	OUTPUTS   { 0x82 },   // Q / A
	MERKERS   { 0x83 },   // M
	DB        { 0x84 },   // DB
	DI        { 0x85 },   // instance DB
	LOCAL     { 0x86 },   // L (rarely readable)
	COUNTER   { 0x1C },   // C / Z
	TIMER     { 0x1D },   // T
}

// API-level element type of an address (used by the value codec). On the wire the client sends only
// BIT, BYTE (count = bytes), COUNTER or TIMER items: see Tsize.wire.
enum Tsize : char (char code, uint elem_bytes)
{
	BIT     { 0x01, 0 },   // one bit; elem_bytes 0 means "1 bit"
	BYTE    { 0x02, 1 },
	CHAR    { 0x03, 1 },
	WORD    { 0x04, 2 },
	INT     { 0x05, 2 },
	DWORD   { 0x06, 4 },
	DINT    { 0x07, 4 },
	REAL    { 0x08, 4 },
	COUNTER { 0x1C, 2 },
	TIMER   { 0x1D, 2 },
}

// The transport size actually put into the S7ANY item.
fn Tsize Tsize.wire(self)
{
	switch (self)
	{
		case BIT:
			return BIT;
		case COUNTER:
			return COUNTER;
		case TIMER:
			return TIMER;
		default:
			return BYTE;
	}
}

// One addressed region: what goes into a 12-byte S7ANY item.
struct Address
{
	Area area;
	ushort db;           // DB number for DB and DI, 0 otherwise
	uint byte_off;       // byte offset (index for counters and timers)
	char bit;            // 0..7, only meaningful for Tsize.BIT
	Tsize tsize;
	uint count;          // number of elements of tsize
}

const uint MAX_BYTE_OFFSET = 0x1FFFFF;   // the item carries a 24 bit bit-address: byte * 8 + bit
const uint MAX_ITEM_COUNT = 0xFFFF;
const uint ITEM_LEN = 12;

// ---- parser ----

struct Scan
{
	String s;
	usz pos;
}

fn char upper(char c) => (c >= 'a' && c <= 'z') ? c - 32 : c;

fn bool Scan.done(&self) => self.pos >= self.s.len;

// The next character folded to upper case, 0 at the end.
fn char Scan.peek(&self) => self.done() ? 0 : upper(self.s[self.pos]);

// Consumes `c` (case-insensitive) or fails.
fn void? Scan.expect(&self, char c)
{
	if (self.done() || upper(self.s[self.pos]) != c) return INVALID_ADDRESS_TEXT~;
	self.pos++;
}

// Decimal digits only. No digits: INVALID_ADDRESS_TEXT; more than 32 bits: ADDRESS_RANGE (never wraps).
fn ulong? Scan.number(&self)
{
	usz start = self.pos;
	ulong v = 0;
	bool over = false;
	while (self.pos < self.s.len && self.s[self.pos] >= '0' && self.s[self.pos] <= '9')
	{
		v = v * 10 + (ulong)(self.s[self.pos] - '0');
		if (v > 0xFFFFFFFF)
		{
			over = true;
			v = 0x100000000;
		}
		self.pos++;
	}
	if (self.pos == start) return INVALID_ADDRESS_TEXT~;
	if (over) return ADDRESS_RANGE~;
	return v;
}

fn uint? Scan.byte_offset(&self)
{
	ulong v = self.number()!;
	if (v > MAX_BYTE_OFFSET) return ADDRESS_RANGE~;
	return (uint)v;
}

fn char? Scan.bit_number(&self)
{
	ulong v = self.number()!;
	if (v > 7) return ADDRESS_RANGE~;
	return (char)v;
}

// Optional "[n]" or ":n"; 1 when absent. Anything else left over is trailing garbage.
fn uint? Scan.range(&self)
{
	if (self.done()) return 1;
	char c = self.s[self.pos];
	ulong n;
	if (c == ':')
	{
		self.pos++;
		n = self.number()!;
	}
	else if (c == '[')
	{
		self.pos++;
		n = self.number()!;
		if (self.done() || self.s[self.pos] != ']') return INVALID_ADDRESS_TEXT~;
		self.pos++;
	}
	else
	{
		return INVALID_ADDRESS_TEXT~;
	}
	if (n == 0 || n > MAX_ITEM_COUNT) return ADDRESS_RANGE~;
	return (uint)n;
}

// B, W or D after an area letter.
fn Tsize? size_letter(char c)
{
	switch (c)
	{
		case 'B':
			return BYTE;
		case 'W':
			return WORD;
		case 'D':
			return DWORD;
		default:
			return INVALID_ADDRESS_TEXT~;
	}
}

// DBn.DBX0.3 / DBn.DBB0 / DBn.DBW0 / DBn.DBD0 and the DI spellings; "DB" and "DI" are interchangeable in both
// places.
fn void? parse_db(Scan* sc, Address* a)
{
	sc.expect('D')!;
	char c = sc.peek();
	if (c == 'B')
	{
		a.area = DB;
	}
	else if (c == 'I')
	{
		a.area = DI;
	}
	else
	{
		return INVALID_ADDRESS_TEXT~;
	}
	sc.pos++;
	ulong n = sc.number()!;
	if (n == 0 || n > 0xFFFF) return ADDRESS_RANGE~;
	a.db = (ushort)n;
	sc.expect('.')!;
	sc.expect('D')!;
	c = sc.peek();
	if (c != 'B' && c != 'I') return INVALID_ADDRESS_TEXT~;
	sc.pos++;
	c = sc.peek();
	if (c == 'X')
	{
		sc.pos++;
		a.byte_off = sc.byte_offset()!;
		sc.expect('.')!;
		a.bit = sc.bit_number()!;
		a.tsize = BIT;
		return;
	}
	a.tsize = size_letter(c)!;
	sc.pos++;
	a.byte_off = sc.byte_offset()!;
}

// PIB4, PQW8, ...: peripheral inputs and outputs share the area code.
fn void? parse_periph(Scan* sc, Address* a)
{
	sc.expect('P')!;
	char c = sc.peek();
	if (c != 'I' && c != 'Q') return INVALID_ADDRESS_TEXT~;
	sc.pos++;
	a.area = PERIPHERY;
	a.tsize = size_letter(sc.peek())!;
	sc.pos++;
	a.byte_off = sc.byte_offset()!;
}

// I/E, Q/A, M, L: letter, then B/W/D + byte, or byte "." bit.
fn void? parse_area(Scan* sc, Address* a, Area area)
{
	sc.pos++;
	a.area = area;
	char c = sc.peek();
	if (c == 'B' || c == 'W' || c == 'D')
	{
		a.tsize = size_letter(c)!;
		sc.pos++;
		a.byte_off = sc.byte_offset()!;
		return;
	}
	a.byte_off = sc.byte_offset()!;
	sc.expect('.')!;
	a.bit = sc.bit_number()!;
	a.tsize = BIT;
}

// T5 and C3 (also Z3): one index.
fn void? parse_timer_counter(Scan* sc, Address* a, Area area)
{
	sc.pos++;
	a.area = area;
	a.tsize = area == TIMER ? TIMER : COUNTER;
	ulong n = sc.number()!;
	if (n > 0xFFFF) return ADDRESS_RANGE~;
	a.byte_off = (uint)n;
}

// "DB1.DBX0.3", "DB1.DBW2", "DB1.DBD4", "DB10.DBB0[16]" (also "DB10.DBB0:16"), "MW20", "I0.1", "QB4",
// "PIW4", "DI2.DIW0" (also "DI2.DBW0"), "T5", "C3". Case-insensitive, no spaces. A bit address takes no range.
// Syntax errors: INVALID_ADDRESS_TEXT; numbers out of range or overflowing: ADDRESS_RANGE.
fn Address? parse_address(String text)
{
	Scan sc = { text, 0 };
	if (sc.done()) return INVALID_ADDRESS_TEXT~;
	Address a;
	switch (sc.peek())
	{
		case 'D':
			parse_db(&sc, &a)!;
		case 'P':
			parse_periph(&sc, &a)!;
		case 'I':
		case 'E':
			parse_area(&sc, &a, INPUTS)!;
		case 'Q':
		case 'A':
			parse_area(&sc, &a, OUTPUTS)!;
		case 'M':
			parse_area(&sc, &a, MERKERS)!;
		case 'L':
			parse_area(&sc, &a, LOCAL)!;
		case 'T':
			parse_timer_counter(&sc, &a, TIMER)!;
		case 'C':
		case 'Z':
			parse_timer_counter(&sc, &a, COUNTER)!;
		default:
			return INVALID_ADDRESS_TEXT~;
	}
	uint count = sc.range()!;
	if (!sc.done()) return INVALID_ADDRESS_TEXT~;
	if (a.tsize == BIT && count > 1) return INVALID_ADDRESS_TEXT~;
	a.count = count;
	return a;
}

// ---- text output ----

fn String size_letter_text(Tsize t)
{
	switch (t.elem_bytes)
	{
		case 2:
			return "W";
		case 4:
			return "D";
		default:
			return "B";
	}
}

// Canonical text, the inverse of parse_address: "DB1.DBX0.3", "DI2.DIW0", "PIB4" (peripheral outputs print as
// inputs), "DB10.DBB0[16]". A bracket range is printed when count > 1.
fn String Address.to_string(&self, Allocator allocator)
{
	String letter = size_letter_text(self.tsize);
	String range = "";
	@pool()
	{
		if (self.count > 1 && self.tsize != BIT) range = string::tformat("[%d]", self.count).copy(tmem);
		String text;
		switch (self.area)
		{
			case DB:
				if (self.tsize == BIT)
				{
					text = string::tformat("DB%d.DBX%d.%d", self.db, self.byte_off, self.bit);
				}
				else
				{
					text = string::tformat("DB%d.DB%s%d%s", self.db, letter, self.byte_off, range);
				}
			case DI:
				if (self.tsize == BIT)
				{
					text = string::tformat("DI%d.DIX%d.%d", self.db, self.byte_off, self.bit);
				}
				else
				{
					text = string::tformat("DI%d.DI%s%d%s", self.db, letter, self.byte_off, range);
				}
			case PERIPHERY:
				text = string::tformat("PI%s%d%s", letter, self.byte_off, range);
			case TIMER:
				text = string::tformat("T%d%s", self.byte_off, range);
			case COUNTER:
				text = string::tformat("C%d%s", self.byte_off, range);
			default:
				String area = self.area == INPUTS ? "I" : (self.area == OUTPUTS ? "Q" : (self.area == MERKERS ? "M" : "L"));
				if (self.tsize == BIT)
				{
					text = string::tformat("%s%d.%d", area, self.byte_off, self.bit);
				}
				else
				{
					text = string::tformat("%s%s%d%s", area, letter, self.byte_off, range);
				}
		}
		return text.copy(allocator);
	};
}

// Payload bytes of a read or write of this address (a bit item: 1). Saturates at the uint maximum.
fn uint Address.payload_bytes(&self)
{
	ulong per = self.tsize.elem_bytes == 0 ? 1 : self.tsize.elem_bytes;
	ulong total = (ulong)self.count * per;
	return total > 0xFFFFFFFF ? 0xFFFFFFFF : (uint)total;
}

// ---- S7ANY item ----

// 12 bytes: 12 0A 10 tsize len(2) db(2) area addr(3). Bit and byte items carry byte * 8 + bit, timers and counters
// their index. Bit items must have count 1; byte items carry the payload byte count (at most 0xFFFF per item:
// larger requests are cut up by the planner).
fn usz? encode_item(Address* a, char[] out)
{
	if (out.len < ITEM_LEN) return BUFFER_TOO_SMALL~;
	if (a.count == 0) return INVALID_ARGUMENT~;
	Tsize wire = a.tsize.wire();
	uint length;
	uint addr;
	switch (wire)
	{
		case BIT:
			if (a.count != 1) return INVALID_ARGUMENT~;
			if (a.bit > 7 || a.byte_off > MAX_BYTE_OFFSET) return ADDRESS_RANGE~;
			length = 1;
			addr = a.byte_off * 8 + a.bit;
		case COUNTER:
		case TIMER:
			if (a.count > MAX_ITEM_COUNT) return INVALID_ARGUMENT~;
			if (a.byte_off > 0xFFFF) return ADDRESS_RANGE~;
			length = a.count;
			addr = a.byte_off;
		default:
			uint bytes = a.payload_bytes();
			if (bytes > MAX_ITEM_COUNT) return INVALID_ARGUMENT~;
			if (a.byte_off > MAX_BYTE_OFFSET) return ADDRESS_RANGE~;
			length = bytes;
			addr = a.byte_off * 8;
	}
	out[0] = 0x12;
	out[1] = 0x0A;
	out[2] = 0x10;
	out[3] = wire.code;
	put_be16(out, 4, (ushort)length)!;
	put_be16(out, 6, a.db)!;
	out[8] = a.area.code;
	out[9] = (char)(addr >> 16);
	out[10] = (char)(addr >> 8);
	out[11] = (char)addr;
	return ITEM_LEN;
}

fn Tsize? tsize_from_code(char code)
{
	switch (code)
	{
		case 0x01:
			return BIT;
		case 0x02:
			return BYTE;
		case 0x03:
			return CHAR;
		case 0x04:
			return WORD;
		case 0x05:
			return INT;
		case 0x06:
			return DWORD;
		case 0x07:
			return DINT;
		case 0x08:
			return REAL;
		case 0x1C:
			return COUNTER;
		case 0x1D:
			return TIMER;
		default:
			return BAD_RESPONSE~;
	}
}

fn Area? area_from_code(char code)
{
	switch (code)
	{
		case 0x80:
			return PERIPHERY;
		case 0x81:
			return INPUTS;
		case 0x82:
			return OUTPUTS;
		case 0x83:
			return MERKERS;
		case 0x84:
			return DB;
		case 0x85:
			return DI;
		case 0x86:
			return LOCAL;
		case 0x1C:
			return COUNTER;
		case 0x1D:
			return TIMER;
		default:
			return BAD_RESPONSE~;
	}
}

// Inverse of encode_item: `count` is the item's length field (elements, bytes for byte items).
fn Address? decode_item(char[] bytes)
{
	if (bytes.len < ITEM_LEN) return TRUNCATED~;
	if (bytes[0] != 0x12 || bytes[1] != 0x0A || bytes[2] != 0x10) return BAD_RESPONSE~;
	Address a;
	a.tsize = tsize_from_code(bytes[3])!;
	a.count = get_be16(bytes, 4)!;
	a.db = get_be16(bytes, 6)!;
	a.area = area_from_code(bytes[8])!;
	uint addr = ((uint)bytes[9] << 16) | ((uint)bytes[10] << 8) | (uint)bytes[11];
	if (a.tsize == COUNTER || a.tsize == TIMER)
	{
		a.byte_off = addr;
	}
	else if (a.tsize == BIT)
	{
		a.byte_off = addr >> 3;
		a.bit = (char)(addr & 7);
	}
	else
	{
		if ((addr & 7) != 0) return BAD_RESPONSE~;
		a.byte_off = addr >> 3;
	}
	return a;
}
