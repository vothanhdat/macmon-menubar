APP_NAME   := MacMon Indicator
EXEC       := MacMonIndicator
BUNDLE_ID  ?= local.MacMonIndicator
VERSION    ?= 0.1.0
BUILD_DIR  := build
APP        := $(BUILD_DIR)/$(APP_NAME).app
PREFIX     ?= /Applications
HELPER     := macmon-indicator-helper

.PHONY: all app run install uninstall clean check-macmon

all: app

$(BUILD_DIR)/$(HELPER): Helper/helper.c
	@mkdir -p $(BUILD_DIR)
	clang -O2 -Wall -Wextra -mmacosx-version-min=13.0 -o $@ $<

app: $(BUILD_DIR)/$(HELPER)
	swift build -c release --arch arm64
	@rm -rf "$(APP)"
	@mkdir -p "$(APP)/Contents/MacOS"
	@cp "$$(swift build -c release --arch arm64 --show-bin-path)/$(EXEC)" "$(APP)/Contents/MacOS/$(EXEC)"
	@cp $(BUILD_DIR)/$(HELPER) "$(APP)/Contents/MacOS/$(HELPER)"
	@sed -e 's/__BUNDLE_ID__/$(BUNDLE_ID)/' -e 's/__VERSION__/$(VERSION)/g' Resources/Info.plist > "$(APP)/Contents/Info.plist"
	@codesign --force --sign - "$(APP)/Contents/MacOS/$(HELPER)"
	@codesign --force --sign - "$(APP)"
	@echo "Built $(APP)"

run: app
	@open "$(APP)"

check-macmon:
	@command -v macmon >/dev/null 2>&1 || [ -x /opt/homebrew/bin/macmon ] || \
		{ echo "macmon not found. Install it first:  brew install macmon"; exit 1; }

install: check-macmon app
	@pkill -x $(EXEC) 2>/dev/null || true
	@# Wait (up to 5 s) for the old copy to quit, or `open` fails with error -600.
	@for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25; do pgrep -x $(EXEC) >/dev/null || break; sleep 0.2; done
	@rm -rf "$(PREFIX)/$(APP_NAME).app"
	@cp -R "$(APP)" "$(PREFIX)/"
	@echo "Installed to $(PREFIX)/$(APP_NAME).app"
	@open "$(PREFIX)/$(APP_NAME).app"

uninstall:
	@pkill -x $(EXEC) 2>/dev/null || true
	@rm -rf "$(PREFIX)/$(APP_NAME).app"
	@echo "Removed $(PREFIX)/$(APP_NAME).app (history stays in ~/Library/Application Support/MacMonIndicator)"

clean:
	rm -rf $(BUILD_DIR) .build
