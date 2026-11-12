# s7.c3l

Siemens S7comm client library for [C3](http://c3-lang.org) (work in progress).

Scope: TPKT/COTP framing, S7 Setup Communication, Read/Write Var, SZL and clock reads, address parser and
S7 value types. Sans-IO core with a blocking TCP adapter. Writes to a PLC are refused unless explicitly
allowed.

Requires c3c v0.8.6 or newer. Licence: MIT.
