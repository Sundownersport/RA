SHELL := /bin/bash

BUILD ?= build
PACKAGE_NAME := RetroArch.pak
PACKAGE_ROOT := $(BUILD)/package
PACKAGE_DIR := $(PACKAGE_ROOT)/$(PACKAGE_NAME)
WORKSPACE_ROOT ?= $(abspath ..)
JAWAKA_SDCARD_ROOT ?= $(WORKSPACE_ROOT)/Jawaka/mock-sdcard
SDCARD_PATH ?= $(JAWAKA_SDCARD_ROOT)
APPS_PATH ?= $(SDCARD_PATH)/Apps

.PHONY: package package-native package-platform package-mlp1 install-jawaka-app adb-stage-pak-mlp1 clean

package package-native package-mlp1:
	@rm -rf "$(PACKAGE_ROOT)"
	@mkdir -p "$(PACKAGE_DIR)"
	@cp -f "pak/launch.sh" "$(PACKAGE_DIR)/launch.sh"
	@cp -f "pak/pak.json" "$(PACKAGE_DIR)/pak.json"
	@chmod 755 "$(PACKAGE_DIR)/launch.sh"
	@find "$(PACKAGE_DIR)" -maxdepth 2 -type f -print | sort

package-platform:
	@test -n "$(PLATFORM)" || { echo "usage: make package-platform PLATFORM=<platform>" >&2; exit 1; }
	@case "$(PLATFORM)" in \
		mlp1|mac|tg5040|tg5050|my355) $(MAKE) package-mlp1 ;; \
		*) echo "unsupported RetroArch pak platform: $(PLATFORM)" >&2; exit 1 ;; \
	esac

install-jawaka-app: package-native
	@mkdir -p "$(APPS_PATH)/shared"
	@rm -rf "$(APPS_PATH)/shared/$(PACKAGE_NAME)"
	@cp -R "$(PACKAGE_DIR)" "$(APPS_PATH)/shared/$(PACKAGE_NAME)"
	@echo "Installed $(PACKAGE_NAME) to $(APPS_PATH)/shared"

adb-stage-pak-mlp1: package-mlp1
	scripts/adb-stage-pak.sh

clean:
	rm -rf "$(BUILD)"
