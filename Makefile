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
CFLAGS = -Wall -Wextra -O2 \
    -fobjc-arc \
    -isysroot $(SDKROOT) \
    -iframework $(SDKROOT)/System/Library/Frameworks \
    -F/System/Library/PrivateFrameworks \
    -Isrc -Isrc/ZKSwizzle
ARCHS = -arch x86_64 -arch arm64 -arch arm64e
FRAMEWORK_PATH = $(SDKROOT)/System/Library/Frameworks
PRIVATE_FRAMEWORK_PATH = $(SDKROOT)/System/Library/PrivateFrameworks
PUBLIC_FRAMEWORKS = -framework Foundation -framework AppKit -framework QuartzCore -framework Cocoa \
    -framework CoreFoundation

# Project name and paths
PROJECT = hiddengem
DYLIB_NAME = lib$(PROJECT).dylib
BUILD_DIR = build
SOURCE_DIR = src
INSTALL_DIR = /var/ammonia/core/tweaks

# Source files
DYLIB_SOURCES = $(SOURCE_DIR)/lostnfound.m $(SOURCE_DIR)/ZKSwizzle/ZKSwizzle.m
DYLIB_OBJECTS = $(DYLIB_SOURCES:%.m=$(BUILD_DIR)/%.o)

# Installation targets
INSTALL_PATH = $(INSTALL_DIR)/$(DYLIB_NAME)
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

# Default target - build the dylib
all: $(BUILD_DIR)/$(DYLIB_NAME)

# Explicit build target (same as all)
compile: $(BUILD_DIR)/$(DYLIB_NAME)

# Create build directory and subdirectories
$(BUILD_DIR):
	@mkdir -p $(BUILD_DIR)
	@mkdir -p $(BUILD_DIR)/src
	@mkdir -p $(BUILD_DIR)/src/ZKSwizzle

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
	@chmod -R 755 $(BUILD_DIR)
	@chown -R admin:admin $(BUILD_DIR) 2>/dev/null || true
	@echo "Build complete. Only $(DYLIB_NAME) remains in $(BUILD_DIR)/"

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
install: $(BUILD_DIR)/$(DYLIB_NAME)
	@echo "Installing dylib directly to $(INSTALL_DIR)"
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
	@echo "Force quitting Dock to reload tweak..."
	killall Dock 2>/dev/null || true
	@echo "Dock restarted with new tweak loaded"

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
# log show --predicate 'process == "Dock" AND eventMessage CONTAINS "HiddenGem"' --info --last 2m 