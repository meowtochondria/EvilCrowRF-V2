.DEFAULT_GOAL := help

HA_CONFIG_DIR ?= ~/.homeassistant
CUSTOM_COMPONENT_DIR := custom_components/evilcrow_rf
SYMLINK_TARGET := $(HA_CONFIG_DIR)/custom_components/evilcrow_rf

.PHONY: help install uninstall reinstall dev-env lock refresh-deps test lint fmt check typecheck clean run run-full logs ci

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

install: ## Symlink the custom component into the Home Assistant config directory
	@mkdir -p "$(HA_CONFIG_DIR)/custom_components"
	@if [ -L "$(SYMLINK_TARGET)" ] || [ -e "$(SYMLINK_TARGET)" ]; then \
		echo "Removing existing $(SYMLINK_TARGET)"; \
		rm -rf "$(SYMLINK_TARGET)"; \
	fi
	ln -s "$$(pwd)/$(CUSTOM_COMPONENT_DIR)" "$(SYMLINK_TARGET)"
	@echo "Symlinked $(CUSTOM_COMPONENT_DIR) -> $(SYMLINK_TARGET)"

uninstall: ## Remove the symlink from the Home Assistant config directory
	@if [ -L "$(SYMLINK_TARGET)" ]; then \
		rm "$(SYMLINK_TARGET)"; \
		echo "Removed symlink at $(SYMLINK_TARGET)"; \
	elif [ -e "$(SYMLINK_TARGET)" ]; then \
		echo "Warning: $(SYMLINK_TARGET) exists but is not a symlink. Remove manually."; \
	else \
		echo "Nothing to uninstall — $(SYMLINK_TARGET) does not exist."; \
	fi

reinstall: uninstall install ## Reinstall the symlink

dev-env: ## Create a virtual environment and sync dependencies (uv sync)
	uv sync --all-extras --prerelease allow

lock: ## Generate/update uv.lock
	uv lock

refresh-deps: ## Refresh all dependency pins
	uv sync --all-extras --upgrade

test: ## Run the test suite with coverage
	uv run pytest

lint: ## Lint with ruff
	uv run ruff check .

fmt: ## Format with ruff
	uv run ruff format .

check: lint fmt-check ## Run lint and format-check
	@echo "--- Check complete ---"

fmt-check: ## Check formatting without making changes
	uv run ruff format --check .

clean: ## Remove generated files and caches
	rm -rf .venv __pycache__ .ruff_cache .mypy_cache .coverage htmlcov
	find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
	find . -type d -name .pytest_cache -exec rm -rf {} + 2>/dev/null || true
	find . -type f -name '*.pyc' -delete

run: ## Start Home Assistant (core) pointing at this config
	hass -c "$(HA_CONFIG_DIR)" --debug

run-full: ## Start Home Assistant with full debug logging for the component
	@echo "Starting Home Assistant with EvilCrowRF debug logging..."
	HASS_LOG_LEVEL=debug \
	hass -c "$(HA_CONFIG_DIR)" \
		--log-level custom_components.evilcrow_rf=debug \
		--log-level aiohttp=debug

logs: ## Tail the Home Assistant log
	tail -f "$(HA_CONFIG_DIR)/home-assistant.log" 2>/dev/null || \
		tail -f "$(HA_CONFIG_DIR)/home-assistant/home-assistant.log" 2>/dev/null || \
		echo "Log file not found"

ci: dev-env check test ## Run all CI checks (dev-env, lint, format-check, typecheck, test)
