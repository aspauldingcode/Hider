# Compiler and SDK settings
CC ?= $(shell which clang || echo clang)
CXX ?= $(shell which clang++ || echo clang++)

# SDK paths with fallback - only evaluate when building, not during install
ifdef MAKECMDGOALS
ifneq ($(filter build all compile installER install test,$(MAKECMDGOALS)),)
SDKROOT ?= $(shell xcrun --show-sdk-path 2>/dev/null || echo /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk)
endif
else
# Default case when no goals specified (make with no arguments = all)
SDKROOT ?= $(shell xcrun --show-sdk-path 2>/dev/null || echo /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk)
endif

# Compiler and flags
# -Werror: treat warnings as errors (strict compilation)
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
    -isysroot $(SDKROOT) \
    -iframework $(SDKROOT)/System/Library/Frameworks \
    -F/System/Library/PrivateFrameworks \
    -Isrc
ARCHS = -arch x86_64 -arch arm64 -arch arm64e
FRAMEWORK_PATH = $(SDKROOT)/System/Library/Frameworks
PRIVATE_FRAMEWORK_PATH = $(SDKROOT)/System/Library/PrivateFrameworks
PUBLIC_FRAMEWORKS = -framework Foundation -framework AppKit -framework QuartzCore -framework Cocoa \
    -framework CoreFoundation -framework ApplicationServices

# Project name and paths
PROJECT = hider
DYLIB_NAME = libHider.dylib
BUILD_DIR = build
SOURCE_DIR = src
INSTALL_DIR = /var/ammonia/core/tweaks

# Source files
DYLIB_SOURCES = $(SOURCE_DIR)/Hider.m
DYLIB_OBJECTS = $(DYLIB_SOURCES:%.m=$(BUILD_DIR)/%.o)

APP_SOURCES = $(SOURCE_DIR)/HiderApp.swift $(SOURCE_DIR)/SettingsManager.swift
APP_NAME = Hider
APP_BINARY = $(BUILD_DIR)/$(APP_NAME)
APP_ID = com.aspauldingcode.hider

# Installation targets
INSTALL_PATH = $(INSTALL_DIR)/$(DYLIB_NAME)
BIN_INSTALL_DIR = /usr/local/bin
BLACKLIST_SOURCE = lib$(PROJECT).dylib.blacklist
BLACKLIST_DEST = $(INSTALL_DIR)/lib$(PROJECT).dylib.blacklist

# Installer package settings
PKG_NAME = $(PROJECT)-installer
PKG_VERSION = 1.0.0
PKG_IDENTIFIER = com.$(PROJECT).installer
PKG_FILE = $(PKG_NAME).pkg
PKG_ROOT = $(BUILD_DIR)/pkg_root
PKG_SCRIPTS = $(BUILD_DIR)/pkg_scripts

# Dylib settings
DYLIB_FLAGS = -dynamiclib \
              -install_name @rpath/$(DYLIB_NAME) \
              -compatibility_version 1.0.0 \
              -current_version 1.0.0

# Default target - build the dylib and the app
# Default target - build the dylib and the app binary
all: $(BUILD_DIR)/$(DYLIB_NAME) $(APP_BINARY)

# Explicit build target
compile: all

# Create build directory and subdirectories
$(BUILD_DIR):
	@mkdir -p $(BUILD_DIR)
	@mkdir -p $(BUILD_DIR)/src

# Compile source files
$(BUILD_DIR)/%.o: %.m
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) $(ARCHS) -c $< -o $@

# Link dylib
$(BUILD_DIR)/$(DYLIB_NAME): $(DYLIB_OBJECTS) | $(BUILD_DIR)
	$(CC) $(DYLIB_FLAGS) $(ARCHS) $(DYLIB_OBJECTS) -o $@ \
	-F$(FRAMEWORK_PATH) \
	-F$(PRIVATE_FRAMEWORK_PATH) \
	$(PUBLIC_FRAMEWORKS) \
	-L$(SDKROOT)/usr/lib
	@echo "Cleaning intermediate build files..."
	@find $(BUILD_DIR) -name "*.o" -delete
	@find $(BUILD_DIR) -type d -empty -delete
	@echo "Build complete. Only $(DYLIB_NAME) remains in $(BUILD_DIR)/"

# Build SwiftUI App Binary
$(APP_BINARY): $(APP_SOURCES) | $(BUILD_DIR)
	@echo "Building SwiftUI Binary..."
	swiftc -sdk $(SDKROOT) $(APP_SOURCES) \
		-o $(APP_BINARY) \
		-emit-executable
	@echo "App binary build complete: $(APP_BINARY)"

# Create installer package
installER: $(BUILD_DIR)/$(DYLIB_NAME)
	@echo "Creating installer package..."
	@mkdir -p $(PKG_ROOT)$(INSTALL_DIR)
	@mkdir -p $(PKG_SCRIPTS)
	
	# Copy dylib to package root
	@cp $(BUILD_DIR)/$(DYLIB_NAME) $(PKG_ROOT)$(INSTALL_DIR)/
	@chmod 755 $(PKG_ROOT)$(INSTALL_DIR)/$(DYLIB_NAME)
	
	# Copy blacklist if it exists
	@if [ -f $(BLACKLIST_SOURCE) ]; then \
		cp $(BLACKLIST_SOURCE) $(PKG_ROOT)$(INSTALL_DIR)/; \
		chmod 644 $(PKG_ROOT)$(INSTALL_DIR)/$(BLACKLIST_SOURCE); \
	fi
	
	# Create postinstall script
	@echo '#!/bin/bash' > $(PKG_SCRIPTS)/postinstall
	@echo 'echo "$(PROJECT) tweak installed successfully"' >> $(PKG_SCRIPTS)/postinstall
	@echo 'echo "Restarting Dock to load tweak..."' >> $(PKG_SCRIPTS)/postinstall
	@echo 'killall Dock 2>/dev/null || true' >> $(PKG_SCRIPTS)/postinstall
	@echo 'exit 0' >> $(PKG_SCRIPTS)/postinstall
	@chmod +x $(PKG_SCRIPTS)/postinstall
	
	# Build the package
	@pkgbuild --root $(PKG_ROOT) \
		--scripts $(PKG_SCRIPTS) \
		--identifier $(PKG_IDENTIFIER) \
		--version $(PKG_VERSION) \
		--install-location / \
		$(PKG_FILE)
	
	@chmod 755 $(PKG_FILE)
	@echo "Installer package created: $(PKG_FILE)"

# Install by compiling first and then installing directly
install: all
	@echo "Installing dylib directly to $(INSTALL_DIR)"
	# Create the target directory.
	sudo mkdir -p $(INSTALL_DIR)
	# Install the tweak's dylib where injection takes place.
	sudo install -m 755 $(BUILD_DIR)/$(DYLIB_NAME) $(INSTALL_DIR)
	@echo "Installing Hider binary to $(BIN_INSTALL_DIR)"
	sudo mkdir -p $(BIN_INSTALL_DIR)
	sudo install -m 755 $(APP_BINARY) $(BIN_INSTALL_DIR)
	@if [ -f $(BLACKLIST_SOURCE) ]; then \
		sudo cp $(BLACKLIST_SOURCE) $(BLACKLIST_DEST); \
		sudo chmod 644 $(BLACKLIST_DEST); \
		echo "Installed $(DYLIB_NAME) and blacklist"; \
	else \
		echo "Warning: $(BLACKLIST_SOURCE) not found"; \
		echo "Installed $(DYLIB_NAME)"; \
	fi
	@echo "Force quitting Dock to reload tweak..."
	sudo killall Dock 2>/dev/null || true

# Test target that compiles, installs, and kills dock for testing
test: $(BUILD_DIR)/$(DYLIB_NAME)
	@echo "Installing dylib for testing..."
	# Create the target directory.
	sudo mkdir -p $(INSTALL_DIR)
	# Install the tweak's dylib where injection takes place.
	sudo install -m 755 $(BUILD_DIR)/$(DYLIB_NAME) $(INSTALL_DIR)
	@if [ -f $(BLACKLIST_SOURCE) ]; then \
		sudo cp $(BLACKLIST_SOURCE) $(BLACKLIST_DEST); \
		sudo chmod 644 $(BLACKLIST_DEST); \
		echo "Installed $(DYLIB_NAME) and blacklist"; \
	else \
		echo "Warning: $(BLACKLIST_SOURCE) not found"; \
		echo "Installed $(DYLIB_NAME)"; \
	fi
	@echo "Clearing previous log file..."
	@rm -f /tmp/hider.log
	@echo "Force quitting Dock to reload tweak..."
	killall Dock 2>/dev/null || true
	@sleep 1
	@echo "Dock restarted with new tweak loaded"
	@echo ""
	@echo "=== Tailing /tmp/hider.log ==="
	@if [ -f /tmp/hider.log ]; then \
		echo "Showing existing log content:"; \
		cat /tmp/hider.log; \
		echo ""; \
		echo "Tailing log file (Ctrl+C to stop)..."; \
		tail -f /tmp/hider.log; \
	else \
		echo "Log file not found yet. Waiting 2 seconds and trying again..."; \
		sleep 2; \
		if [ -f /tmp/hider.log ]; then \
			echo "Showing existing log content:"; \
			cat /tmp/hider.log; \
			echo ""; \
			echo "Tailing log file (Ctrl+C to stop)..."; \
			tail -f /tmp/hider.log; \
		else \
			echo "Log file still not found. Dock may not have loaded the tweak yet."; \
			echo "Check /tmp/hider.log manually or restart Dock again."; \
		fi \
	fi

# Clean build files
clean:
	@rm -rf $(BUILD_DIR)
	@echo "Cleaned build directory"

# Delete installed files
delete:
	@echo "Force quitting Dock..."
	killall Dock 2>/dev/null || true
	@sudo rm -f $(INSTALL_PATH)
	@sudo rm -f $(BLACKLIST_DEST)
	@echo "Deleted $(DYLIB_NAME) and blacklist from $(INSTALL_DIR)"

# Uninstall
uninstall:
	@echo "Force quitting Dock..."
	killall Dock 2>/dev/null || true
	@sudo rm -f $(INSTALL_PATH)
	@sudo rm -f $(BLACKLIST_DEST)
	@echo "Uninstalled $(DYLIB_NAME) and blacklist"

.PHONY: all clean install installER test delete uninstall compile


# verbose test
## log show --predicate 'process == "Dock"' --info --last 2m | tail -30
# log show --predicate 'process == "Dock" AND eventMessage CONTAINS "Hider"' --info --last 2m