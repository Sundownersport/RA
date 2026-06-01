SHELL := /bin/bash

BUILD ?= build
PACKAGE_NAME := RetroArch.pak
PACKAGE_ROOT := $(BUILD)/package
PACKAGE_DIR := $(PACKAGE_ROOT)/$(PACKAGE_NAME)
WORKSPACE_ROOT ?= $(abspath ..)
JAWAKA_SDCARD_ROOT ?= $(WORKSPACE_ROOT)/Jawaka/mock-sdcard
SDCARD_PATH ?= $(JAWAKA_SDCARD_ROOT)
APPS_PATH ?= $(SDCARD_PATH)/Apps

.PHONY: package package-native package-mlp1 install-jawaka-app adb-stage-pak-mlp1 clean

package package-native package-mlp1:
	@rm -rf "$(PACKAGE_ROOT)"
	@mkdir -p "$(PACKAGE_DIR)"
	@cp -f "pak/launch.sh" "$(PACKAGE_DIR)/launch.sh"
	@cp -f "pak/pak.json" "$(PACKAGE_DIR)/pak.json"
	@chmod 755 "$(PACKAGE_DIR)/launch.sh"
	@find "$(PACKAGE_DIR)" -maxdepth 2 -type f -print | sort

install-jawaka-app: package-native
	@mkdir -p "$(APPS_PATH)"
	@rm -rf "$(APPS_PATH)/$(PACKAGE_NAME)"
	@cp -R "$(PACKAGE_DIR)" "$(APPS_PATH)/$(PACKAGE_NAME)"
	@echo "Installed $(PACKAGE_NAME) to $(APPS_PATH)"

adb-stage-pak-mlp1: package-mlp1
	scripts/adb-stage-pak.sh

clean:
	rm -rf "$(BUILD)"
