# GMApplePlayer, build / test / run / install shortcuts
#
# Quick start:
#   make ffmpeg            # build the FFmpeg xcframework (once)
#   make generate          # regenerate the Xcode project from project.yml
#   make mac               # build + run the macOS app (Debug)
#   make help              # list every target
#
# Most targets accept CONFIG=Debug|Release (default Debug) and, where relevant,
# DEVICE=... / SIM=... overrides. Examples:
#   make mac CONFIG=Release
#   make ios-sim SIM="iPhone 16 Pro"
#   make tvos-device DEVICE="Living Room" TEAM=XXXXXXXXXX

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
PROJECT      := GMApplePlayer.xcodeproj
SCHEME_MAC   := GMApplePlayer-macOS
SCHEME_IOS   := GMApplePlayer-iOS
SCHEME_TVOS  := GMApplePlayer-tvOS
PKG          := Packages/GMPlayerKit
CONFIG       ?= Debug
BUNDLE_ID    := com.gm.appleplayer
DERIVED      := $(HOME)/Library/Developer/Xcode/DerivedData

# Default simulators (override on the CLI). tvOS sim name is matched loosely.
SIM          ?= iPhone 16 Pro
TVSIM        ?= Apple TV 4K (3rd generation)
# Physical device name as shown by `xcrun devicectl` / Xcode (override for yours)
DEVICE       ?= Apple TV
# Apple Developer Team ID for device signing (set yours: make tvos-device TEAM=XXXXXXXXXX).
TEAM         ?=

XCPRETTY     := $(shell command -v xcbeautify >/dev/null 2>&1 && echo "| xcbeautify" || echo "")
COMMON_FLAGS := -project $(PROJECT) -configuration $(CONFIG) CODE_SIGNING_ALLOWED=NO
SIM_ARCH     := ARCHS=arm64 ONLY_ACTIVE_ARCH=YES
# FFmpeg.xcframework ships only an arm64 macOS slice, so pin the Mac build to
# arm64 (Release would otherwise also try x86_64 and fail to link).
MAC_ARCH     := ARCHS=arm64

.DEFAULT_GOAL := help

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
.PHONY: ffmpeg ffmpeg-mac generate bootstrap icons
ffmpeg: ## Build the full FFmpeg xcframework (all Apple slices)
	./Scripts/build-ffmpeg.sh

icons: ## Regenerate app icons for all platforms from assets/GMPlayerIcon.png
	./Scripts/make-icons.sh

ffmpeg-mac: ## Build only the macOS FFmpeg slice (fast dev loop)
	./Scripts/build-ffmpeg.sh macos

generate: ## Regenerate the Xcode project from project.yml (xcodegen)
	xcodegen generate

bootstrap: ffmpeg icons generate ## First-time setup: build FFmpeg + icons + generate project

# ---------------------------------------------------------------------------
# Build (compile only)
# ---------------------------------------------------------------------------
.PHONY: build-mac build-ios build-tvos build-all
build-mac: ## Build the macOS app
	xcodebuild $(COMMON_FLAGS) $(MAC_ARCH) -scheme $(SCHEME_MAC) -destination 'platform=macOS' build $(XCPRETTY)

build-ios: ## Build the iOS app for the simulator
	xcodebuild $(COMMON_FLAGS) -scheme $(SCHEME_IOS) -destination 'generic/platform=iOS Simulator' $(SIM_ARCH) build $(XCPRETTY)

build-tvos: ## Build the tvOS app for the simulator
	xcodebuild $(COMMON_FLAGS) -scheme $(SCHEME_TVOS) -destination 'generic/platform=tvOS Simulator' $(SIM_ARCH) build $(XCPRETTY)

build-all: build-mac build-ios build-tvos ## Build all three platforms

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
.PHONY: mac ios-sim tvos-sim run-mac
mac: build-mac run-mac ## Build + launch the macOS app

run-mac: ## Launch the already-built macOS app (pass FILE=/path to auto-open)
	@./Scripts/run-app.sh mac $(CONFIG) "$(FILE)"

ios-sim: ## Build, install & launch on the iOS simulator (SIM="iPhone 16 Pro")
	xcodebuild $(COMMON_FLAGS) -scheme $(SCHEME_IOS) -destination 'platform=iOS Simulator,name=$(SIM)' $(SIM_ARCH) build $(XCPRETTY)
	@./Scripts/run-app.sh ios $(CONFIG) "$(SIM)" "$(FILE)"

tvos-sim: ## Build, install & launch on the tvOS simulator
	xcodebuild $(COMMON_FLAGS) -scheme $(SCHEME_TVOS) -destination 'platform=tvOS Simulator,name=$(TVSIM)' $(SIM_ARCH) build $(XCPRETTY)
	@./Scripts/run-app.sh tvos $(CONFIG) "$(TVSIM)"

# ---------------------------------------------------------------------------
# Install on physical devices (requires code signing; set TEAM=XXXXXXXXXX)
# ---------------------------------------------------------------------------
.PHONY: devices ios-device tvos-device
devices: ## List connected physical devices
	xcrun devicectl list devices 2>/dev/null || xcrun xctrace list devices

ios-device: ## Build (signed) + install on a connected iPhone (override DEVICE=, TEAM=)
	xcodebuild -project $(PROJECT) -scheme $(SCHEME_IOS) -configuration $(CONFIG) \
		-destination 'generic/platform=iOS' DEVELOPMENT_TEAM=$(TEAM) \
		-allowProvisioningUpdates CODE_SIGN_STYLE=Automatic \
		-derivedDataPath build/dd-ios build $(XCPRETTY)
	xcrun devicectl device install app --device "$(DEVICE)" \
		build/dd-ios/Build/Products/$(CONFIG)-iphoneos/$(SCHEME_IOS).app

tvos-device: ## Build (signed) + install on a connected Apple TV (DEVICE="Living Room")
	xcodebuild -project $(PROJECT) -scheme $(SCHEME_TVOS) -configuration $(CONFIG) \
		-destination 'generic/platform=tvOS' DEVELOPMENT_TEAM=$(TEAM) \
		-allowProvisioningUpdates CODE_SIGN_STYLE=Automatic \
		-derivedDataPath build/dd-tvos build $(XCPRETTY)
	xcrun devicectl device install app --device "$(DEVICE)" \
		build/dd-tvos/Build/Products/$(CONFIG)-appletvos/$(SCHEME_TVOS).app

tvos-launch: ## Launch the installed app on the Apple TV (DEVICE=..., wake it first; URL=... optional)
	@if [ -n "$(URL)" ]; then \
		xcrun devicectl device process launch --device "$(DEVICE)" $(BUNDLE_ID).tvos --arguments "--open $(URL)"; \
	else \
		xcrun devicectl device process launch --device "$(DEVICE)" $(BUNDLE_ID).tvos; \
	fi

# ---------------------------------------------------------------------------
# Test
# ---------------------------------------------------------------------------
.PHONY: test test-pkg test-mac
test: test-pkg ## Run all tests (currently the GMPlayerKit package tests)

test-pkg: ## Run the Swift package unit tests
	cd $(PKG) && swift test

test-mac: ## Run the macOS app's test bundle via xcodebuild
	xcodebuild $(COMMON_FLAGS) $(MAC_ARCH) -scheme $(SCHEME_MAC) -destination 'platform=macOS' test $(XCPRETTY)

# ---------------------------------------------------------------------------
# Lint / format
# ---------------------------------------------------------------------------
.PHONY: lint fmt
lint: ## Run SwiftLint + SwiftFormat (lint mode)
	./Scripts/lint.sh

fmt: ## Auto-format Swift sources (SwiftFormat write mode)
	./Scripts/lint.sh --fix || swiftformat Sources $(PKG)/Sources/GMPlayerKit $(PKG)/Sources/gmremux-cli

# ---------------------------------------------------------------------------
# Engine CLI (headless remux harness)
# ---------------------------------------------------------------------------
.PHONY: cli remux
cli: ## Build the gmremux-cli tool
	cd $(PKG) && swift build --product gmremux-cli

remux: ## Remux a file with the engine: make remux IN=movie.mkv OUT=out.mp4
	cd $(PKG) && swift run gmremux-cli "$(IN)" "$(OUT)"

# ---------------------------------------------------------------------------
# Housekeeping
# ---------------------------------------------------------------------------
.PHONY: clean distclean help
clean: ## Remove build artifacts (keeps the FFmpeg xcframework)
	rm -rf build/dd-ios build/dd-tvos $(PKG)/.build
	xcodebuild $(COMMON_FLAGS) -scheme $(SCHEME_MAC) clean >/dev/null 2>&1 || true

distclean: clean ## Also remove the FFmpeg build tree + xcframework + generated project
	rm -rf build $(PKG)/Frameworks/FFmpeg.xcframework $(PROJECT)

help: ## Show this help
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
