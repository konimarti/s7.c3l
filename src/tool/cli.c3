module s7tool;

import std::io, std::time;
import s7;

// The command line tool of the library: option parsing, output formatting and the commands. The pure parts are tested
// in src/test/cli_test.c3; example/s7tool.c3 only calls `run`.
//
//   s7tool [options] info
//   s7tool [options] read ADDRESS [--type TYPE]
//   s7tool [options] write ADDRESS VALUE [--type TYPE] --allow-write
//   s7tool [options] dump ADDRESS LENGTH
//
// Exit codes: 0 ok, 1 usage, 2 write refused, 3 connection or protocol failure, 4 the PLC refused or lacks the object.

faultdef USAGE;

const int EXIT_OK = 0;
const int EXIT_USAGE = 1;
const int EXIT_REFUSED = 2;
const int EXIT_CONNECTION = 3;
const int EXIT_PLC = 4;

enum Command : char
{
	NONE,
	INFO,
	READ,
	WRITE,
	DUMP,
}

struct Options
{
	String host;
	int port;
	uint rack;
	uint slot;
	bool rack_set;
	bool slot_set;
	ConnType conn;
	String model;
	bool has_tsap;
	Tsaps tsap;
	long timeout_ms;
	bool has_type;
	ValueKind kind;
	bool allow_write;
	bool help;
	Command command;
	String address;
	String value;
	uint dump_len;
	String error;               // the message of the last USAGE fault
}

fn Options default_options()
{
	Options o;
	o.port = 102;
	o.rack = 0;
	o.slot = 2;
	o.conn = PG;
	o.timeout_ms = 5000;
	return o;
}

// ---- text helpers ----

fn bool is_digit(char c) => c >= '0' && c <= '9';

fn int? hex_value(char c)
{
	if (c >= '0' && c <= '9') return c - '0';
	if (c >= 'a' && c <= 'f') return c - 'a' + 10;
	if (c >= 'A' && c <= 'F') return c - 'A' + 10;
	return USAGE~;
}

// Decimal digits only, at most `max`.
fn ulong? parse_number(String s, ulong max)
{
	if (s.len == 0) return USAGE~;
	ulong v = 0;
	foreach (c : s)
	{
		if (!is_digit(c)) return USAGE~;
		v = v * 10 + (ulong)(c - '0');
		if (v > max) return USAGE~;
	}
	return v;
}

fn bool lower_equals(String s, String word)
{
	if (s.len != word.len) return false;
	foreach (i, c : s)
	{
		char d = (c >= 'A' && c <= 'Z') ? c + 32 : c;
		char w = (word[i] >= 'A' && word[i] <= 'Z') ? word[i] + 32 : word[i];
		if (d != w) return false;
	}
	return true;
}

// ---- escaping what the PLC sends ----

// Length of the valid UTF-8 sequence at s[i] (0 when invalid). Overlong forms, surrogates, code points above U+10FFFF and
// the C1 controls U+0080..U+009F (a terminal acts on them) count as invalid.
fn usz utf8_sequence_len(String s, usz i)
{
	char c = s[i];
	if (c < 0x80) return 1;
	usz n;
	uint cp;
	uint min;
	if (c >= 0xC2 && c <= 0xDF)
	{
		n = 2;
		cp = c & 0x1F;
		min = 0x80;
	}
	else if ((c & 0xF0) == 0xE0)
	{
		n = 3;
		cp = c & 0x0F;
		min = 0x800;
	}
	else if (c >= 0xF0 && c <= 0xF4)
	{
		n = 4;
		cp = c & 0x07;
		min = 0x10000;
	}
	else
	{
		return 0;
	}
	if (i + n > s.len) return 0;
	for (usz k = 1; k < n; k++)
	{
		if ((s[i + k] & 0xC0) != 0x80) return 0;
		cp = (cp << 6) | (s[i + k] & 0x3F);
	}
	if (cp < min || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) return 0;
	if (cp >= 0x80 && cp <= 0x9F) return 0;
	return n;
}

const String HEX_DIGITS = "0123456789ABCDEF";

// Text from the PLC made safe for a terminal: bytes below 0x20 (ESC included), 0x7F, the C1 controls and bytes that are
// not valid UTF-8 are shown as \xNN; valid UTF-8 text passes unchanged. Release with alloc::free(allocator, result.ptr).
fn String escape_for_terminal(String s, Allocator allocator)
{
	if (s.len == 0) return "";
	usz cap = s.len * 4;
	char[] out = alloc::new_array(allocator, char, (sz)cap)[:cap];
	usz at = 0;
	usz i = 0;
	while (i < s.len)
	{
		char c = s[i];
		usz n = (c < 0x20 || c == 0x7F) ? 0 : utf8_sequence_len(s, i);
		if (n == 0)
		{
			out[at++] = '\\';
			out[at++] = 'x';
			out[at++] = HEX_DIGITS[c >> 4];
			out[at++] = HEX_DIGITS[c & 0x0F];
			i++;
			continue;
		}
		for (usz k = 0; k < n; k++) out[at++] = s[i + k];
		i += n;
	}
	return (String)out[:at];
}

// ---- options ----

fn Tsaps raw_tsaps(ushort local, ushort remote)
{
	Tsaps t;
	t.local = s7::tsap_from_u16(local);
	t.remote = s7::tsap_from_u16(remote);
	return t;
}

// The connection presets of --model. S7-200 and LOGO! use fixed TSAPs, the others rack and slot.
fn bool model_is_known(String name)
{
	String[6] names = { "s7-300", "s7-400", "s7-1200", "s7-1500", "s7-200", "logo" };
	foreach (n : names)
	{
		if (lower_equals(name, n)) return true;
	}
	return false;
}

// The TSAPs to connect with: an explicit --tsap wins, then a raw model, then rack and slot (explicit, else the model's
// default, else rack 0 slot 2) with the connection type.
fn Tsaps? tsaps_for(Options* o)
{
	if (o.has_tsap) return o.tsap;
	if (o.model.len > 0 && lower_equals(o.model, "s7-200")) return raw_tsaps(0x1000, 0x1001);
	if (o.model.len > 0 && lower_equals(o.model, "logo")) return raw_tsaps(0x0100, 0x0200);
	uint rack = o.rack;
	uint slot = o.slot;
	if (o.model.len > 0 && !o.slot_set && (lower_equals(o.model, "s7-1200") || lower_equals(o.model, "s7-1500"))) slot = 1;
	return s7::tsaps_from_rack_slot(o.conn, rack, slot);
}

fn void? usage(Options* o, String message)
{
	o.error = message;
	return USAGE~;
}

fn ConnType? conn_from_name(String s)
{
	if (lower_equals(s, "pg")) return PG;
	if (lower_equals(s, "op")) return OP;
	if (lower_equals(s, "basic")) return BASIC;
	return USAGE~;
}

fn ValueKind? kind_from_name(String s)
{
	String[18] names = {
		"BOOL", "BYTE", "WORD", "DWORD", "INT", "DINT", "REAL", "LREAL", "CHAR", "STRING", "WSTRING",
		"DATE", "TIME", "TOD", "DATE_AND_TIME", "DTL", "S5TIME", "COUNTER"
	};
	ValueKind[18] kinds = {
		BOOL, BYTE, WORD, DWORD, INT, DINT, REAL, LREAL, CHAR, STRING, WSTRING,
		DATE, TIME, TOD, DATE_AND_TIME, DTL, S5TIME, COUNTER_BCD
	};
	foreach (i, n : names)
	{
		if (lower_equals(s, n)) return kinds[i];
	}
	return USAGE~;
}

// "LOCAL:REMOTE", each a hex string of 1 to 16 bytes ("0100:0102").
fn Tsap? parse_tsap_hex(String s)
{
	if (s.len == 0 || s.len % 2 != 0 || s.len > 32) return USAGE~;
	char[16] raw;
	for (usz i = 0; i < s.len; i += 2)
	{
		raw[i / 2] = (char)(hex_value(s[i])!* 16 + hex_value(s[i + 1])!);
	}
	return s7::tsap_from_bytes(raw[:s.len / 2]);
}

fn void? parse_tsap_option(Options* o, String text)
{
	usz colon = text.len;
	foreach (i, c : text)
	{
		if (c == ':') colon = (usz)i;
	}
	if (colon >= text.len) return usage(o, "--tsap takes LOCAL:REMOTE as hex, for example 0100:0102");
	Tsap? local = parse_tsap_hex(text[:colon]);
	Tsap? remote = parse_tsap_hex(text[colon + 1..]);
	if (catch e1 = local) return usage(o, "--tsap takes LOCAL:REMOTE as hex, for example 0100:0102");
	if (catch e2 = remote) return usage(o, "--tsap takes LOCAL:REMOTE as hex, for example 0100:0102");
	o.tsap.local = local;
	o.tsap.remote = remote;
	o.has_tsap = true;
}

fn bool takes_value(String name)
{
	String[8] names = { "--host", "--port", "--rack", "--slot", "--conn", "--tsap", "--model", "--timeout" };
	foreach (n : names)
	{
		if (name == n) return true;
	}
	return name == "--type";
}

fn void? apply_option(Options* o, String name, String value)
{
	if (name == "--host")
	{
		o.host = value;
	}
	else if (name == "--port")
	{
		ulong? n = parse_number(value, 65535);
		if (catch e = n) return usage(o, "--port takes a number from 1 to 65535");
		if (n == 0) return usage(o, "--port takes a number from 1 to 65535");
		o.port = (int)n;
	}
	else if (name == "--rack")
	{
		ulong? n = parse_number(value, 7);
		if (catch e = n) return usage(o, "--rack takes a number from 0 to 7");
		o.rack = (uint)n;
		o.rack_set = true;
	}
	else if (name == "--slot")
	{
		ulong? n = parse_number(value, 31);
		if (catch e = n) return usage(o, "--slot takes a number from 0 to 31");
		o.slot = (uint)n;
		o.slot_set = true;
	}
	else if (name == "--conn")
	{
		ConnType? c = conn_from_name(value);
		if (catch e = c) return usage(o, "--conn is pg, op or basic");
		o.conn = c;
	}
	else if (name == "--tsap")
	{
		parse_tsap_option(o, value)!;
	}
	else if (name == "--model")
	{
		if (!model_is_known(value)) return usage(o, "--model is s7-300, s7-400, s7-1200, s7-1500, s7-200 or logo");
		o.model = value;
	}
	else if (name == "--timeout")
	{
		ulong? n = parse_number(value, 3600000);
		if (catch e = n) return usage(o, "--timeout takes milliseconds from 1 to 3600000");
		if (n == 0) return usage(o, "--timeout takes milliseconds from 1 to 3600000");
		o.timeout_ms = (long)n;
	}
	else if (name == "--type")
	{
		ValueKind? k = kind_from_name(value);
		if (catch e = k) return usage(o, "--type is BOOL, BYTE, WORD, DWORD, INT, DINT, REAL, LREAL, CHAR, STRING, WSTRING, DATE, TIME, TOD, DATE_AND_TIME, DTL, S5TIME or COUNTER");
		o.kind = k;
		o.has_type = true;
	}
}

// Parses `args` (args[0] is the program name). On a USAGE fault `o.error` says what is wrong.
fn void? parse_options(String[] args, Options* o)
{
	String[] positional;
	String[8] slots;
	usz n = 0;
	for (usz i = 1; i < args.len; i++)
	{
		String a = args[i];
		if (a == "--help" || a == "-h")
		{
			o.help = true;
		}
		else if (a == "--allow-write")
		{
			o.allow_write = true;
		}
		else if (a.len > 2 && a[0] == '-' && a[1] == '-')
		{
			if (!takes_value(a)) return usage(o, "unknown option");
			if (i + 1 >= args.len) return usage(o, "an option is missing its value");
			i++;
			apply_option(o, a, args[i])!;
		}
		else
		{
			if (n >= 8) return usage(o, "too many arguments");
			slots[n++] = a;
		}
	}
	if (o.help) return;
	if (n == 0) return usage(o, "no command given (info, read, write or dump)");
	String command = slots[0];
	usz expected;
	if (command == "info")
	{
		o.command = INFO;
		expected = 0;
	}
	else if (command == "read")
	{
		o.command = READ;
		expected = 1;
	}
	else if (command == "write")
	{
		o.command = WRITE;
		expected = 2;
	}
	else if (command == "dump")
	{
		o.command = DUMP;
		expected = 2;
	}
	else
	{
		return usage(o, "unknown command (info, read, write or dump)");
	}
	if (n != expected + 1) return usage(o, "wrong number of arguments for the command");
	if (expected >= 1) o.address = slots[1];
	if (o.command == WRITE) o.value = slots[2];
	if (o.command == DUMP)
	{
		ulong? len = parse_number(slots[2], 65535);
		if (catch e = len) return usage(o, "dump takes a length from 1 to 65535");
		if (len == 0) return usage(o, "dump takes a length from 1 to 65535");
		o.dump_len = (uint)len;
	}
	if (o.host.len == 0) return usage(o, "--host is required");
	if (o.command != WRITE && o.allow_write) return usage(o, "--allow-write only belongs to the write command");
}

// ---- the write guard ----

// The write command is refused before any connection is made unless --allow-write is given. Returns the exit code, 0 when
// the command may go on.
fn int write_guard(Options* o)
{
	if (o.command == WRITE && !o.allow_write) return EXIT_REFUSED;
	return EXIT_OK;
}

// ---- exit codes ----

// The exit code for a fault that ended a command: the local write guard is 2, a PLC answer that refuses or lacks the object is
// 4, everything about the connection and the protocol is 3, a bad argument is 1.
fn int exit_code_for(fault f)
{
	if (f == s7::WRITE_NOT_ALLOWED) return EXIT_REFUSED;
	if (f == USAGE || f == s7::INVALID_ADDRESS_TEXT || f == s7::ADDRESS_RANGE || f == s7::INVALID_ARGUMENT || f == s7::INVALID_VALUE) return EXIT_USAGE;
	if (f == s7::ACCESS_DENIED || f == s7::OBJECT_DOES_NOT_EXIST || f == s7::ADDRESS_OUT_OF_RANGE || f == s7::DATA_TYPE_UNSUPPORTED
		|| f == s7::TYPE_MISMATCH || f == s7::HARDWARE_FAULT || f == s7::UNKNOWN_RETURN_CODE || f == s7::NOT_SUPPORTED || f == s7::S7_ERROR)
	{
		return EXIT_PLC;
	}
	return EXIT_CONNECTION;
}

// The fault without its module prefix: "s7::OBJECT_DOES_NOT_EXIST".
fn String fault_name(fault f)
{
	String full = string::tformat("%s", f);
	usz start = 0;
	foreach (i, c : full)
	{
		if (c == ':') start = (usz)i + 1;
	}
	return full[start..];
}

fn String hint_for(fault f)
{
	if (f == s7::ACCESS_DENIED) return " (the PLC refused access: PUT/GET may be disabled, or the block is protected or uses optimized access)";
	if (f == s7::OBJECT_DOES_NOT_EXIST) return " (the area or data block does not exist in the PLC)";
	if (f == s7::ADDRESS_OUT_OF_RANGE) return " (the address lies outside the area)";
	if (f == s7::WRITE_NOT_ALLOWED) return " (pass --allow-write to write)";
	return "";
}

// ---- output ----

// "12 34 0A": the bytes as hex.
fn String hex_bytes(char[] data, Allocator allocator)
{
	if (data.len == 0) return "";
	usz cap = data.len * 3;
	char[] out = alloc::new_array(allocator, char, (sz)cap)[:cap];
	usz at = 0;
	foreach (i, b : data)
	{
		if (i > 0) out[at++] = ' ';
		out[at++] = HEX_DIGITS[b >> 4];
		out[at++] = HEX_DIGITS[b & 0x0F];
	}
	return (String)out[:at];
}

// A 16 column dump: offset, hex bytes, printable ASCII (everything else is a dot). `start` is the offset of the first byte.
fn String format_dump(char[] data, usz start, Allocator allocator)
{
	usz lines = (data.len + 15) / 16;
	if (lines == 0) return "";
	usz cap = lines * 80;
	char[] out = alloc::new_array(allocator, char, (sz)cap)[:cap];
	usz at = 0;
	for (usz line = 0; line < lines; line++)
	{
		usz base = line * 16;
		usz offset = start + base;
		for (int shift = 12; shift >= 0; shift -= 4) out[at++] = HEX_DIGITS[(offset >> shift) & 0xF];
		out[at++] = ' ';
		out[at++] = ' ';
		for (usz k = 0; k < 16; k++)
		{
			if (k > 0) out[at++] = ' ';
			if (base + k < data.len)
			{
				out[at++] = HEX_DIGITS[data[base + k] >> 4];
				out[at++] = HEX_DIGITS[data[base + k] & 0x0F];
			}
			else
			{
				out[at++] = ' ';
				out[at++] = ' ';
			}
		}
		out[at++] = ' ';
		out[at++] = ' ';
		out[at++] = '|';
		for (usz k = 0; k < 16 && base + k < data.len; k++)
		{
			char c = data[base + k];
			out[at++] = (c >= 0x20 && c < 0x7F) ? c : '.';
		}
		out[at++] = '|';
		out[at++] = '\n';
	}
	return (String)out[:at];
}

// days since 1990-01-01 as "YYYY-MM-DD"
fn String format_date(ulong days)
{
	uint year = 1990;
	ulong left = days;
	while (true)
	{
		ulong in_year = s7::is_leap(year) ? 366 : 365;
		if (left < in_year) break;
		left -= in_year;
		year++;
	}
	uint month = 1;
	while (left >= s7::days_in_month(year, month))
	{
		left -= s7::days_in_month(year, month);
		month++;
	}
	return string::tformat("%04d-%02d-%02d", year, month, (uint)left + 1);
}

fn String format_dtl(Dtl* d)
{
	return string::tformat("%04d-%02d-%02d %02d:%02d:%02d.%09d", (uint)d.year, (uint)d.month, (uint)d.day, (uint)d.hour, (uint)d.minute, (uint)d.second, d.nanosecond);
}

// A decoded value as text. Strings go through escape_for_terminal; the result is a temporary string.
fn String format_value(Value* v)
{
	switch (v.kind)
	{
		case BOOL:
			return v.b ? "true" : "false";
		case BYTE:
		case WORD:
		case DWORD:
		case COUNTER_BCD:
			return string::tformat("%d", v.u);
		case INT:
		case DINT:
			return string::tformat("%d", v.i);
		case TIME:
			return string::tformat("%d ms", v.i);
		case S5TIME:
			return string::tformat("%d ms", v.u);
		case REAL:
		case LREAL:
			return string::tformat("%g", v.f);
		case DATE:
			return format_date(v.u);
		case TOD:
			return string::tformat("%02d:%02d:%02d.%03d", v.u / 3600000, (v.u / 60000) % 60, (v.u / 1000) % 60, v.u % 1000);
		case DATE_AND_TIME:
		case DTL:
			return format_dtl(&v.dtl);
		default:
			return escape_for_terminal(v.str, tmem);
	}
}

fn void print_help()
{
	io::printn("s7tool: read and write a Siemens S7 PLC (classic S7comm)");
	io::printn("");
	io::printn("usage: s7tool [options] <command>");
	io::printn("");
	io::printn("commands:");
	io::printn("  info                          module, state, clock and negotiated PDU size");
	io::printn("  read ADDRESS [--type T]       read an address (hex bytes without --type)");
	io::printn("  write ADDRESS VALUE --type T  write a value; refused unless --allow-write is given");
	io::printn("  dump ADDRESS LENGTH           hex dump of LENGTH bytes");
	io::printn("");
	io::printn("options:");
	io::printn("  --host HOST          PLC address (required)");
	io::printn("  --port PORT          TCP port, default 102");
	io::printn("  --rack N --slot N    rack 0..7 and slot 0..31, default 0 and 2");
	io::printn("  --conn pg|op|basic   connection type, default pg");
	io::printn("  --tsap LOCAL:REMOTE  raw TSAPs in hex (S7-200, LOGO!), for example 1000:1001");
	io::printn("  --model M            s7-300, s7-400, s7-1200, s7-1500, s7-200 or logo (sets rack, slot or TSAPs)");
	io::printn("  --timeout MS         connect and response timeout in milliseconds, default 5000");
	io::printn("  --type T             BOOL BYTE WORD DWORD INT DINT REAL LREAL CHAR STRING WSTRING DATE TIME TOD DATE_AND_TIME DTL S5TIME COUNTER");
	io::printn("  --allow-write        let the write command write");
	io::printn("  --help               this text");
	io::printn("");
	io::printn("addresses: DB1.DBX0.3 DB1.DBW2 DB10.DBB0[16] MW20 I0.1 QB4 PIW4 T5 C3");
	io::printn("exit codes: 0 ok, 1 usage, 2 write refused, 3 connection or protocol failure, 4 the PLC refused");
}

// ---- the commands ----

// The bytes to write for VALUE: parsed as `kind` when --type is given, otherwise a hex string with the size of the address.
fn char[]? payload_for_write(Options* o, Address* a, Allocator allocator)
{
	usz size = a.payload_bytes();
	char[] out = alloc::new_array(allocator, char, (sz)size)[:size];
	if (!o.has_type)
	{
		String v = o.value;
		if (v.len != size * 2)
		{
			alloc::free(allocator, out.ptr);
			return USAGE~;
		}
		for (usz i = 0; i < size; i++)
		{
			int? hi = hex_value(v[i * 2]);
			int? lo = hex_value(v[i * 2 + 1]);
			if (catch e1 = hi)
			{
				alloc::free(allocator, out.ptr);
				return USAGE~;
			}
			if (catch e2 = lo)
			{
				alloc::free(allocator, out.ptr);
				return USAGE~;
			}
			out[i] = (char)(hi * 16 + lo);
		}
		return out;
	}
	Value? v = s7::parse_value(o.kind, o.value, allocator);
	if (catch e = v)
	{
		alloc::free(allocator, out.ptr);
		return s7::INVALID_VALUE~;
	}
	uint max_len = 254;
	if (o.kind == STRING && size >= 2) max_len = (uint)size - 2;
	if (o.kind == WSTRING && size >= 4) max_len = ((uint)size - 4) / 2;
	usz? n = s7::encode_value(&v, out, max_len);
	v.free(allocator);
	if (catch e = n)
	{
		alloc::free(allocator, out.ptr);
		return e~;
	}
	if (n != size)
	{
		alloc::free(allocator, out.ptr);
		return s7::INVALID_ARGUMENT~;
	}
	return out;
}

fn int fail(fault f)
{
	String hint = hint_for(f);
	io::eprintfn("s7tool: %s%s", fault_name(f), hint);
	return exit_code_for(f);
}

fn int cmd_info(Client* c)
{
	io::printfn("PDU size: %d", (int)c.pdu_size());
	CpuInfo? info = c.cpu_info(mem);
	if (try i = info)
	{
		io::printfn("Module: %s", escape_for_terminal(i.module_name, tmem));
		io::printfn("Plant: %s", escape_for_terminal(i.plant_id, tmem));
		io::printfn("Serial: %s", escape_for_terminal(i.serial, tmem));
		io::printfn("Type: %s", escape_for_terminal(i.module_type_name, tmem));
		i.free(mem);
	}
	else
	{
		io::printfn("Module: unavailable (%s)", fault_name(@catch(info)));
	}
	CpuState? state = c.cpu_state();
	if (try s = state)
	{
		io::printfn("State: %s", s == RUN ? "RUN" : (s == STOP ? "STOP" : (s == STARTUP ? "STARTUP" : "unknown")));
	}
	else
	{
		io::printfn("State: unavailable (%s)", fault_name(@catch(state)));
	}
	Dtl? clock = c.read_clock();
	if (try t = clock)
	{
		io::printfn("Clock: %s", format_dtl(&t));
	}
	else
	{
		io::printfn("Clock: unavailable (%s)", fault_name(@catch(clock)));
	}
	return EXIT_OK;
}

fn int cmd_read(Client* c, Options* o, Address* a)
{
	char[]? data = c.read_bytes(*a, mem);
	if (catch err = data) return fail(err);
	defer alloc::free(mem, data.ptr);
	if (!o.has_type)
	{
		io::printn(hex_bytes(data, tmem));
		return EXIT_OK;
	}
	Value? v = s7::decode_value(o.kind, data, mem);
	if (catch err = v)
	{
		io::eprintfn("s7tool: the address covers %d bytes, which does not fit the type", (int)data.len);
		return EXIT_USAGE;
	}
	io::printn(format_value(&v));
	v.free(mem);
	return EXIT_OK;
}

fn int cmd_dump(Client* c, Options* o, Address* a)
{
	char[]? data = c.read_bytes(*a, mem);
	if (catch err = data) return fail(err);
	defer alloc::free(mem, data.ptr);
	io::printf("%s", format_dump(data, a.byte_off, tmem));
	return EXIT_OK;
}

fn int cmd_write(Client* c, Address* a, char[] payload)
{
	if (catch err = c.write_bytes(*a, payload)) return fail(err);
	io::printn("written");
	return EXIT_OK;
}

// What a command needs from its address, checked before any connection is made.
fn int prepare(Options* o, Address* a, char[]* payload)
{
	if (o.command == INFO) return EXIT_OK;
	Address? parsed = s7::parse_address(o.address);
	if (catch err = parsed)
	{
		io::eprintfn("s7tool: %s is not an address (%s)", escape_for_terminal(o.address, tmem), fault_name(err));
		return EXIT_USAGE;
	}
	*a = parsed;
	if (o.command == DUMP)
	{
		if (a.tsize == BIT)
		{
			io::eprintn("s7tool: dump needs a byte address, not a bit");
			return EXIT_USAGE;
		}
		a.tsize = BYTE;
		a.count = o.dump_len;
	}
	if (o.command == READ && o.has_type && o.kind.wire_size() != 0 && a.payload_bytes() != o.kind.wire_size())
	{
		io::eprintfn("s7tool: the address covers %d bytes but the type needs %d", (int)a.payload_bytes(), (int)o.kind.wire_size());
		return EXIT_USAGE;
	}
	if (o.command == WRITE)
	{
		if (o.has_type && o.kind.wire_size() != 0 && a.payload_bytes() != o.kind.wire_size())
		{
			io::eprintfn("s7tool: the address covers %d bytes but the type needs %d", (int)a.payload_bytes(), (int)o.kind.wire_size());
			return EXIT_USAGE;
		}
		char[]? data = payload_for_write(o, a, mem);
		if (catch err = data)
		{
			io::eprintn("s7tool: the value does not fit the address and type");
			return EXIT_USAGE;
		}
		*payload = data;
	}
	return EXIT_OK;
}

fn int run(String[] args)
{
	Options o = default_options();
	if (catch err = parse_options(args, &o))
	{
		io::eprintfn("s7tool: %s (try --help)", o.error);
		return EXIT_USAGE;
	}
	if (o.help)
	{
		print_help();
		return EXIT_OK;
	}
	if (write_guard(&o) != EXIT_OK)
	{
		io::eprintn("s7tool: write refused: pass --allow-write to let s7tool write to the PLC");
		return EXIT_REFUSED;
	}
	Address address;
	char[] payload;
	int prepared = prepare(&o, &address, &payload);
	if (prepared != EXIT_OK) return prepared;
	defer if (payload.len > 0) alloc::free(mem, payload.ptr);

	Tsaps? tsaps = tsaps_for(&o);
	if (catch err = tsaps)
	{
		io::eprintn("s7tool: rack 0..7 and slot 0..31 are required");
		return EXIT_USAGE;
	}
	SessionConfig cfg = s7::default_config(tsaps);
	cfg.allow_write = o.allow_write;
	cfg.response_timeout = time::ms(o.timeout_ms);
	cfg.connect_timeout = time::ms(o.timeout_ms);
	TcpTransport? tcp = s7::tcp_connect(o.host, o.port, time::ms(o.timeout_ms));
	if (catch err = tcp)
	{
		io::eprintfn("s7tool: cannot connect to %s:%d (%s)", escape_for_terminal(o.host, tmem), o.port, fault_name(err));
		return EXIT_CONNECTION;
	}
	Client client;
	if (catch err = client.open(&tcp, cfg, mem))
	{
		io::eprintfn("s7tool: the PLC did not accept the connection (%s)", fault_name(err));
		if (catch closing = tcp.close()) {}
		return EXIT_CONNECTION;
	}
	int code;
	switch (o.command)
	{
		case INFO:
			code = cmd_info(&client);
		case READ:
			code = cmd_read(&client, &o, &address);
		case DUMP:
			code = cmd_dump(&client, &o, &address);
		case WRITE:
			code = cmd_write(&client, &address, payload);
		default:
			code = EXIT_USAGE;
	}
	client.close();
	return code;
}
