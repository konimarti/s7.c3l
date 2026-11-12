module s7;

// Hex fixtures for the address tests: full Read Var request frames (V* are the IDs of the independent
// test vector set, derived by hand). The S7ANY items start at frame offset 19.

const String FX_V20 = "03 00 00 1F 02 F0 80 32 01 00 00 00 02 00 0E 00 00 04 01 12 0A 10 02 00 02 00 01 84 00 00 10";
const String FX_V22 = "03 00 00 1F 02 F0 80 32 01 00 00 00 03 00 0E 00 00 04 01 12 0A 10 01 00 01 00 01 84 00 00 03";
const String FX_V24 = "03 00 00 1F 02 F0 80 32 01 00 00 00 04 00 0E 00 00 04 01 12 0A 10 02 00 04 00 00 83 00 00 A0";
const String FX_V26 = "03 00 00 1F 02 F0 80 32 01 00 00 00 05 00 0E 00 00 04 01 12 0A 10 1D 00 01 00 00 1D 00 00 05";
const String FX_V28 = "03 00 00 1F 02 F0 80 32 01 00 00 00 06 00 0E 00 00 04 01 12 0A 10 1C 00 01 00 00 1C 00 00 03";
const String FX_V29 = "03 00 00 2B 02 F0 80 32 01 00 00 00 07 00 1A 00 00 04 02 12 0A 10 02 00 03 00 01 84 00 00 00 12 0A 10 02 00 02 00 01 84 00 00 50";
