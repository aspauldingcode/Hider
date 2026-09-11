# Hider — Dock tweak for Plugin Playground (macOS Sequoia 15 → latest).

CC ?= $(shell which clang || echo clang)
CXX ?= $(shell which clang++ || echo clang++)

SDKROOT ?= $(shell xcrun --show-sdk-path 2>/dev/null || echo /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk)

CFLAGS = -Wall -Wextra -Werror \
    -Wstrict-prototypes \
    -Wmissing-prototypes \
    -Wstrict-aliasing=2 \
    -Wcast-align \
    -Wconversion \
    -Wsign-conversion \
    -Wfloat-equal \
    -Wshadow \
    -Wunused \
    -Wunused-parameter \
    -Wunused-variable \
    -Wunused-function \
    -Wpedantic \
    -Wextra-semi \
    -Wnullability-completeness \
    -Wobjc-method-access \
    -Wstrict-selector-match \
    -Wundeclared-selector \
    -Wdeprecated-implementations \
    -Wgnu-zero-variadic-macro-arguments \
    -Wformat-pedantic \
    -Wdollar-in-identifier-extension \
    -Wlanguage-extension-token \
    -Wgnu-pointer-arith \
    -O2 \
    -fobjc-arc \
    -mmacosx-version-min=15.0 \
    -isysroot $(SDKROOT) \
    -iframework $(SDKROOT)/System/Library/Frameworks \
    -F/System/Library/PrivateFrameworks \
    -Isrc

ARCHS = -arch x86_64 -arch arm64 -arch arm64e
FRAMEWORK_PATH = $(SDKROOT)/System/Library/Frameworks
PRIVATE_FRAMEWORK_PATH = $(SDKROOT)/System/Library/PrivateFrameworks
PUBLIC_FRAMEWORKS = -framework Foundation -framework AppKit -framework QuartzCore -framework Cocoa \
    -framework CoreFoundation -framework ApplicationServices

PROJECT = hider
DYLIB_NAME = libHider.dylib
BUILD_DIR = build
SOURCE_DIR = src

# Plugin Playground only (Sequoia → latest).
INSTALL_DIR = /opt/pluginplayground/tweaks
PP_OPTIONS = /opt/pluginplayground/current.options
LEGACY_AMMONIA_TWEAKS = /var/ammonia/core/tweaks

DYLIB_SOURCES = $(SOURCE_DIR)/Hider.m
DYLIB_OBJECTS = $(DYLIB_SOURCES:%.m=$(BUILD_DIR)/%.o)

APP_NAME = Hider
APP_ID = com.aspauldingcode.hider
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
APP_BINARY = $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
CLI_BINARY = $(BUILD_DIR)/hiderctl
SWIFT_RELEASE_DIR = .build/release
SWIFT_BUILD_STAMP = $(BUILD_DIR)/.swift-release.stamp
SWIFT_SOURCES = Package.swift $(shell find Sources src Tests -type f \( -name '*.swift' -o -name '*.c' -o -name '*.h' \) 2>/dev/null)
SWIFT_BUILD_ENV = CLANG_MODULE_CACHE_PATH=$(CURDIR)/.build/clang-module-cache \
	SWIFTPM_MODULECACHE_OVERRIDE=$(CURDIR)/.build/swiftpm-module-cache
SWIFT_BUILD_FLAGS ?= --disable-sandbox -debug-info-format none

INSTALL_PATH = $(INSTALL_DIR)/$(DYLIB_NAME)
BIN_INSTALL_DIR = /usr/local/bin
APP_INSTALL_DIR = /Applications
WHITELIST_SOURCE = libHider.dylib.whitelist
WHITELIST_DEST = $(INSTALL_DIR)/$(WHITELIST_SOURCE)
OPTIONS_SOURCE = libHider.dylib.options
OPTIONS_DEST = $(INSTALL_DIR)/$(OPTIONS_SOURCE)
LAUNCH_AGENT_PLIST = com.aspauldingcode.hider.plist
LAUNCH_AGENT_DEST = $(HOME)/Library/LaunchAgents/$(LAUNCH_AGENT_PLIST)

PKG_NAME = $(PROJECT)-installer
PKG_VERSION = 1.0.0
PKG_IDENTIFIER = com.aspauldingcode.hider.installer
PKG_FILE = $(PKG_NAME).pkg
PKG_ROOT = $(BUILD_DIR)/pkg_root
PKG_SCRIPTS = $(BUILD_DIR)/pkg_scripts
PKG_MIN_OS = 15.0

DYLIB_FLAGS = -dynamiclib \
              -install_name @rpath/$(DYLIB_NAME) \
              -compatibility_version 1.0.0 \
              -current_version 1.0.0 \
              -undefined dynamic_lookup

.PHONY: all clean install installER test delete uninstall compile info ensure-pp-options

all: $(BUILD_DIR)/$(DYLIB_NAME) $(APP_BUNDLE) $(CLI_BINARY)

compile: all

info:
	@echo "Injector:    Plugin Playground"
	@echo "Tweaks dir:  $(INSTALL_DIR)"
	@echo "Min macOS:   Sequoia ($(PKG_MIN_OS))+ "

$(BUILD_DIR):
	@mkdir -p $(BUILD_DIR)
	@mkdir -p $(BUILD_DIR)/src

$(BUILD_DIR)/%.o: %.m
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) $(ARCHS) -c $< -o $@

$(BUILD_DIR)/$(DYLIB_NAME): $(DYLIB_OBJECTS) | $(BUILD_DIR)
	$(CC) $(DYLIB_FLAGS) $(ARCHS) $(DYLIB_OBJECTS) -o $@ \
	-F$(FRAMEWORK_PATH) \
	-F$(PRIVATE_FRAMEWORK_PATH) \
	$(PUBLIC_FRAMEWORKS) \
	-L$(SDKROOT)/usr/lib
	@find $(BUILD_DIR) -name "*.o" -delete
	@find $(BUILD_DIR) -type d -empty -delete 2>/dev/null || true
	@echo "Dylib build complete: $@"

$(SWIFT_BUILD_STAMP): $(SWIFT_SOURCES) | $(BUILD_DIR)
	$(SWIFT_BUILD_ENV) swift build -c release $(SWIFT_BUILD_FLAGS)
	@touch $@

$(APP_BUNDLE): $(SWIFT_BUILD_STAMP)
	@echo "Assembling Hider.app..."
	@rm -rf $@
	@mkdir -p $@/Contents/MacOS
	@cp $(SWIFT_RELEASE_DIR)/HiderApp $(APP_BINARY)
	@plutil -create xml1 $@/Contents/Info.plist
	@plutil -insert CFBundleExecutable -string Hider $@/Contents/Info.plist
	@plutil -insert CFBundleIdentifier -string $(APP_ID) $@/Contents/Info.plist
	@plutil -insert CFBundleName -string Hider $@/Contents/Info.plist
	@plutil -insert CFBundlePackageType -string APPL $@/Contents/Info.plist
	@plutil -insert CFBundleShortVersionString -string 1.0.0 $@/Contents/Info.plist
	@plutil -insert CFBundleVersion -string 1 $@/Contents/Info.plist
	@plutil -insert LSMinimumSystemVersion -string $(PKG_MIN_OS) $@/Contents/Info.plist
	@plutil -lint $@/Contents/Info.plist
	@codesign --force --sign - $@

$(CLI_BINARY): $(SWIFT_BUILD_STAMP)
	@cp $(SWIFT_RELEASE_DIR)/hiderctl $@
	@chmod 755 $@

# Ensure Plugin Playground options exist (disablePAC for stock arm64 fangs).
ensure-pp-options:
	@sudo mkdir -p /opt/pluginplayground
	@if [ ! -f $(PP_OPTIONS) ]; then sudo plutil -create xml1 $(PP_OPTIONS); fi
	@sudo plutil -replace disablePAC -bool true $(PP_OPTIONS) 2>/dev/null || \
		sudo plutil -insert disablePAC -bool true $(PP_OPTIONS)
	@sudo chmod 666 $(PP_OPTIONS) 2>/dev/null || true
	@echo "Plugin Playground options: disablePAC=true ($(PP_OPTIONS))"

# Distribution package for Sequoia → latest. Installs the tweak into the PP
# tweaks folder, Hider.app, hiderctl, and a login LaunchAgent. postinstall
# enables disablePAC, removes any leftover Ammonia copy of Hider, and restarts Dock.
installER: all
	@echo "Creating Plugin Playground installer package (macOS $(PKG_MIN_OS)+)..."
	@rm -rf $(PKG_ROOT) $(PKG_SCRIPTS)
	@mkdir -p $(PKG_ROOT)$(INSTALL_DIR)
	@mkdir -p $(PKG_ROOT)$(APP_INSTALL_DIR)
	@mkdir -p $(PKG_ROOT)$(BIN_INSTALL_DIR)
	@mkdir -p $(PKG_ROOT)/Library/LaunchAgents
	@mkdir -p $(PKG_SCRIPTS)
	@cp $(BUILD_DIR)/$(DYLIB_NAME) $(PKG_ROOT)$(INSTALL_DIR)/
	@chmod 755 $(PKG_ROOT)$(INSTALL_DIR)/$(DYLIB_NAME)
	@cp $(WHITELIST_SOURCE) $(PKG_ROOT)$(INSTALL_DIR)/
	@chmod 644 $(PKG_ROOT)$(INSTALL_DIR)/$(WHITELIST_SOURCE)
	@cp $(OPTIONS_SOURCE) $(PKG_ROOT)$(INSTALL_DIR)/
	@chmod 644 $(PKG_ROOT)$(INSTALL_DIR)/$(OPTIONS_SOURCE)
	@cp -R $(APP_BUNDLE) $(PKG_ROOT)$(APP_INSTALL_DIR)/$(APP_NAME).app
	@install -m 755 $(APP_BINARY) $(PKG_ROOT)$(BIN_INSTALL_DIR)/hider
	@install -m 755 $(APP_BINARY) $(PKG_ROOT)$(BIN_INSTALL_DIR)/Hider
	@install -m 755 $(CLI_BINARY) $(PKG_ROOT)$(BIN_INSTALL_DIR)/hiderctl
	@cp $(LAUNCH_AGENT_PLIST) $(PKG_ROOT)/Library/LaunchAgents/$(LAUNCH_AGENT_PLIST)
	@printf '%s\n' \
		'#!/bin/bash' \
		'set -e' \
		'echo "Hider: configuring Plugin Playground…"' \
		'mkdir -p /opt/pluginplayground' \
		'OPTIONS=/opt/pluginplayground/current.options' \
		'if [ ! -f "$$OPTIONS" ]; then plutil -create xml1 "$$OPTIONS"; fi' \
		'plutil -replace disablePAC -bool true "$$OPTIONS" 2>/dev/null \' \
		'  || plutil -insert disablePAC -bool true "$$OPTIONS"' \
		'chmod 666 "$$OPTIONS" 2>/dev/null || true' \
		'# Drop any leftover Ammonia copy so Dock is not double-injected.' \
		'rm -f /var/ammonia/core/tweaks/libHider.dylib \' \
		'      /var/ammonia/core/tweaks/libHider.dylib.whitelist \' \
		'      /var/ammonia/core/tweaks/libhider.dylib.whitelist \' \
		'      /var/ammonia/core/tweaks/libHider.dylib.options 2>/dev/null || true' \
		'printf 1 > /tmp/hider-intentional-restart' \
		'killall Dock 2>/dev/null || true' \
		'echo "Hider installed for Plugin Playground (Sequoia → latest)."' \
		'exit 0' > $(PKG_SCRIPTS)/postinstall
	@chmod +x $(PKG_SCRIPTS)/postinstall
	@pkgbuild --root $(PKG_ROOT) \
		--scripts $(PKG_SCRIPTS) \
		--identifier $(PKG_IDENTIFIER) \
		--version $(PKG_VERSION) \
		--install-location / \
		--min-os-version $(PKG_MIN_OS) \
		$(PKG_FILE)
	@chmod 755 $(PKG_FILE)
	@echo "Installer package created: $(PKG_FILE)"
	@echo "Requires Plugin Playground on the target Mac (macOS Sequoia 15+)."

install: all ensure-pp-options
	@echo "Installing dylib → $(INSTALL_DIR)"
	sudo mkdir -p $(INSTALL_DIR)
	sudo install -m 755 $(BUILD_DIR)/$(DYLIB_NAME) $(INSTALL_DIR)/$(DYLIB_NAME)
	sudo cp $(WHITELIST_SOURCE) $(WHITELIST_DEST)
	sudo chmod 644 $(WHITELIST_DEST)
	sudo cp $(OPTIONS_SOURCE) $(OPTIONS_DEST)
	sudo chmod 644 $(OPTIONS_DEST)
	@echo "Installed whitelist + options"
	@# Avoid double-injection if an old Ammonia copy remains.
	-@sudo rm -f $(LEGACY_AMMONIA_TWEAKS)/libHider.dylib \
		$(LEGACY_AMMONIA_TWEAKS)/libHider.dylib.whitelist \
		$(LEGACY_AMMONIA_TWEAKS)/libhider.dylib.whitelist \
		$(LEGACY_AMMONIA_TWEAKS)/libHider.dylib.options
	@echo "Installing Hider.app → $(APP_INSTALL_DIR)"
	sudo rm -rf $(APP_INSTALL_DIR)/$(APP_NAME).app
	sudo cp -R $(APP_BUNDLE) $(APP_INSTALL_DIR)/$(APP_NAME).app
	@echo "Installing CLI tools → $(BIN_INSTALL_DIR)"
	sudo mkdir -p $(BIN_INSTALL_DIR)
	sudo install -m 755 $(APP_BINARY) $(BIN_INSTALL_DIR)/hider
	sudo install -m 755 $(APP_BINARY) $(BIN_INSTALL_DIR)/Hider
	sudo install -m 755 $(CLI_BINARY) $(BIN_INSTALL_DIR)/hiderctl
	@echo "Installing launch agent → $(LAUNCH_AGENT_DEST)"
	@mkdir -p $(HOME)/Library/LaunchAgents
	@cp $(LAUNCH_AGENT_PLIST) $(LAUNCH_AGENT_DEST)
	@launchctl bootout gui/$$(id -u) $(LAUNCH_AGENT_DEST) 2>/dev/null || true
	@launchctl bootstrap gui/$$(id -u) $(LAUNCH_AGENT_DEST) 2>/dev/null || \
		launchctl load $(LAUNCH_AGENT_DEST) 2>/dev/null || true
	@echo "Restarting Dock to load tweak..."
	@printf '1' > /tmp/hider-intentional-restart
	sudo killall -9 Dock 2>/dev/null || true
	@echo "Done. Open Hider.app or run: hiderctl status"

test:
	$(SWIFT_BUILD_ENV) swift test $(SWIFT_BUILD_FLAGS)

clean:
	@rm -rf $(BUILD_DIR) .build $(PKG_FILE)
	@echo "Cleaned build directory"

delete uninstall:
	@echo "Uninstalling Hider..."
	killall Dock 2>/dev/null || true
	@launchctl bootout gui/$$(id -u) $(LAUNCH_AGENT_DEST) 2>/dev/null || true
	@launchctl unload $(LAUNCH_AGENT_DEST) 2>/dev/null || true
	@rm -f $(LAUNCH_AGENT_DEST)
	-@sudo rm -f $(INSTALL_DIR)/$(DYLIB_NAME) $(WHITELIST_DEST) $(OPTIONS_DEST)
	-@sudo rm -f $(LEGACY_AMMONIA_TWEAKS)/libHider.dylib \
		$(LEGACY_AMMONIA_TWEAKS)/libHider.dylib.whitelist \
		$(LEGACY_AMMONIA_TWEAKS)/libhider.dylib.whitelist \
		$(LEGACY_AMMONIA_TWEAKS)/libHider.dylib.options
	-@sudo rm -f $(BIN_INSTALL_DIR)/hider $(BIN_INSTALL_DIR)/Hider $(BIN_INSTALL_DIR)/hiderctl
	-@sudo rm -rf $(APP_INSTALL_DIR)/$(APP_NAME).app
	@echo "Uninstalled."
	@printf '1' > /tmp/hider-intentional-restart
	sudo killall -9 Dock 2>/dev/null || true
