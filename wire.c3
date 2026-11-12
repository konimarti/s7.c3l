module s7;

// Pure codec functions on byte slices: TPKT (RFC 1006 section 6), COTP class 0 (X.224 clause 13)
// and the S7 header with Setup Communication. No I/O, no allocation, no clock.

fn ushort? get_be16(char[] b, usz off)
{
	if (b.len < 2 || off > b.len - 2) return TRUNCATED~;
	return (ushort)(((uint)b[off] << 8) | (uint)b[off + 1]);
}

fn uint? get_be32(char[] b, usz off)
{
	if (b.len < 4 || off > b.len - 4) return TRUNCATED~;
	return ((uint)b[off] << 24) | ((uint)b[off + 1] << 16) | ((uint)b[off + 2] << 8) | (uint)b[off + 3];
}

fn void? put_be16(char[] b, usz off, ushort v)
{
	if (b.len < 2 || off > b.len - 2) return BUFFER_TOO_SMALL~;
	b[off] = (char)(v >> 8);
	b[off + 1] = (char)v;
}

fn void? put_be32(char[] b, usz off, uint v)
{
	if (b.len < 4 || off > b.len - 4) return BUFFER_TOO_SMALL~;
	b[off] = (char)(v >> 24);
	b[off + 1] = (char)(v >> 16);
	b[off + 2] = (char)(v >> 8);
	b[off + 3] = (char)v;
}

// ---- TSAPs ----

enum ConnType : char (char code)
{
	PG    { 0x01 },
	OP    { 0x02 },
	BASIC { 0x03 },
}

const usz MAX_TSAP_LEN = 16;

// A TSAP is 1..16 bytes on the wire; S7 PLCs use 2.
struct Tsap
{
	char[MAX_TSAP_LEN] bytes;
	char len;
}

struct Tsaps
{
	Tsap local;
	Tsap remote;
}

fn Tsap tsap_from_u16(ushort v)
{
	Tsap t;
	t.bytes[0] = (char)(v >> 8);
	t.bytes[1] = (char)v;
	t.len = 2;
	return t;
}

fn Tsap? tsap_from_bytes(char[] raw)
{
	if (raw.len == 0 || raw.len > MAX_TSAP_LEN) return INVALID_ARGUMENT~;
	Tsap t;
	t.len = (char)raw.len;
	t.bytes[:raw.len] = raw[..];
	return t;
}

// Local TSAP 0x0100; remote TSAP (type << 8) | (rack * 32 + slot). rack > 7 or slot > 31: INVALID_ARGUMENT.
fn Tsaps? tsaps_from_rack_slot(ConnType type, uint rack, uint slot)
{
	if (rack > 7 || slot > 31) return INVALID_ARGUMENT~;
	Tsaps t;
	t.local = tsap_from_u16(0x0100);
	t.remote = tsap_from_u16((ushort)(((uint)type.code << 8) | (rack * 32 + slot)));
	return t;
}

// ---- TPKT and COTP ----

const usz TPKT_HEADER_LEN = 4;
const usz DT_HEADER_LEN = 7;   // TPKT (4) + COTP DT (3)

enum CotpKind : char { CR, CC, DR, ER, DT }

struct CotpPdu
{
	CotpKind kind;
	ushort dst_ref;            // CR, CC, DR, ER
	ushort src_ref;            // CR, CC, DR
	char reason;               // DR reason, ER cause
	char tpdu_size;            // CR/CC TPDU size exponent from parameter 0xC0, 0 when absent
	bool has_local_tsap;       // parameter 0xC1 present
	bool has_remote_tsap;      // parameter 0xC2 present
	Tsaps tsaps;
	char[] payload;            // DT: the S7 PDU, a slice of the frame (not owned)
}

// The first 4 bytes of a frame -> total packet length (7 <= length <= max_frame).
// A reserved byte other than 0 is BAD_TPKT only when `strict_reserved`.
fn usz? decode_tpkt_header(char[] header, uint max_frame, bool strict_reserved)
{
	if (header.len < TPKT_HEADER_LEN) return TRUNCATED~;
	if (header[0] != 3) return BAD_TPKT~;
	if (strict_reserved && header[1] != 0) return BAD_TPKT~;
	usz length = (usz)get_be16(header, 2)!;
	if (length < DT_HEADER_LEN) return BAD_TPKT~;
	if (length > max_frame) return FRAME_TOO_LARGE~;
	return length;
}

// A whole frame (TPKT included, exactly as long as its length field says) -> COTP PDU.
// Class 0 only; parameter TLVs must fit the TPDU, unknown ones are skipped; a DT must carry EOT.
// The CC's DST-REF is not judged here (session policy).
fn CotpPdu? decode_cotp(char[] frame)
{
	if (frame.len < TPKT_HEADER_LEN) return TRUNCATED~;
	if (frame[0] != 3) return BAD_TPKT~;
	usz total = (usz)get_be16(frame, 2)!;
	if (total < DT_HEADER_LEN) return BAD_TPKT~;
	if (total > frame.len) return TRUNCATED~;
	if (total < frame.len) return BAD_TPKT~;

	usz li = frame[4];
	if (li == 0 || li == 255 || 5 + li > total) return BAD_COTP~;
	char code = frame[5];
	CotpPdu pdu;
	usz end = 5 + li;   // one past the last byte of the TPDU header

	switch (code & 0xF0)
	{
		case 0xF0:
			if ((code & 0x0F) != 0 || li != 2) return BAD_COTP~;
			if ((frame[6] & 0x80) == 0) return UNEXPECTED_PDU~;
			pdu.kind = DT;
			pdu.payload = frame[DT_HEADER_LEN..];
			return pdu;
		case 0xE0:
			pdu.kind = CR;
		case 0xD0:
			pdu.kind = CC;
		case 0x80:
			if ((code & 0x0F) != 0 || li < 6) return BAD_COTP~;
			pdu.kind = DR;
			pdu.dst_ref = get_be16(frame, 6)!;
			pdu.src_ref = get_be16(frame, 8)!;
			pdu.reason = frame[10];
			return pdu;
		case 0x70:
			if ((code & 0x0F) != 0 || li < 4) return BAD_COTP~;
			pdu.kind = ER;
			pdu.dst_ref = get_be16(frame, 6)!;
			pdu.reason = frame[8];
			return pdu;
		default:
			return BAD_COTP~;
	}

	// CR and CC: dst-ref(2) src-ref(2) class(1) {parameter}
	if (li < 6) return BAD_COTP~;
	pdu.dst_ref = get_be16(frame, 6)!;
	pdu.src_ref = get_be16(frame, 8)!;
	if ((frame[10] & 0xF0) != 0) return BAD_COTP~;   // only class 0
	usz pos = 11;
	while (pos < end)
	{
		if (pos + 2 > end) return BAD_COTP~;
		char pcode = frame[pos];
		usz plen = frame[pos + 1];
		pos += 2;
		if (pos + plen > end) return BAD_COTP~;
		switch (pcode)
		{
			case 0xC0:
				if (plen == 1) pdu.tpdu_size = frame[pos];
			case 0xC1:
				if (plen == 0 || plen > MAX_TSAP_LEN) return BAD_COTP~;
				pdu.tsaps.local.len = (char)plen;
				pdu.tsaps.local.bytes[:plen] = frame[pos:plen];
				pdu.has_local_tsap = true;
			case 0xC2:
				if (plen == 0 || plen > MAX_TSAP_LEN) return BAD_COTP~;
				pdu.tsaps.remote.len = (char)plen;
				pdu.tsaps.remote.bytes[:plen] = frame[pos:plen];
				pdu.has_remote_tsap = true;
			default:
				break;
		}
		pos += plen;
	}
	return pdu;
}

// Connection Request including TPKT. Parameters: TPDU size 1024 (0xC0), calling and called TSAP.
fn usz? encode_cr(Tsaps tsaps, ushort src_ref, char[] out)
{
	usz l = tsaps.local.len;
	usz r = tsaps.remote.len;
	if (l == 0 || l > MAX_TSAP_LEN || r == 0 || r > MAX_TSAP_LEN) return INVALID_ARGUMENT~;
	usz total = 11 + 3 + (2 + l) + (2 + r);
	if (out.len < total) return BUFFER_TOO_SMALL~;
	out[0] = 3;
	out[1] = 0;
	put_be16(out, 2, (ushort)total)!;
	out[4] = (char)(total - 5);
	out[5] = 0xE0;
	put_be16(out, 6, 0)!;
	put_be16(out, 8, src_ref)!;
	out[10] = 0;
	out[11] = 0xC0;
	out[12] = 1;
	out[13] = 0x0A;
	out[14] = 0xC1;
	out[15] = (char)l;
	out[16:l] = tsaps.local.bytes[:l];
	usz pos = 16 + l;
	out[pos] = 0xC2;
	out[pos + 1] = (char)r;
	out[pos + 2:r] = tsaps.remote.bytes[:r];
	return total;
}

// Disconnect Request including TPKT (reason 0x80: normal disconnect, X.224 13.5, verify).
fn usz? encode_dr(ushort dst_ref, ushort src_ref, char[] out)
{
	if (out.len < 11) return BUFFER_TOO_SMALL~;
	out[0] = 3;
	out[1] = 0;
	put_be16(out, 2, 11)!;
	out[4] = 6;
	out[5] = 0x80;
	put_be16(out, 6, dst_ref)!;
	put_be16(out, 8, src_ref)!;
	out[10] = 0x80;
	return 11;
}

// Writes TPKT + DT (03 00 LL LL 02 F0 80) at out[0..7]. The S7 PDU of `s7_len` bytes is already at out[7..].
// Returns the total frame length.
fn usz? encode_dt_header(char[] out, usz s7_len)
{
	if (s7_len > 0xFFFF - DT_HEADER_LEN) return INVALID_ARGUMENT~;
	usz total = DT_HEADER_LEN + s7_len;
	if (out.len < total) return BUFFER_TOO_SMALL~;
	out[0] = 3;
	out[1] = 0;
	put_be16(out, 2, (ushort)total)!;
	out[4] = 2;
	out[5] = 0xF0;
	out[6] = 0x80;
	return total;
}

// ---- S7 header ----

enum Rosctr : char (char code)
{
	JOB      { 1 },
	ACK      { 2 },
	ACK_DATA { 3 },
	USERDATA { 7 },
}

struct S7Header
{
	Rosctr rosctr;
	ushort pdu_ref;
	char err_class;            // ACK and ACK_DATA only
	char err_code;
	char[] param;              // slices of the payload
	char[] data;
}

// `payload` is the DT payload. Protocol id 0x72 (S7comm-plus): UNSUPPORTED_PROTOCOL; another id, an unknown
// ROSCTR or lengths that do not add up exactly: BAD_S7_HEADER; a payload shorter than the header: TRUNCATED.
fn S7Header? decode_s7_header(char[] payload)
{
	if (payload.len == 0) return TRUNCATED~;
	if (payload[0] == 0x72) return UNSUPPORTED_PROTOCOL~;
	if (payload[0] != 0x32) return BAD_S7_HEADER~;
	if (payload.len < 10) return TRUNCATED~;

	S7Header h;
	switch (payload[1])
	{
		case 1:
			h.rosctr = JOB;
		case 2:
			h.rosctr = ACK;
		case 3:
			h.rosctr = ACK_DATA;
		case 7:
			h.rosctr = USERDATA;
		default:
			return BAD_S7_HEADER~;
	}
	usz header_len = (h.rosctr == ACK || h.rosctr == ACK_DATA) ? 12 : 10;
	if (payload.len < header_len) return TRUNCATED~;

	h.pdu_ref = get_be16(payload, 4)!;
	usz param_len = (usz)get_be16(payload, 6)!;
	usz data_len = (usz)get_be16(payload, 8)!;
	if (header_len + param_len + data_len != payload.len) return BAD_S7_HEADER~;
	if (header_len == 12)
	{
		h.err_class = payload[10];
		h.err_code = payload[11];
	}
	h.param = payload[header_len:param_len];
	h.data = payload[header_len + param_len:data_len];
	return h;
}

// Setup Communication request including TPKT/DT: amq 1/1 and the offered PDU size. Returns 25.
fn usz? encode_setup_request(ushort pdu_ref, ushort pdu, char[] out)
{
	if (out.len < 25) return BUFFER_TOO_SMALL~;
	out[7] = 0x32;
	out[8] = 0x01;
	put_be16(out, 9, 0)!;
	put_be16(out, 11, pdu_ref)!;
	put_be16(out, 13, 8)!;
	put_be16(out, 15, 0)!;
	out[17] = 0xF0;
	out[18] = 0;
	put_be16(out, 19, 1)!;
	put_be16(out, 21, 1)!;
	put_be16(out, 23, pdu)!;
	return encode_dt_header(out, 18);
}

struct SetupParams
{
	ushort amq_calling;
	ushort amq_called;
	ushort pdu;
}

// Setup Communication response (ROSCTR 3). A header error class/code: S7_ERROR (no parameters to trust);
// wrong ROSCTR, function code or parameter length: BAD_RESPONSE. An amq of 0 is clamped to 1. The PDU range
// policy (zero, minimum, clamping to our offer) belongs to the session.
fn SetupParams? decode_setup_response(S7Header* header)
{
	if (header == null) return INVALID_ARGUMENT~;
	if (header.rosctr != ACK_DATA) return BAD_RESPONSE~;
	if (header.err_class != 0 || header.err_code != 0) return S7_ERROR~;
	if (header.param.len < 8) return BAD_RESPONSE~;
	if (header.param[0] != 0xF0) return BAD_RESPONSE~;
	SetupParams p;
	p.amq_calling = get_be16(header.param, 2)!;
	p.amq_called = get_be16(header.param, 4)!;
	p.pdu = get_be16(header.param, 6)!;
	if (p.amq_calling == 0) p.amq_calling = 1;
	if (p.amq_called == 0) p.amq_called = 1;
	return p;
}
