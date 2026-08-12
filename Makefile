SHELL := /bin/bash

BUILD ?= build
PACKAGE_NAME := RetroArch.pak
PACKAGE_ROOT := $(BUILD)/package
PACKAGE_DIR := $(PACKAGE_ROOT)/$(PACKAGE_NAME)
PYTHON ?= python3
MLP1_SHADER_TOOL := scripts/mlp1_shader_bundle.py
MLP1_SHADER_OUTPUT ?= output/mlp1/shaders
MLP1_ASSET_TOOL := scripts/mlp1_asset_bundle.py
MLP1_ASSET_OUTPUT ?= output/mlp1/assets
WORKSPACE_ROOT ?= $(abspath ..)
JAWAKA_SDCARD_ROOT ?= $(WORKSPACE_ROOT)/Jawaka/mock-sdcard
SDCARD_PATH ?= $(JAWAKA_SDCARD_ROOT)
APPS_PATH ?= $(SDCARD_PATH)/Apps

.PHONY: package package-native package-platform package-mlp1 install-jawaka-app adb-stage-pak-mlp1 shaders-mlp1 validate-shaders-mlp1 test-shaders-mlp1 smoke-shaders-mlp1 performance-shader-mlp1 qualify-shader-recommendations-mlp1 qualify-shader-expansion-mlp1 assets-mlp1 validate-assets-mlp1 test-assets-mlp1 clean

shaders-mlp1:
	$(PYTHON) "$(MLP1_SHADER_TOOL)" build --output "$(MLP1_SHADER_OUTPUT)"

assets-mlp1:
	$(PYTHON) "$(MLP1_ASSET_TOOL)" build --output "$(MLP1_ASSET_OUTPUT)"

validate-assets-mlp1:
	$(PYTHON) "$(MLP1_ASSET_TOOL)" validate --output "$(MLP1_ASSET_OUTPUT)"

test-assets-mlp1:
	$(PYTHON) -m unittest discover -s scripts -p 'test_mlp1_asset_bundle.py'

validate-shaders-mlp1:
	$(PYTHON) "$(MLP1_SHADER_TOOL)" validate --output "$(MLP1_SHADER_OUTPUT)"

test-shaders-mlp1:
	$(PYTHON) -m unittest discover -s scripts -p 'test_mlp1_shader_bundle.py'

smoke-shaders-mlp1:
	./smoke-mlp1-shaders.sh

performance-shader-mlp1:
	./performance-mlp1-shader.sh

qualify-shader-recommendations-mlp1:
	./qualify-mlp1-shader-recommendations.sh

qualify-shader-expansion-mlp1:
	./qualify-mlp1-shader-expansion.sh

package package-native package-mlp1:
	@rm -rf "$(PACKAGE_ROOT)"
	@mkdir -p "$(PACKAGE_DIR)"
	@cp -f "pak/launch.sh" "$(PACKAGE_DIR)/launch.sh"
	@cp -f "pak/pak.json" "$(PACKAGE_DIR)/pak.json"
	@cp -R "pak/res" "$(PACKAGE_DIR)/res"
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
