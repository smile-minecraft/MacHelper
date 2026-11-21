# Developer entry points. Run `make` or `make help` for the list.
#
# Everyday work never touches /Applications: `make open` (then ⌘R in Xcode) or `make run`
# build a Debug copy under build/. `make install` is the one target that replaces the installed
# app. The Xcode used comes from xcode-select, or DEVELOPER_DIR in Config/Local.env.

SHELL := /bin/bash
ENV := . scripts/lib/env.sh &&
PROJECT := MacHelper.xcodeproj
CONFIGURATION ?= Debug
APP = build/Build/Products/$(CONFIGURATION)/MacHelper.app
# Extra xcodebuild settings, e.g. `make build XCODEBUILD_FLAGS="CODE_SIGN_IDENTITY=-"`.
XCODEBUILD_FLAGS ?=

.DEFAULT_GOAL := help
.PHONY: help setup project open build run test install release clean

help: ## List the targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-9s %s\n", $$1, $$2}'

setup: ## Check the tools, fetch Sparkle and generate the Xcode project
	@scripts/check-tools.sh
	@scripts/sparkle/fetch.sh
	@$(ENV) xcodegen generate --quiet
	@echo "Ready: make open (Xcode) or make run"

project: ## Regenerate MacHelper.xcodeproj after adding or removing files
	@$(ENV) xcodegen generate --quiet

open: setup ## Open the project in Xcode (build and run with ⌘R)
	@open $(PROJECT)

build: setup ## Build the app into build/ (CONFIGURATION=Debug by default)
	@mkdir -p build
	@$(ENV) xcodebuild -project $(PROJECT) -scheme MacHelper -configuration $(CONFIGURATION) \
		-derivedDataPath build $(XCODEBUILD_FLAGS) build > build/xcodebuild-$(CONFIGURATION).log 2>&1 \
		|| { grep -E "error:" build/xcodebuild-$(CONFIGURATION).log | sort -u | head -30; \
		     echo "Build failed; full log: build/xcodebuild-$(CONFIGURATION).log"; exit 1; }
	@echo "Built $(APP)"

run: ## Build and open the app from build/ (quit the installed copy first)
	@if pgrep -x MacHelper >/dev/null; then \
		echo "MacHelper is already running. Quit it first: both copies share settings and data."; exit 1; fi
	@$(MAKE) --no-print-directory build
	@open $(APP)

test: ## Run the unit tests of the Swift packages
	@$(ENV) swift test

install: ## Release build, replace /Applications/MacHelper.app and relaunch it
	@scripts/install.sh

release: ## Maintainers: make release ACTION=build|prepare|publish VERSION=x.y.z
	@test -n "$(ACTION)" -a -n "$(VERSION)" || { echo "usage: make release ACTION=build|prepare|publish VERSION=x.y.z"; exit 64; }
	@scripts/release.sh $(ACTION) $(VERSION)

clean: ## Remove build products (keeps the downloaded Sparkle and release archives)
	@rm -rf build/Build build/Logs build/ModuleCache.noindex build/Index.noindex build/xcodebuild-*.log .build
