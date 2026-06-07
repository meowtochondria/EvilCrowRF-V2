.PHONY: help setup setup-esptoolpy build clean flash test monitor flash-monitor show-device-mac

PYTHON := python
ENV_DIR := .venv
PLATFORMIO := $(ENV_DIR)/bin/platformio

help:
	@echo "EvilCrowRF-V2 Firmware Build System"
	@echo ""
	@echo "Available targets:"
	@echo "  setup    - Create virtual environment and install dependencies"
	@echo "  build    - Build ESP32 firmware (production mode)"
	@echo "  clean    - Clean build artifacts"
	@echo "  flash         - Flash firmware to ESP32"
	@echo "  monitor       - Open serial monitor"
	@echo "  flash-monitor - Flash then open serial monitor"
	@echo "  show-device-mac - Read ESP32 MAC address via esptool"
	@echo "  test     - Run tests"
	@echo "  update   - Update PlatformIO and dependencies"

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

build: setup
	@echo "Building ESP32 firmware (production)..."
	@uv run platformio run --environment esp32dev
	@echo ""
	@echo "Firmware built successfully!"
	@echo "Firmware: .pio/build/esp32dev/firmware.bin"

clean:
	@uv run platformio run --verbose --target clean
	@rm -rf .pio

flash: build
	@echo "Flashing firmware to ESP32..."
	@uv run platformio run --verbose --target upload --environment esp32dev

flash-monitor:
	@uv run platformio run --target upload --target monitor --environment esp32dev

update:
	@uv sync
	@uv run platformio upgrade

test:
	@uv run platformio test

show-device-wifi-mac:
	@uv run esptool --chip esp32 read_mac
