Here are the findings — existing code that's compiled into the firmware but never actually called from anywhere:

## Orphaned Code Survey

### Most significant (complete, working, but zero callers)

| # | Module | File(s) | What it does | Notes |
|---|--------|---------|-------------|-------|
| 1 | **KeeloqCipher** | `firmware/src/modules/protopirate/protocols/KeeloqCipher.h` | Full 528-round KeeLoq block cipher (encrypt/decrypt) | Never `#include`d by any file; not listed in `PPAllProtocols.h` |
| 2 | **FlipperSubFile** | `firmware/lib/generators/FlipperSubFile.h/.cpp` | `.sub` file generator (`generateRaw()`, `writeHeader()`, etc.) | Compiled but superseded by inline `.sub` writing in `SubGhzCaptureManager::onSignalDecoded()` |
| 3 | **StreamingSubFileParser** | `firmware/src/modules/subghz_function/StreamingSubFileParser.h/.cpp` | RAM-optimized two-pass `.sub` file parser | `#include`d by `CC1101_Worker.cpp` but never instantiated |
| 4 | **StreamingPulsePayload** | `firmware/lib/subghz/StreamingPulsePayload.h/.cpp` | On-demand pulse reader for file-based transmission | `#include`d by `CC1101_Worker.cpp` but never instantiated |
| 5 | **SafeBuffer\<T\>** | `firmware/include/SafeBuffer.h` | RAII `malloc`/`free` wrapper template | Zero instantiations anywhere in the project |
| 6 | **StringBuffer\<MaxSize\>** | `firmware/include/StringBuffer.h` | Static-memory string builder template | Zero instantiations anywhere |
| 7 | **SubFileParser class** | `firmware/include/SubFileParser.h` (line 68) | `.sub` file parser class (`parseFile()`, `getPayload()`, etc.) | The class is never instantiated (its preset byte arrays ARE used, but the class wrapper isn't) |
| 8 | **bruter_init() / bruter_handleCommand()** | `firmware/src/modules/bruter/bruter_main.cpp` lines 65-73 | Bruter module init and command dispatch stub | Never called; bruter is initialized via `BruterCommands` instead |
| 9 | **DeviceControls::poweronBlink()** | `firmware/src/core/device_controls/DeviceControls.cpp` line 60 | LED blink pattern on power-on | Only reference was a commented-out call in `main.cpp:874` |

### Pattern

The most common pattern is code that was ported from Flipper Zero or written for a refactor that never landed — **fully implemented, compiled into the binary, but with no call site**. This wastes flash space and, depending on linker garbage collection, may or may not be stripped.

### Quick wins to wire in (similar to what we just did)

- **`KeeloqCipher`** — if ProtoPirate mode ever needs to decode/encode KeeLoq-rolling-code remotes (e.g., Chamberlain, LiftMaster), it's sitting there ready
- **`FlipperSubFile`** — could replace the hand-written `.sub` writing in `onSignalDecoded()` with a cleaner abstraction
- **`StreamingSubFileParser`** + **`StreamingPulsePayload`** — if the transmit path needs to handle very large `.sub` files without loading everything into RAM, this pair was designed for that

Would you like me to explore any of these further, or investigate whether any are low-hanging fruit to either wire in or remove?
