APP_NAME   := MacMon Indicator
EXEC       := MacMonIndicator
BUNDLE_ID  ?= local.MacMonIndicator
VERSION    ?= 0.1.2
BUILD_DIR  := build
APP        := $(BUILD_DIR)/$(APP_NAME).app
PREFIX     ?= /Applications
HELPER     := macmon-indicator-helper
DIST_DIR   := dist
DIST_ZIP   := $(DIST_DIR)/MacMon-Indicator-$(VERSION).zip
# macmon to bundle inside the app (the real file behind Homebrew's symlink). Override with MACMON=/path.
MACMON     ?= $(shell p=$$(command -v macmon || echo /opt/homebrew/bin/macmon); [ -e "$$p" ] && realpath "$$p")

.PHONY: all app run install uninstall clean check-macmon dist

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
	@# The app icon is drawn in code (About.icon); render it at every size and pack it as .icns.
	@mkdir -p "$(APP)/Contents/Resources"
	@"$(APP)/Contents/MacOS/$(EXEC)" --iconset "$(BUILD_DIR)/AppIcon.iconset"
	@iconutil -c icns "$(BUILD_DIR)/AppIcon.iconset" -o "$(APP)/Contents/Resources/AppIcon.icns"
	@sed -e 's/__BUNDLE_ID__/$(BUNDLE_ID)/' -e 's/__VERSION__/$(VERSION)/g' Resources/Info.plist > "$(APP)/Contents/Info.plist"
	@codesign --force --sign - "$(APP)/Contents/MacOS/$(HELPER)"
	@# Bundle macmon (MIT) so the app also works on Macs without Homebrew. Without a bundled
	@# copy, the app looks for macmon in the usual places at runtime.
	@if [ -x "$(MACMON)" ]; then \
		mkdir -p "$(APP)/Contents/Resources"; \
		cp "$(MACMON)" "$(APP)/Contents/MacOS/macmon"; chmod 755 "$(APP)/Contents/MacOS/macmon"; \
		lic="$$(dirname "$$(dirname "$(MACMON)")")/LICENSE"; \
		if [ -f "$$lic" ]; then cp "$$lic" "$(APP)/Contents/Resources/macmon-LICENSE"; fi; \
		codesign --force --sign - "$(APP)/Contents/MacOS/macmon"; \
		echo "Bundled $$("$(MACMON)" --version) from $(MACMON)"; \
	else \
		echo "Note: macmon not found, so it is not bundled (brew install macmon)"; \
	fi
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

# Zip for a GitHub Release: unzip, move to /Applications, open (macmon included).
dist: app
	@[ -x "$(APP)/Contents/MacOS/macmon" ] || { echo "dist needs macmon to bundle: brew install macmon"; exit 1; }
	@codesign --verify --deep --strict "$(APP)"
	@mkdir -p $(DIST_DIR)
	@# No extended attributes: they become ._ files, which break the signature when unzipped with `unzip`.
	@ditto -c -k --norsrc --noextattr --noacl --keepParent "$(APP)" "$(DIST_ZIP).tmp" && mv -f "$(DIST_ZIP).tmp" "$(DIST_ZIP)"
	@echo "Built $(DIST_ZIP) ($$(du -h "$(DIST_ZIP)" | cut -f1))"
	@shasum -a 256 "$(DIST_ZIP)"

uninstall:
	@pkill -x $(EXEC) 2>/dev/null || true
	@rm -rf "$(PREFIX)/$(APP_NAME).app"
	@echo "Removed $(PREFIX)/$(APP_NAME).app (history stays in ~/Library/Application Support/MacMonIndicator)"

clean:
	rm -rf $(BUILD_DIR) $(DIST_DIR) .build
