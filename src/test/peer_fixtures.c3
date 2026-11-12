module s7;

// Frames captured from the python-snap7 server on 2026-11-12 (scripts/run_peer.py, peercheck --capture): one connection with
// a read, a write of 0x1234, a read, the restoring write, a read and the disconnect. W are the frames the client sent,
// R the answers. The client offered a PDU size of 960; the peer answered 480.

const String FXP_W0 = "03 00 00 16 11 E0 00 00 00 01 00 C0 01 0A C1 02 01 00 C2 02 01 02";
const String FXP_R0 = "03 00 00 16 11 D0 00 01 00 01 00 C0 01 0A C1 02 01 00 C2 02 01 02";
const String FXP_W1 = "03 00 00 19 02 F0 80 32 01 00 00 00 01 00 08 00 00 F0 00 00 01 00 01 03 C0";
const String FXP_R1 = "03 00 00 1B 02 F0 80 32 03 00 00 00 01 00 08 00 00 00 00 F0 00 00 01 00 01 01 E0";
const String FXP_W2 = "03 00 00 1F 02 F0 80 32 01 00 00 00 02 00 0E 00 00 04 01 12 0A 10 02 00 02 00 01 84 00 00 10";
const String FXP_R2 = "03 00 00 1B 02 F0 80 32 03 00 00 00 02 00 02 00 06 00 00 04 01 FF 04 00 10 02 03";
const String FXP_W3 = "03 00 00 25 02 F0 80 32 01 00 00 00 03 00 0E 00 06 05 01 12 0A 10 02 00 02 00 01 84 00 00 10 00 04 00 10 12 34";
const String FXP_R3 = "03 00 00 16 02 F0 80 32 03 00 00 00 03 00 02 00 01 00 00 05 01 FF";
const String FXP_W4 = "03 00 00 1F 02 F0 80 32 01 00 00 00 04 00 0E 00 00 04 01 12 0A 10 02 00 02 00 01 84 00 00 10";
const String FXP_R4 = "03 00 00 1B 02 F0 80 32 03 00 00 00 04 00 02 00 06 00 00 04 01 FF 04 00 10 12 34";
const String FXP_W5 = "03 00 00 25 02 F0 80 32 01 00 00 00 05 00 0E 00 06 05 01 12 0A 10 02 00 02 00 01 84 00 00 10 00 04 00 10 02 03";
const String FXP_R5 = "03 00 00 16 02 F0 80 32 03 00 00 00 05 00 02 00 01 00 00 05 01 FF";
const String FXP_W6 = "03 00 00 1F 02 F0 80 32 01 00 00 00 06 00 0E 00 00 04 01 12 0A 10 02 00 02 00 01 84 00 00 10";
const String FXP_R6 = "03 00 00 1B 02 F0 80 32 03 00 00 00 06 00 02 00 06 00 00 04 01 FF 04 00 10 02 03";
const String FXP_W7 = "03 00 00 0B 06 80 00 01 00 01 80";
