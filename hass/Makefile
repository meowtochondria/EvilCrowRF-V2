.DEFAULT_GOAL := help

HA_CONFIG_DIR ?= $(HOME)/.homeassistant
CUSTOM_COMPONENT_DIR := custom_components/evilcrow_rf
SYMLINK_TARGET := $(HA_CONFIG_DIR)/custom_components/evilcrow_rf

.PHONY: help install uninstall reinstall ensure-python dev-env lock refresh-deps test lint fmt check typecheck clean run run-full logs ci deploy

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

ensure-python: ## Ensure a Python matching pyproject.toml is available (installs via uv if missing)
	@uv python install

dev-env: ensure-python ## Create a virtual environment and sync dependencies (uv sync)
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
	find . -type d -name __pycache__ -exec rm -rf {} +
	find . -type d -name .pytest_cache -exec rm -rf {} +
	find . -type f -name '*.pyc' -delete

run: ensure-python ## Start Home Assistant (core) pointing at this config
	uv run hass -c "$(HA_CONFIG_DIR)" --debug

run-full: ensure-python ## Start Home Assistant with full debug logging for the component
	@echo "Starting Home Assistant with EvilCrowRF debug logging..."
	HASS_LOG_LEVEL=debug \
	uv run hass -c "$(HA_CONFIG_DIR)" \
		--log-level custom_components.evilcrow_rf=debug \
		--log-level aiohttp=debug

logs: ## Tail the Home Assistant log
	tail -f "$(HA_CONFIG_DIR)/home-assistant.log" 2>/dev/null || \
		tail -f "$(HA_CONFIG_DIR)/home-assistant/home-assistant.log" 2>/dev/null || \
		echo "Log file not found"

ci: dev-env check test ## Run all CI checks (dev-env, lint, format-check, typecheck, test)

deploy: ## SCP the component to a remote HA server and restart. Usage: make deploy SERVER=user@host REMOTE_PATH=/config/custom_components/evilcrow_rf [HASS_TOKEN=xxx]
	@if [ -z "$(SERVER)" ]; then echo "Error: SERVER is required. Usage: make deploy SERVER=user@host REMOTE_PATH=/config/custom_components/evilcrow_rf"; exit 1; fi
	@if [ -z "$(REMOTE_PATH)" ]; then echo "Error: REMOTE_PATH is required. Usage: make deploy SERVER=user@host REMOTE_PATH=/config/custom_components/evilcrow_rf"; exit 1; fi
	@case "$(REMOTE_PATH)" in *custom_components/evilcrow_rf) ;; *) echo "Error: REMOTE_PATH must end with 'custom_components/evilcrow_rf' (got: $(REMOTE_PATH))"; exit 1;; esac
	@echo "==> Deploying $(CUSTOM_COMPONENT_DIR) to $(SERVER):$(REMOTE_PATH)..."
	ssh $(SERVER) "mkdir -p $(REMOTE_PATH)"
	tar --exclude-from=$$(pwd)/.gitignore --directory $(CUSTOM_COMPONENT_DIR) --create --file - . | ssh $(SERVER) "tar --directory $(REMOTE_PATH) --extract --file -"
	@echo "==> Deploy complete. Restarting Home Assistant..."
	@if [ -n "$(HASS_TOKEN)" ]; then \
		echo "Calling restart API on $(SERVER)..."; \
		http_code=$$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "Authorization: Bearer $(HASS_TOKEN)" -H "Content-Type: application/json" https://$(SERVER)/api/services/homeassistant/restart); \
		if [ "$$http_code" = "200" ]; then \
			printf "Response code: \033[32m%s\033[0m\n" "$$http_code"; \
		else \
			printf "Response code: \033[31m%s\033[0m\n" "$$http_code"; \
		fi; \
		echo ""; \
	else \
		echo "HASS_TOKEN is unset — cannot restart automatically."; \
		echo "Restart Home Assistant manually to pick up the changes."; \
	fi
