APP_NAME      := Rune
SCHEME        := Rune
PROJECT       := $(APP_NAME).xcodeproj
BUILD_DIR     := build
DERIVED       := $(BUILD_DIR)/DerivedData
DEBUG_APP     := $(DERIVED)/Build/Products/Debug/$(APP_NAME).app
RELEASE_APP   := $(DERIVED)/Build/Products/Release/$(APP_NAME).app
DIST_DIR      := $(BUILD_DIR)/dist
DMG           := $(BUILD_DIR)/$(APP_NAME).dmg
INSTALL_DIR   ?= /Applications
PREFIX        ?= $(HOME)/.local

XCODEBUILD := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -derivedDataPath $(DERIVED) \
	-skipPackagePluginValidation -skipMacroValidation

.PHONY: all gen build run release install dmg cli uninstall-cli test clean distclean

all: build

# Regenerated on every build so new source files are always picked up (takes <1s).
gen:
	@command -v xcodegen >/dev/null || { echo "xcodegen not found: brew install xcodegen"; exit 1; }
	@xcodegen generate --quiet

build: gen
	$(XCODEBUILD) -configuration Debug build -quiet

run: build
	open "$(DEBUG_APP)"

test: gen
	$(XCODEBUILD) -configuration Debug test -quiet

# Universal (arm64 + x86_64) Release build, ad-hoc signed.
release: gen
	$(XCODEBUILD) -configuration Release -destination 'generic/platform=macOS' \
		ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build -quiet
	codesign --force --deep --sign - "$(RELEASE_APP)"
	@lipo -info "$(RELEASE_APP)/Contents/MacOS/$(APP_NAME)"

install: release
	@if [ -d "$(INSTALL_DIR)/$(APP_NAME).app" ]; then rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"; fi
	ditto "$(RELEASE_APP)" "$(INSTALL_DIR)/$(APP_NAME).app"
	@echo "Installed $(INSTALL_DIR)/$(APP_NAME).app"

dmg: release
	rm -rf "$(DIST_DIR)" "$(DMG)"
	mkdir -p "$(DIST_DIR)"
	ditto "$(RELEASE_APP)" "$(DIST_DIR)/$(APP_NAME).app"
	ln -s /Applications "$(DIST_DIR)/Applications"
	cp INSTALL.md "$(DIST_DIR)/INSTALL.md"
	hdiutil create -volname "$(APP_NAME)" -srcfolder "$(DIST_DIR)" -ov -format UDZO "$(DMG)" -quiet
	rm -rf "$(DIST_DIR)"
	@echo "Created $(DMG)"

# Installs the `rune` command. Override with: make cli PREFIX=/usr/local
cli:
	mkdir -p "$(PREFIX)/bin"
	install -m 0755 scripts/rune "$(PREFIX)/bin/rune"
	@echo "Installed $(PREFIX)/bin/rune"
	@case ":$$PATH:" in *":$(PREFIX)/bin:"*) ;; *) echo "Note: $(PREFIX)/bin is not on your PATH";; esac

uninstall-cli:
	rm -f "$(PREFIX)/bin/rune"

clean:
	rm -rf "$(DERIVED)/Build" "$(DMG)" "$(DIST_DIR)"

distclean:
	rm -rf "$(BUILD_DIR)" "$(PROJECT)"
