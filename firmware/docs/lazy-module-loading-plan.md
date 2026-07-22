# Lazy Module Loading Plan

## Problem

The ESP32 boot heap has ~39 KB free with 90% fragmentation (largest block 3828 bytes). Multiple modules are initialized at boot in `setup()` (`main.cpp:680-850`) even though they're only used when a specific command arrives from the app. This fragments the heap early and prevents other subsystems (SoftAP DHCP, BLE, etc.) from getting contiguous allocations.

## Current Boot-Time Memory Map

| Module | Boot cost | When actually used | Can defer? |
|--------|-----------|-------------------|------------|
| CC1101Worker (task queue + mutexes) | ~1 KB | Always (worker loop) | No |
| CC1101Worker stream buffers | **64 KB** (2 × 32 KB) | Only during Recording (ISR pushes) | **Yes** |
| CC1101Worker task stack | 6 KB (static) | Always (worker loop) | No |
| TaskProcessor task | 6 KB (dynamic) | Always (command dispatch) | No |
| SendNotifications task | 6 KB (dynamic) | Always (BLE/WiFi notifications) | No |
| SerialCmd task | 3 KB (dynamic) | Always (serial input) | No |
| TimeSync task | 1 KB (dynamic) | Always (clock) | No |
| **BruterModule** | **16 KB** (static task stack) + heap | Only on bruter TX command | **Yes** |
| **ProtoPirateModule** | **4 KB** (static task stack) + mutex + decoders | Only on ProtoPirate decode command | **Yes** |
| **nRF24L01** (NrfModule + MouseJack + NrfJammer) | SPI bus init + config loads + heap | Only on NRF jam/mousejack/spectrum commands | **Yes** |
| BatteryModule | ADC config (~0 heap) | Only on battery status query | **Yes** (low priority — minimal cost) |
| SDR module | Sets `initialized_` flag (~0 heap) | Only on SDR enable command | **Yes** (low priority — minimal cost) |
| WiFi/BLE adapter | Transport stack | Always (device connectivity) | No |
| SD card | Filesystem mount | Always (file operations) | No |
| CommandHandler | Function pointer table (~0 heap) | Always (command dispatch) | No |
| ConfigManager | Settings load (~0 heap) | Always | No |

## Estimated Savings

| Module | Heap freed when idle | Notes |
|--------|---------------------|-------|
| Stream buffers (deferred per-module) | **32-64 KB** | Created per-module in `handleStartRecord`, freed in `handleStopRecord`. 0 KB at boot, 32 KB per active module, 64 KB max if both modules capture simultaneously. |
| BruterModule task stack | **16 KB** | Static array in `.bss` → move to on-demand `xTaskCreateStatic` or `xTaskCreate` |
| ProtoPirateModule task stack | **4 KB** | Same pattern |
| nRF24L01 init | ~1-2 KB | SPI bus + config reads; defer until NRF command arrives |
| **Total** | **~53-85 KB** | When no capture/bruter/ProtoPirate/NRF is active |

## Implementation Plan

### ✅ Phase 1: Defer CC1101 stream buffers per-module to capture start (COMPLETE)

**Files:** `SubGhzCaptureManager.h/cpp`, `CC1101_Worker.cpp`

**Change made (2026-07-15):**
- Moved stream buffer creation from `init()` into `ensureReceiver(module)` — only the activated module's stream buffer is allocated.
- Moved stream buffer deletion from `~SubGhzCaptureManager()` into `freeReceiver(module)` — the buffer is freed when capture stops.
- `init()` is now a no-op (just logs).

**Memory model:**

| State | Module 0 | Module 1 | Total heap for buffers |
|-------|----------|----------|----------------------|
| Boot (idle) | null | null | **0 KB** |
| Capture on module 0 | 32 KB stream + receiver | null | **~32 KB** |
| Capture on module 1 | null | 32 KB stream + receiver | **~32 KB** |
| Capture on both | 32 KB stream + receiver | 32 KB stream + receiver | **~64 KB** |
| After stop | null | null | **0 KB** |

**Risk:** Low. Null-checks already exist in `isrPush`, `isrSignalOverrun`, and `process`. This extends the same lifecycle already proven with lazy receivers.

### ✅ Phase 2: Defer BruterModule to first bruter command (COMPLETE)

**Files:** `bruter_main.h/cpp`, `main.cpp`

**Changes made (2026-07-15):**
- Removed `static StackType_t bruterTaskStack[4096]` and `static StaticTask_t bruterTaskTCB` — 16 KB no longer in .bss.
- Changed `startAttackAsync()` and `resumeAttackAsync()` from `xTaskCreateStatic()` to `xTaskCreatePinnedToCore()` — task stack is allocated from heap only when an attack runs, freed on task self-delete (`vTaskDelete(NULL)`).
- Removed `bruter_init()` call from `setup()` in `main.cpp`.
- Removed `checkAndNotifySavedState()` call from `setup()` — the app queries saved state via sub-command `0xF9` (already implemented in `BruterCommands` and `serialCommandTask`).
- Added comment explaining lazy init (attack task calls `setupCC1101()` internally).

**Design note:** No `ensureBruterInit()` guard was needed in command handlers because `attackTaskFunc()` already calls `setupCC1101()` at the start of every attack. Commands that don't start attacks (setModule, setDelay, query saved state) don't need CC1101 initialized.

**Savings:** ~16 KB stack in .bss eliminated. The 16 KB heap allocation only exists during active attacks (transient).

### ✅ Phase 3: Defer ProtoPirateModule to first ProtoPirate command (COMPLETE)

**Files:** `ProtoPirateModule.h/cpp`, `main.cpp`, `ProtoPirateCommands.h`

**Changes made (2026-07-15):**
- Removed `static StackType_t taskStack_[4096]` and `static StaticTask_t taskTcb_` from class & .cpp — eliminates 16 KB from .bss.
- Changed `startDecode()` from `xTaskCreateStatic()` to `xTaskCreatePinnedToCore()` — task stack allocated from heap during decode, freed on task self-delete.
- Added `deinit()` method: stops decode, frees decoders, deletes mutex.
- Added `isInitialized()` accessor (checks `mutex_ != nullptr`).
- Added `ensureInit()` helper in `ProtoPirateCommands.h` — calls `pp.init()` if not yet initialized, returns false on failure. Guards are placed in: `cmdStartDecode`, `cmdGetHistoryEntry`, `cmdClearHistory`, `cmdLoadSubFile`, `cmdEmulate`, `cmdSaveCapture`.
- Removed `ProtoPirateModule::getInstance().init()` from `setup()` in `main.cpp`.

**Commands that work without init** (no guard needed): StopDecode, GetHistoryCount, GetStatus, ListSubFiles, ListSaved.

**Savings:** ~16 KB task stack in .bss eliminated. Only ~a few hundred bytes for the heap-allocated task stack during active decode (transient).

### ✅ Phase 4: Defer nRF24L01 to first NRF command (COMPLETE)

**Files:** `NrfCommands.h`, `main.cpp`

**Changes made (2026-07-15):**
- Added `ensureNrfInit()` helper in `NrfCommands.h`: calls `NrfJammer::loadConfigs()` + `NrfModule::init()` + `MouseJack::init()` on first use. Guarded by `NrfModule::isInitialized()` — runs only once.
- Added `ensureNrfInit()` guards to 7 command handlers that access NRF hardware: `handleScanStart`, `handleAttackHid`, `handleAttackString`, `handleAttackDucky`, `handleSpectrumStart`, `handleJamStart`, `handleNrfSettings`.
- `handleInit` (0x20) already does its own init — no guard needed.
- Commands that only manage state (stop, status, config read) work without init.
- Removed NRF init block from `setup()` in `main.cpp`.

**Note:** `NrfModule::deinit()` was already implemented — no changes needed.

**Savings:** ~1-2 KB heap from SPI bus init + config loading deferred until first NRF command.

### ✅ Phase 5: Defer BatteryModule and SDR module (COMPLETE)

**Files:** `BatteryModule.cpp`, `StateCommands.h`, `main.cpp`

**Changes made (2026-07-15):**
- `BatteryModule::sendBatteryStatus()` now calls `init()` lazily if not yet initialized. Since `init()` is already idempotent (`if (initialized_) return;`), this is safe to call from any context.
- `StateCommands::handleGetState()`: removed the `if (BatteryModule::isInitialized())` guard — `sendBatteryStatus()` handles lazy init internally.
- `SdrModule::init()` was already effectively lazy (just sets a flag). No code change needed beyond removing the boot-time call.
- Removed both `BatteryModule::init()` and `SdrModule::init()` calls from `setup()` in `main.cpp`.

**Risk:** Very low. BatteryModule was already guarded by `initialized_`. SdrModule init is a no-op.

**Savings:** Minimal (~0 heap), but ensures consistency — no module initializes at boot unless essential.

---

## All Phases Complete 🎉

| Phase | Module | Savings | Status |
|-------|--------|---------|--------|
| 1 | Stream buffers | 64 KB at boot | ✅ Complete |
| 2 | BruterModule | 16 KB .bss → heap | ✅ Complete |
| 3 | ProtoPirateModule | 16 KB .bss → heap | ✅ Complete |
| 4 | nRF24L01 | ~1-2 KB heap | ✅ Complete |
| 5 | Battery/SDR | ~0 KB | ✅ Complete |

**Total estimated savings:** ~65-98 KB when no capture/bruter/ProtoPirate/NRF is active.

## Design Pattern

All phases follow the same pattern:

```
// Lazy init guard (called at entry to each command handler)
void ModuleCommands::ensureInit() {
    if (initialized_) return;
    initialized_ = true;
    // ... create resources ...
}

// Teardown (called when module goes idle)
void ModuleCommands::deinit() {
    if (!initialized_) return;
    // ... free resources ...
    initialized_ = false;
}
```

Each module's command handler calls `ensureInit()` as its first action. Each module's stop/idle handler calls `deinit()`. The `initialized_` flag prevents double-init and double-free.

## Testing

After each phase:
1. Boot the device — verify heap stats improve.
2. Verify SoftAP connects (the original symptom).
3. Verify the deferred module still works when invoked.
4. Verify the module's memory is reclaimed after use (call `logHeapStats` before/after).
5. Verify no regressions in other modules.