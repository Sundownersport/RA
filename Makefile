SHELL := /bin/bash

BUILD ?= build
PACKAGE_NAME := RetroArch.pak
PACKAGE_ROOT := $(BUILD)/package
PACKAGE_DIR := $(PACKAGE_ROOT)/$(PACKAGE_NAME)
JAWAKA_SDCARD_ROOT ?= /Volumes/Storage/UMRK/Jawaka/mock-sdcard

.PHONY: package package-native package-mlp1 install-jawaka-app adb-stage-pak-mlp1 clean

package package-native package-mlp1:
	@rm -rf "$(PACKAGE_ROOT)"
	@mkdir -p "$(PACKAGE_DIR)"
	@cp -f "pak/launch.sh" "$(PACKAGE_DIR)/launch.sh"
	@cp -f "pak/pak.json" "$(PACKAGE_DIR)/pak.json"
	@chmod 755 "$(PACKAGE_DIR)/launch.sh"
	@find "$(PACKAGE_DIR)" -maxdepth 2 -type f -print | sort

install-jawaka-app: package-native
	@mkdir -p "$(JAWAKA_SDCARD_ROOT)/Apps"
	@rm -rf "$(JAWAKA_SDCARD_ROOT)/Apps/$(PACKAGE_NAME)"
	@cp -R "$(PACKAGE_DIR)" "$(JAWAKA_SDCARD_ROOT)/Apps/$(PACKAGE_NAME)"
	@echo "Installed $(PACKAGE_NAME) to $(JAWAKA_SDCARD_ROOT)/Apps"

adb-stage-pak-mlp1: package-mlp1
	scripts/adb-stage-pak.sh

clean:
	rm -rf "$(BUILD)"
