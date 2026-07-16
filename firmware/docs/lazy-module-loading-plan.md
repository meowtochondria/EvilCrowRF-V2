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

### Phase 1: Defer CC1101 stream buffers per-module to capture start

**Files:** `SubGhzCaptureManager.h/cpp`, `CC1101_Worker.cpp`

Currently `init()` creates **both** stream buffers (2 × 32 KB = 64 KB) at boot, even though only one module is typically active at a time and the ISR only pushes to a buffer during `Recording` state (ISR attached in `handleStartRecord`). The app issues a capture command for a **specific module** — only that module's stream buffer and receiver need to exist.

**Current state (already implemented):**
- `init()` already only creates stream buffers (no receivers) — receivers are lazy.
- `ensureReceiver(module)` creates the receiver for the requested module only.
- `freeReceiver(module)` frees the receiver for that module.

**Remaining change (to complete Phase 1):**
- Move stream buffer creation from `init()` into `ensureReceiver(module)` so that **only the activated module's stream buffer** is allocated.
- Move stream buffer deletion from `~SubGhzCaptureManager()` into `freeReceiver(module)` so the buffer is freed when capture stops.
- `init()` becomes a true no-op (just logs).

**Memory model:**

| State | Module 0 | Module 1 | Total heap for buffers |
|-------|----------|----------|----------------------|
| Boot (idle) | null | null | **0 KB** |
| Capture on module 0 | 32 KB stream + receiver | null | **~32 KB** |
| Capture on module 1 | null | 32 KB stream + receiver | **~32 KB** |
| Capture on both | 32 KB stream + receiver | 32 KB stream + receiver | **~64 KB** |
| After stop | null | null | **0 KB** |

**Risk:** Low. Stream buffer is only used during active capture. The null-checks already exist in `isrPush`, `isrSignalOverrun`, and `process`. The receiver is already lazily created in `ensureReceiver` and freed in `freeReceiver` — this just extends the same lifecycle to the stream buffer.

### Phase 2: Defer BruterModule to first bruter command

**Files:** `bruter_main.h/cpp`, `main.cpp`

Currently `bruter_init()` is called at boot. It creates a mutex and loads saved state. The 16 KB static task stack (`bruterTaskStack[4096]`) is allocated in `.bss` at compile time — it's always in RAM regardless of whether bruter_init runs.

- Move `bruterTaskStack` and `bruterTaskTCB` from file-scope statics to dynamically allocated (use `xTaskCreate` instead of `xTaskCreateStatic`, or allocate the static arrays on first use via a function-local static).
- Remove `bruter_init()` from `setup()`.
- Add lazy init: first bruter command (TX, RX, etc.) calls `bruter_init()` if not already initialized.
- Add `bruter_deinit()`: stops any running attack, deletes task, frees mutex. Called when bruter goes idle (after attack completes or is stopped).
- `BruterCommands` handlers: add `ensureBruterInit()` guard at entry.

**Risk:** Medium. BruterModule has persistent state (paused attack, saved config). Need to ensure `checkAndNotifySavedState()` still works on first connect — move it to a lazy trigger (e.g., on first `GetState` command after connect, or on first bruter command).

### Phase 3: Defer ProtoPirateModule to first ProtoPirate command

**Files:** `ProtoPirateModule.h/cpp`, `main.cpp`

Currently `ProtoPirateModule::getInstance().init()` is called at boot. It creates a mutex and instantiates protocol decoders. The 4 KB static task stack (`taskStack_[4096]`) is in `.bss`.

- Move `taskStack_` and `taskTcb_` from class statics to dynamically allocated (or function-local statics inside `startDecode()`).
- Remove `ProtoPirateModule::getInstance().init()` from `setup()`.
- Add lazy init: first ProtoPirate command calls `init()` if not already initialized.
- Add `deinit()`: stops decode, deletes task, frees mutex + decoder instances. Called when ProtoPirate goes idle.
- `ProtoPirateCommands` handlers: add `ensureInit()` guard at entry.

**Risk:** Low. ProtoPirate is self-contained. `init()` is already idempotent (`if (mutex_) return true`).

### Phase 4: Defer nRF24L01 to first NRF command

**Files:** `NrfModule.h/cpp`, `NrfJammer.h/cpp`, `MouseJack.h/cpp`, `main.cpp`

Currently `NrfModule::init()`, `NrfJammer::loadConfigs()`, and `MouseJack::init()` are called at boot. These initialize the SPI bus and load config from flash.

- Remove NRF init from `setup()`.
- Add lazy init: first NRF command (jam, mousejack, spectrum) calls `NrfModule::init()` + `NrfJammer::loadConfigs()` + `MouseJack::init()` if not already initialized.
- Add `NrfModule::deinit()`: puts NRF to power-down, releases SPI. Called when NRF goes idle.
- `NrfCommands` handlers: add `ensureInit()` guard at entry.

**Risk:** Low. `NrfModule::init()` already returns false if hardware not detected. `NrfModule::initialized_` flag prevents double-init.

### Phase 5: Defer BatteryModule and SDR module (low priority)

**Files:** `BatteryModule.h/cpp`, `SdrModule.h/cpp`, `main.cpp`

These are minimal cost (~0 heap) but can be deferred for consistency.

- BatteryModule: `init()` configures ADC. Move to first `getBatteryVoltage()` call. Add `initialized_` guard.
- SDR module: `init()` just sets a flag. Already effectively lazy. No change needed.

**Risk:** Very low. These are nearly free.

## Implementation Order

1. **Phase 1** (stream buffers) — highest impact (64 KB), lowest risk.
2. **Phase 2** (BruterModule) — second highest impact (16 KB), medium risk.
3. **Phase 3** (ProtoPirateModule) — good impact (4 KB), low risk.
4. **Phase 4** (nRF24L01) — moderate impact (1-2 KB), low risk.
5. **Phase 5** (Battery/SDR) — minimal impact, lowest priority.

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