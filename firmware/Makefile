.PHONY: help setup setup-esptoolpy build build-bt build-wifi \
        clean flash flash-bt flash-wifi \
        monitor flash-monitor flash-monitor-bt flash-monitor-wifi \
        show-device-mac test update \
        build-littlefs-wifi flash-littlefs-wifi

PYTHON := python
ENV_DIR := .venv
PLATFORMIO := $(ENV_DIR)/bin/platformio

help:
	@echo "EvilCrowRF-V2 Firmware Build System"
	@echo ""
	@echo "Available targets:"
	@echo "  setup              - Create virtual environment and install dependencies"
	@echo "  build              - Build ESP32 firmware (BT mode, default)"
	@echo "  build-bt           - Build ESP32 firmware (BT mode)"
	@echo "  build-wifi         - Build ESP32 firmware (WiFi mode)"
	@echo "  clean              - Clean build artifacts"
	@echo "  flash              - Flash BT firmware to ESP32"
	@echo "  flash-bt           - Flash BT firmware to ESP32"
	@echo "  flash-wifi         - Flash WiFi firmware to ESP32"
	@echo "  monitor            - Open serial monitor"
	@echo "  flash-monitor      - Flash BT then open serial monitor"
	@echo "  flash-monitor-bt   - Flash BT then open serial monitor"
	@echo "  flash-monitor-wifi - Flash WiFi then open serial monitor"
	@echo "  show-device-mac    - Read ESP32 MAC address via esptool"
	@echo "  build-littlefs-wifi - Build blank LittleFS filesystem (WiFi mode)"
	@echo "  flash-littlefs-wifi - Build and upload blank LittleFS filesystem (WiFi mode)"
	@echo "  test               - Run tests"
	@echo "  update             - Update PlatformIO and dependencies"

setup:
	@uv sync
	@echo "Installing PlatformIO packages..."
	@uv run platformio pkg install || { \
		echo "platformio pkg install failed. Setting up package.json..."; \
		$(MAKE) setup-esptoolpy; \
		echo "Retrying platformio pkg install..."; \
		uv run platformio pkg install; \
	}
	@echo "Setup complete!"

setup-esptoolpy:
	@ESPTOOL_DIR=$$(echo ~)/.platformio/packages/tool-esptoolpy; \
		if [ ! -f "$$ESPTOOL_DIR/package.json" ]; then \
			echo "esptoolpy package.json not found. Setting up..."; \
			VERSION=$$(python -c "import tomllib; print(tomllib.load(open('$$ESPTOOL_DIR/pyproject.toml', 'rb'))['tool']['commitizen']['version'])"); \
			if [ -z "$$VERSION" ]; then \
				echo "ERROR: Could not detect esptool version from pyproject.toml"; \
				exit 1; \
			fi; \
			echo "Detected esptool version: $$VERSION"; \
			sed -i "s/\"version\": \"[^\"]*\"/\"version\": \"$$VERSION\"/" tools/esptool-package.json; \
			mkdir -p "$$ESPTOOL_DIR"; \
			cp tools/esptool-package.json "$$ESPTOOL_DIR/package.json"; \
			echo "esptoolpy package.json installed."; \
		else \
			echo "esptoolpy package.json already exists. Skipping."; \
		fi

setup-with-clangd: setup
	@uv run platformio run --target compiledb

build: build-bt

build-bt: setup
	@echo "Building ESP32 firmware (BT mode)..."
	@uv run platformio run --environment evilcrow-bt
	@echo ""
	@echo "BT firmware built successfully!"
	@echo "Firmware: .pio/build/evilcrow-bt/firmware.bin"

build-wifi: setup
	@echo "Building ESP32 firmware (WiFi mode)..."
	@uv run platformio run --environment evilcrow-wifi
	@echo ""
	@echo "WiFi firmware built successfully!"
	@echo "Firmware: .pio/build/evilcrow-wifi/firmware.bin"

clean:
	@uv run platformio run --verbose --target clean
	@rm -rf .pio

flash: flash-bt

flash-bt: build-bt
	@echo "Flashing BT firmware to ESP32..."
	@uv run platformio run --verbose --target upload --environment evilcrow-bt

flash-wifi: build-wifi
	@echo "Flashing WiFi firmware to ESP32..."
	@uv run platformio run --verbose --target upload --environment evilcrow-wifi

flash-monitor: flash-monitor-bt

flash-monitor-bt:
	@uv run platformio run --target upload --target monitor --environment evilcrow-bt

flash-monitor-wifi:
	@uv run platformio run --target upload --target monitor --environment evilcrow-wifi

monitor:
	@uv run platformio run --target monitor

update:
	@uv sync
	@uv run platformio upgrade

test:
	@uv run platformio test

build-littlefs-wifi: setup
	@mkdir -p data
	@echo "Building blank LittleFS filesystem (WiFi mode)..."
	@uv run platformio run --target buildfs --environment evilcrow-wifi
	@echo ""
	@echo "LittleFS filesystem built successfully!"

flash-littlefs-wifi: build-littlefs-wifi
	@echo "Uploading blank LittleFS filesystem (WiFi mode)..."
	@uv run platformio run --target uploadfs --environment evilcrow-wifi
	@echo ""
	@echo "LittleFS filesystem uploaded successfully!"

show-device-wifi-mac:
	@uv run esptool --chip esp32 read_mac

flash-erase:
	@uv run esptool --chip esp32 --port /dev/ttyUSB0 erase-flash
