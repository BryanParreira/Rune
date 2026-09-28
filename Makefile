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

# Signing: uses your "Developer ID Application" certificate when one is installed, otherwise
# ad-hoc. Override with SIGN_IDENTITY="-" (ad-hoc) or a specific identity name.
SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | grep -m1 "Developer ID Application" | sed -E 's/.*"(.*)"/\1/')
ifeq ($(strip $(SIGN_IDENTITY)),)
SIGN_IDENTITY := -
endif
# Notarization credentials stored with:
#   xcrun notarytool store-credentials rune-notary --apple-id <you> --team-id <TEAM>
NOTARY_PROFILE ?= rune-notary

XCODEBUILD := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -derivedDataPath $(DERIVED) \
	-skipPackagePluginValidation -skipMacroValidation

.PHONY: all gen build run release install dmg notarize cli uninstall-cli test clean distclean

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

# Universal (arm64 + x86_64) Release build, signed inside-out.
release: gen
	$(XCODEBUILD) -configuration Release -destination 'generic/platform=macOS' \
		ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build -quiet
	sh scripts/sign.sh "$(RELEASE_APP)" "$(SIGN_IDENTITY)"
	@lipo -info "$(RELEASE_APP)/Contents/MacOS/$(APP_NAME)"

install: release
	@if [ -d "$(INSTALL_DIR)/$(APP_NAME).app" ]; then rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"; fi
	ditto "$(RELEASE_APP)" "$(INSTALL_DIR)/$(APP_NAME).app"
	@echo "Installed $(INSTALL_DIR)/$(APP_NAME).app"

dmg: release
	sh scripts/make-dmg.sh "$(RELEASE_APP)" "$(DMG)" "$(SIGN_IDENTITY)"

# Notarizes and staples the app, rebuilds the DMG around it, then notarizes and staples the DMG.
notarize: release
	@test "$(SIGN_IDENTITY)" != "-" || { echo "Notarization needs a Developer ID Application certificate"; exit 1; }
	sh scripts/notarize.sh "$(RELEASE_APP)" "$(DMG)" "$(SIGN_IDENTITY)" "$(NOTARY_PROFILE)"

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
