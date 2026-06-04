# BLE Connection Reliability Analysis — EvilCrowRF-V2

_Generated from a full read of the NimBLE firmware transport (`firmware/src/core/ble/`) and the Android Flutter client (`mobile_app/lib/providers/ble_provider.dart`)._

---

## 1. Unicode / character encoding (implicit contract risk)

On the Android side, `ble_provider.dart` sends commands via `_convertCommandToFirmwareProtocol` and receives data through the binary chunk path but also through `String.fromCharCodes` (raw bytes re-interpreted as UTF-16 strings on the Dart side). The firmware wraps all non-binary responses as JSON `String` objects and converts through Arduino `String` (Latin-1 / single-byte encoding).

For any response byte ≥ 0x80 in a JSON payload — e.g. extended ASCII characters in file names, filesystem paths, or firmware version strings — Dart will decode it as a surrogate / UTF-16 sequence and silently corrupt the data. This is particularly dangerous for file paths and firmware version strings that may contain non-ASCII bytes.

**Fix**:

- **Firmware**: encode all text responses as UTF-8 before sending over the wire.
- **Android**: decode all incoming `Uint8List` chunks with `utf8.decode`, not `String.fromCharCodes`, before any JSON parsing or string comparison.

---

## 2. Supervision timeout is not tuned on the Android client

`BleProvider` calls `device.requestMtu(512)` but never uses `flutter_blue_plus` to request connection parameters such as slave latency or supervision timeout. The NimBLE ESP32 runs at the default 2-second supervision timeout; a single momentary RF glitch (Wi-Fi co-existence, body blocking, moving the phone) will tear down the link.

**Fix**:

- On Android, use `flutter_blue_plus` `connectionPriority` to prefer a stable `balanced` link. This maps to longer connection intervals and effectively higher slave latency on the phone side.
- On the firmware side, explicitly configure connection parameters (connection interval min/max, slave latency, supervision timeout) before advertising starts, so the controller has a stable baseline regardless of what the phone requests.

---

## 3. `vTaskDelay(500ms)` before re-advertising on disconnect

In `BleAdapter::ServerCallbacks::onDisconnect` (`BleAdapter.cpp`, line ~762):

```cpp
vTaskDelay(pdMS_TO_TICKS(500));
NimBLEDevice::startAdvertising();
```

NimBLE does **not** require a 500 ms delay before restarting advertising. This half-second gap dramatically widens the window during which the phone cannot see the device to initiate a reconnect. `flutter_blue_plus` has an internal reconnect timer, but it will eventually give up if the advertisement is not yet visible.

**Fix**:

```cpp
vTaskDelay(pdMS_TO_TICKS(50));  // 50 ms is sufficient
NimBLEDevice::startAdvertising();
```

---

## 4. No keepalive / heartbeat mechanism

There is no periodic heartbeat on either side. An idle BLE link silently drops after the supervision timeout expires (default 2 seconds on NimBLE). The app's `_commandCooldown` of 200 ms only fires when commands are being sent, so long idle periods go entirely unmonitored.

A `BinaryHeartbeat` message type (`0x82`) is already modelled in `binary_message_parser.dart` on the Android side — the protocol signal exists but nothing sends it on a timer.

**Fix**:

- Add a lightweight periodic keepalive on the ESP32: every 2–3 seconds, send a binary heartbeat packet (`0x82`). The keepalive does not need to wait for an ACK; merely sending it refreshes the supervision timer.
- The `ClientsManager::notifyAll()` path iterates all adapters without first checking `isConnected()`. Callers that fire notifications while no BLE client is attached waste cycles and risk accessing freed state. Guard `notifyAll` / `notifyAllBinary` with `if (pair.second->isConnected())`.

---

## 5. No receiver-side acknowledgement / retransmission for missing chunks

`sendSingleChunk` fires data with fixed `vTaskDelay(10 ms)` between chunks, but the Android receiver (`_handleChunkedResponse`) processes data purely as a passive listener. If a notification is lost — because of ATT_MTU overflow, a lost CONN_IND, or Android backpressure at the isolate boundary — the firmware has no mechanism to detect the loss and will never retransmit.

The practical symptom is occasional missing-file or corrupt-JSON messages that look like an "unstable connection".

**Fix**:

In `_handleChunkedResponse`, when `_chunkTimeout` (10 s) fires without gathering all chunks, clear the buffer and surface the event as a named error so the UI can trigger a re-fetch instead of silently stalling.

```dart
// After stale detection in _cleanupStaleChunkBuffers():
// If a buffer is declared stale, fire a clear event
// so the UI or caller can decide to re-send the request.
```

---

## 6. `_resetConnectionState` silently drops the user into an unconnected state

When the connection drops (e.g. after any supervision timeout), `_resetConnectionState()` (`ble_provider.dart`, line ~640) clears `isConnected = false` and does **not** attempt any reconnect. The app simply shows "disconnected" and waits for the user to tap Connect again.

This is the single largest contributor to the user-perceived instability: the app appears to "lose" its connection spontaneously and stays stranded.

**Fix**:

Add a soft auto-reconnect in `_resetConnectionState()` with exponential back-off:

```dart
void _resetConnectionState() {
  _connectionStateSubscription?.cancel();
  _rxValueSubscription?.cancel();
  connectedDevice = null;
  txCharacteristic = null;
  rxCharacteristic = null;
  isConnected = false;
  statusMessage = 'disconnected';
  _commandTimeout?.cancel();
  // ... other state resets ...

  // Auto-reconnect with backoff when a device is known
  if (_knownDeviceId != null && !_otaRebootPending) {
    _scheduleReconnect(0);
  }
}

void _scheduleReconnect(int attempt) {
  final backoffMs = [500, 1000, 2000][attempt.clamp(0, 2)];
  _otaReconnectTimer?.cancel();
  _otaReconnectTimer = Timer(Duration(milliseconds: backoffMs), () async {
    if (isConnected || _knownDeviceId == null) return;
    try {
      final device = BluetoothDevice.fromId(_knownDeviceId!);
      await connectToDevice(device);
    } catch (e) {
      if (attempt < 2) _scheduleReconnect(attempt + 1);
    }
  });
}
```

---

## 7. `setNotifyValue(true)` is called before MTU negotiation

In `connectToDevice` (`ble_provider.dart`, lines ~567–571):

```dart
await rxCharacteristic!.setNotifyValue(true);   // line 568
// ...
int mtu = await device.requestMtu(512);          // line 572
```

The CCCD write that enables notifications and the MTU exchange are in the wrong order. Many Android BLE stacks require the MTU exchange to happen before data flow starts; calling `setNotifyValue` first means the first wave of notifications may arrive at the default 23-byte ATT_MTU, causing immediate fragmentation on the receiver side.

**Fix** — swap the two calls:

```dart
try {
  int mtu = await device.requestMtu(512);
} catch (e) {
  print('MTU negotiation failed: $e');  // log and continue
}
await rxCharacteristic!.setNotifyValue(true);
```

---

## 8. Flutter write timeout of 10 s blocks the Dart event loop

The BLE write call uses a 10-second Dart timeout (`ble_provider.dart`, line ~850):

```dart
await txCharacteristic!.write(commandBytes).timeout(
  const Duration(seconds: 10),
  onTimeout: () => throw Exception('BLE write timeout after 10 seconds'),
);
```

`flutter_blue_plus` writes go through a platform channel. A 10-second `timeout` future blocks the Dart isolate's main thread for the full duration. During that window, no incoming notification events are dispatched — so a response that *did* arrive gets queued silently and the app appears frozen.

**Fix**: reduce the write timeout to 3 seconds. Commands that legitimately take longer (e.g. file list) already have a separate `_startCommandTimeout` applied at the application layer.

```dart
await txCharacteristic!.write(commandBytes).timeout(
  const Duration(seconds: 3),
  onTimeout: () => throw TimeoutException('BLE write timeout', Duration(seconds: 3)),
);
```

This reduces worst-case perceived freeze time by 3× without removing timeout protection.

---

## 9. Chunk stale timeout of 2 s is too aggressive under Android isolate scheduling

```dart
static const Duration _chunkStaleTimeout = Duration(seconds: 2);
```

Android isolates introduce GC pauses and scheduler jitter. Under concurrent load (e.g. recording + transmitting simultaneously), two seconds is often not enough for all fragments of a large file-transfer chunk to arrive. The current stale declaration evicts the entire buffer, dropping any in-progress file transfer.

**Fix**: increase to 4–5 seconds (still bounded by the 10-second overall chunk timeout):

```dart
static const Duration _chunkStaleTimeout = Duration(seconds: 4);
```

---

## 10. NimBLE `onSubscribe` not implemented — CCCD state is race-prone

NimBLE does not preserve the CCCD "Notify enabled" bit across disconnections. After `onDisconnect` → reconnect → `setNotifyValue(true)`, there is a brief window where the ESP32 may already be sending notifications (e.g. a spontaneous state update) but the Android side has not yet subscribed. The first few notifications are silently dropped.

`CharacteristicCallbacks` in `BleAdapter.h` already exists but does not override `onSubscribe`.

**Fix**: implement `onSubscribe` on the firmware side so `deviceConnected` is only set `true` once the CCCD subscription event has actually arrived from the central:

```cpp
class CharacteristicCallbacks : public NimBLECharacteristicCallbacks {
  BleAdapter* adapter;
public:
  // ... existing onWrite ...

  void onSubscribe(NimBLECharacteristic* pCharacteristic,
                   NimBLEConnInfo& connInfo,
                   uint16_t subscriptionValue) override {
    if (subscriptionValue != 0) {
      adapter->deviceConnected = true;
    }
  }
};
```

---

## 10b. `ClientsManager::notifyAll` iterates adapters without checking `isConnected`

`ClientsManager.cpp` `notifyAll` and `notifyAllBinary` iterate over every registered adapter and call `notify()` regardless of connection state:

```cpp
void ClientsManager::notifyAll(NotificationType type, const std::string& message) {
  for (const auto& pair : adapters) {
    pair.second->notify(typeName, message);  // no isConnected() guard
  }
}
```

When no BLE client is connected, this still calls `BleAdapter::notify()`, which copies the payload into `String` objects and evaluates `deviceConnected` at the end — wasted work on an ESP32 with ~320 KB heap.

**Fix**: guard with `isConnected()`:

```cpp
void ClientsManager::notifyAll(NotificationType type, const std::string& message) {
  for (const auto& pair : adapters) {
    if (pair.second->isConnected()) {
      pair.second->notify(typeName, message);
    }
  }
}
```

---

## 11. NimBLE connection parameters should be configured explicitly

The ESP32 NimBLE stack defaults to a connection interval of roughly 30–50 ms, with no slave latency and a 2-second supervision timeout. On a crowded 2.4 GHz band this is fragile.

Current `begin()` code requests MTU 512 but never sets `conn_itvl_min`, `conn_itvl_max`, `slave_latency`, or `supervision_timeout`.

**Fix** — configure before `startAdvertising()`:

```cpp
// In begin(), after pServer->setCallbacks(...):
struct ble_gap_conn_params params;
params.itvl_min  = 0x0048;  // 30 ms  (NimBLE unit = 1.25 ms)
params.itvl_max  = 0x0096;  // 75 ms
params.slave_latency   = 4; // tolerate up to 4 skipped connection events
params.conn_timeout    = 600; // 6 s supervision timeout (NimBLE unit = 10 ms)

ble_gap_set_preferred_conn_params(&params);
```

Even if the Android central sends its own preference, NimBLE uses these as the starting point for the connection parameter negotiation.

---

## Summary table (prioritised)

| Priority | Issue | File | Effort |
|----------|-------|------|--------|
| **P0** | **No auto-reconnect** — app stays stranded on disconnect | `ble_provider.dart:640` `_resetConnectionState()` | Low |
| **P0** | **500 ms reconnect delay** in NimBLE `onDisconnect` | `BleAdapter.cpp:762` | Trivial |
| **P1** | **MTU before notify** — order of operations | `ble_provider.dart:567–571` | Trivial |
| **P1** | **10 s write timeout** blocks Dart isolate | `ble_provider.dart:850–854` | Low |
| **P1** | **2 s chunk stale timeout too aggressive** | `ble_provider.dart:1396` | Trivial |
| **P2** | **No keepalive** — silent idle-drop | Add binary heartbeat (`0x82` timer) | Low |
| **P2** | **Connection parameters not tuned** — default 2 s supervision, no slave latency | NimBLE gap params + Android `connectionPriority` | Medium |
| **P3** | **`notifyAll` iterates disconnected adapters** | `ClientsManager.cpp:44–60` | Low |
| **P3** | **`CharacteristicCallbacks::onSubscribe` not implemented** — CCCD race | `BleAdapter.h:54–59` + `BleAdapter.cpp` | Low |

The two highest-impact changes for the least code are:

1. **(P0)** Reduce the 500 ms → 50 ms advertising restart delay in NimBLE's `onDisconnect`.
2. **(P0)** Add exponential-backoff auto-reconnect to `_resetConnectionState()` in `ble_provider.dart`.

Those two changes alone eliminate the majority of user-visible disconnection events without touching the binary protocol layer.
