* Abstract writing to storage. Littlefs was corrupted and we needed to clean it up and reflash. in the process we lost wifi config. Mirror littlefs to sdcard (if available) on all writes. If Littlefs is corrupted and expected file is available in SDCard mirror, then inform the user by pushing a notification, and use the available file. Here's the complete LittleFS usage across the firmware:

## Filesystems

LittleFS is mounted at boot in `main.cpp:612-621`. The `data/` directory on the host populates it at flash time. SD is optional — when absent, several features fall back to LittleFS (pathType 4).

### `include/ConfigManager.h` — Config persistence
| Function | File | Operation |
|---|---|---|
| `loadSettings()` | `/config.txt` | Read (or create defaults) |
| `saveSettings()` | `/config.tmp` → `/config.txt` | Atomic write + rename |
| `resetConfigToDefault()` | `/config.txt` | Remove |
| `factoryReset()` | `/config.txt`, `/sleep_mode.flag`, `/service_mode.flag` | Remove + `format()` + reboot |
| `setFlag()` / `clearFlag()` / `isFlagSet()` | Arbitrary path | Toggle flag files |

### `include/BruterState.h` — Attack resume state
| Function | File | Operation |
|---|---|---|
| `save()` | `/bruter_state.bin` | Write |
| `load()` | `/bruter_state.bin` | Read |
| `clear()` | `/bruter_state.bin` | Remove |
| `exists()` | `/bruter_state.bin` | Check |

### `include/FileCommands.h` — File browser API
| Operation | Path | Detail |
|---|---|---|
| `getFS()` | pathType==4 → LittleFS | Select filesystem by type |
| List directory | `/` (LittleFS root) | Recursive listing, no timestamps |
| Read/Write/Delete | Various paths | Via Arduino File API + pathType routing |

### `src/modules/nrf/NrfJammer.cpp` — NRF jammer config
| Operation | File | Detail |
|---|---|---|
| Init/load | `/nrf_jam_cfg.bin` | Read on startup |
| Save | `/nrf_jam_cfg.bin` | Write on config change |

### `src/modules/CC1101_driver/CC1101_Worker.cpp` — Signal transmit
| Operation | Detail |
|---|---|
| pathType==4 → LittleFS | Selects LittleFS for signal file access |
| Transmit from LittleFS | **Not supported** — returns error message |

### `src/core/BinaryProtocolHandler.cpp` — File uploads
| Operation | Detail |
|---|---|
| pathType==1 → SD, else LittleFS | Upload destination routing |

### `src/main.cpp` — Boot mount
| Function | Detail |
|---|---|
| `setup()` | `begin(false)` → `begin(true)` on failure → abort if format fails |
