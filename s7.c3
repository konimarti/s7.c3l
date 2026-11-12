module s7;

// ---- Error model (DESIGN.md section 6). One flat fault list, grouped by layer. ----

// Framing / protocol violations by the peer (malformed or unexpected bytes).
faultdef
	TRUNCATED,            // frame or field shorter than its own length says
	BAD_TPKT,             // version != 3, reserved != 0, length < 7
	BAD_COTP,             // unknown TPDU code, bad length indicator, bad parameter
	FRAME_TOO_LARGE,      // TPKT length above Limits.max_frame
	BAD_S7_HEADER,        // protocol id != 0x32, lengths do not add up
	UNEXPECTED_PDU,       // valid PDU, wrong for the current state
	PDU_REF_MISMATCH,     // response does not match the outstanding job
	BAD_RESPONSE,         // response body inconsistent with the request
	NEGOTIATION_FAILED,   // setup communication refused or PDU size below minimum
	CONNECT_REFUSED,      // COTP Disconnect Request / Error TPDU in place of Connect Confirm
	UNSUPPORTED_PROTOCOL, // S7 protocol id 0x72 (S7comm-plus) or other non-0x32 id
	NOT_SUPPORTED;        // peer says the function/SZL is not available (param error / rc 0x0A on SZL)

// Local usage errors.
faultdef
	NOT_CONNECTED,
	BUSY,                 // a job is already in flight (v1: one outstanding job)
	NO_EVENT,             // Session.next_event() with an empty queue
	INVALID_ADDRESS_TEXT, // address parser: syntax
	ADDRESS_RANGE,        // address parser: number out of range
	INVALID_ARGUMENT,     // zero count, empty request, value too large for the item
	BUFFER_TOO_SMALL,
	TIMEOUT,              // deadline expired (time is passed in)
	CLOSED;               // transport reports end of stream

// Peer-reported errors: S7 header error class/code (ack with error) and data item return codes.
// An Ack/Ack_Data with class/code != 0 -> S7_ERROR; with 0/0 where data was expected -> BAD_RESPONSE.
faultdef
	S7_ERROR,             // header error class/code != 0 (details in Session.err_class/err_code)
	HARDWARE_FAULT,       // item return code 0x01
	WRITE_NOT_ALLOWED,    // local guard: submit_write/Client.write while SessionConfig.allow_write is false
	ACCESS_DENIED,        // 0x03 (also PUT/GET disabled, protected block, no optimized access)
	ADDRESS_OUT_OF_RANGE, // 0x05 invalid address / outside the object
	DATA_TYPE_UNSUPPORTED, // 0x06
	TYPE_MISMATCH,        // 0x07 data type inconsistent (length vs transport size)
	OBJECT_DOES_NOT_EXIST, // 0x0A (e.g. DB missing)
	UNKNOWN_RETURN_CODE;

// Value codec.
faultdef
	INVALID_VALUE,        // BCD digit > 9, date out of range, string length > max
	VALUE_TOO_SHORT;

struct Limits
{
	ushort min_pdu;       // refuse negotiation below this (default 240? see DESIGN 5.3)
	ushort max_pdu;       // our offer (default 960)
	ushort max_items;     // items per Read/Write PDU (default 20); values above 20 are capped to 20 by the planner
	uint   max_frame;     // reject TPKT length above this (default 8192)
	uint   max_request_bytes; // cap on one logical request (default 1 MiB)
	ushort max_szl_fragments; // continuation requests per SZL read (default 64)
}

const Limits DEFAULT_LIMITS = { 240, 960, 20, 8192, 1 << 20, 64 };
