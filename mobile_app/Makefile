# Evil Crow RF v2 Mobile App — Makefile
# Mirrors Build_APK_android.bat: setup SDK, install deps, build release APK.
#
# Prerequisites (must be on PATH before running):
#   - Java 11+  (Temurin or any OpenJDK)
#   - Flutter   (https://flutter.dev/docs/get-started/install)
#
# Quick start:
#   make setup          — one-time Android SDK + dependency setup
#   make apk            — build the release APK
#   make all            — setup + build in one step

# ── Configurable paths / versions ──────────────────────────────────────
ANDROID_HOME ?= $(HOME)/android/sdk
CMDLINE_TOOLS_URL := https://dl.google.com/android/repository/commandlinetools-linux-9477386_latest.zip
ANDROID_PLATFORM := android-36
BUILD_TOOLS_VER := 36.1.0

# ── Required SDK paths (used for existence checks) ────────────────────
REQUIRED_SDK_DIRS := \
	$(ANDROID_HOME)/platform-tools \
	$(ANDROID_HOME)/build-tools/$(BUILD_TOOLS_VER) \
	$(ANDROID_HOME)/platforms/$(ANDROID_PLATFORM)

# ── Derived paths ──────────────────────────────────────────────────────
SDKMANAGER      := $(ANDROID_HOME)/cmdline-tools/latest/bin/sdkmanager
ADB             := $(ANDROID_HOME)/platform-tools/adb
APK_OUTPUT      := build/app/outputs/flutter-apk/app-release.apk

# ── Helpers ────────────────────────────────────────────────────────────
BLUE  := \033[1;34m
GREEN := \033[1;32m
RED   := \033[1;31m
RESET := \033[0m

define banner
	@printf "\n$(BLUE)== $1 ==$(RESET)\n\n"
endef

# ── Phony targets ──────────────────────────────────────────────────────
.PHONY: all setup check-java check-flutter check-sdk install-sdk install-deps \
        accept-licenses write-local-properties apk clean help

# ── Default ────────────────────────────────────────────────────────────
help: ## Show this help
	@printf "Usage: make [target]\n\n"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  $(GREEN)%-24s$(RESET) %s\n", $$1, $$2}'

# ── All-in-one ─────────────────────────────────────────────────────────
all: setup apk ## Setup environment + build release APK

# ═══════════════════════════════════════════════════════════════════════
#  Setup targets
# ═══════════════════════════════════════════════════════════════════════
setup: check-java check-flutter check-sdk install-sdk accept-licenses \
       write-local-properties install-deps ## One-time development environment setup

check-java: ## Verify Java 11+ is available
	$(call banner,Check Java)
	@java -version 2>&1 | head -1 || \
		(echo "$(RED)Java not found. Install OpenJDK 11+ and re-run.$(RESET)"; exit 1)

check-flutter: ## Verify Flutter is available
	$(call banner,Check Flutter)
	@flutter --version 2>&1 | head -1 || \
		(echo "$(RED)Flutter not found. Install from https://flutter.dev$(RESET)"; exit 1)
	@flutter doctor

check-sdk: ## Check which required SDK components are present
	$(call banner,Check SDK components)
	@echo "  SDK root: $(ANDROID_HOME)"
	@for dir in $(REQUIRED_SDK_DIRS); do \
		if [ -d "$$dir" ]; then \
			echo "  $(GREEN)✓$(RESET) $$dir"; \
		else \
			echo "  $(RED)✗$(RESET) $$dir  (will be installed)"; \
		fi; \
	done

install-sdk: check-sdk $(SDKMANAGER) ## Download Android command-line tools + SDK components

$(SDKMANAGER):
	$(call banner,Install Android SDK command-line tools)
	@mkdir -p $(ANDROID_HOME)/cmdline-tools/latest
	@echo "Downloading command-line tools..."
	@curl -fsSL "$(CMDLINE_TOOLS_URL)" -o /tmp/cmdline-tools.zip
	@unzip -qo /tmp/cmdline-tools.zip -d /tmp/cmdline-tools-tmp
	@cp -a /tmp/cmdline-tools-tmp/cmdline-tools/. $(ANDROID_HOME)/cmdline-tools/latest/
	@rm -rf /tmp/cmdline-tools.zip /tmp/cmdline-tools-tmp
	@echo "$(GREEN)Command-line tools installed to $(ANDROID_HOME)/cmdline-tools/latest$(RESET)"
	@echo "Installing missing SDK components..."
	@$(SDKMANAGER) --sdk_root=$(ANDROID_HOME) \
		"platform-tools" \
		"build-tools;$(BUILD_TOOLS_VER)" \
		"platforms;$(ANDROID_PLATFORM)" \
		--verbose

	$(call banner,Final SDK component check)
	@echo "  $(GREEN)✓$(RESET) platform-tools"
	@echo "  $(GREEN)✓$(RESET) build-tools/$(BUILD_TOOLS_VER)"
	@echo "  $(GREEN)✓$(RESET) platforms/$(ANDROID_PLATFORM)"

accept-licenses: check-sdk $(SDKMANAGER) ## Accept all Android SDK licenses
	$(call banner,Accept SDK licenses)
	@yes | $(SDKMANAGER) --sdk_root=$(ANDROID_HOME) --licenses > /dev/null 2>&1 || true
	@echo "$(GREEN)SDK licenses accepted.$(RESET)"

write-local-properties: ## Write android/local.properties with sdk.dir
	$(call banner,Update android/local.properties)
	@if [ -f android/local.properties ] && grep -q '^flutter\.' android/local.properties; then \
		sed -i 's|^sdk\.dir=.*|sdk.dir=$(ANDROID_HOME)|' android/local.properties; \
	else \
		printf "sdk.dir=$(ANDROID_HOME)\n" > android/local.properties; \
	fi
	@echo "$(GREEN)Wrote android/local.properties$(RESET)"

install-deps: ## Run flutter pub get
	$(call banner,Install Flutter dependencies)
	@flutter pub get
	@echo "$(GREEN)Dependencies installed.$(RESET)"

# ═══════════════════════════════════════════════════════════════════════
#  Build targets
# ═══════════════════════════════════════════════════════════════════════
apk: accept-licenses write-local-properties install-deps ## Build release APK (flutter build apk --release)
	$(call banner,Build APK)
	@export ANDROID_HOME="$(ANDROID_HOME)"; \
		flutter build apk --release
	@echo ""
	@echo "$(GREEN)APK built successfully!$(RESET)"
	@echo "Location: $(APK_OUTPUT)"

# ═══════════════════════════════════════════════════════════════════════
#  Clean
# ═══════════════════════════════════════════════════════════════════════
clean: ## Remove Flutter build artifacts
	@flutter clean
	@echo "$(GREEN)Cleaned.$(RESET)"
