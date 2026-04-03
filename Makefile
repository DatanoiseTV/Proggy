APP_NAME = Proggy
BUILD_DIR = .build
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
CONTENTS = $(APP_BUNDLE)/Contents
MACOS = $(CONTENTS)/MacOS
RESOURCES = $(CONTENTS)/Resources

.PHONY: all build bundle run clean

all: bundle

build:
	swift build -c release

debug:
	swift build

bundle: build
	@mkdir -p $(MACOS) $(RESOURCES)
	@cp $(BUILD_DIR)/release/$(APP_NAME) $(MACOS)/$(APP_NAME)
	@cp Resources/Info.plist $(CONTENTS)/Info.plist
	@codesign --force --sign - $(APP_BUNDLE)
	@echo "Built $(APP_BUNDLE)"

bundle-debug: debug
	@mkdir -p $(MACOS) $(RESOURCES)
	@cp $(BUILD_DIR)/debug/$(APP_NAME) $(MACOS)/$(APP_NAME)
	@cp Resources/Info.plist $(CONTENTS)/Info.plist
	@codesign --force --sign - $(APP_BUNDLE)
	@echo "Built $(APP_BUNDLE) (debug)"

run: bundle-debug
	@open $(APP_BUNDLE)

run-release: bundle
	@open $(APP_BUNDLE)

clean:
	swift package clean
	rm -rf $(APP_BUNDLE)
