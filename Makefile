.PHONY: adapters build run check test app install clean

# Build the TypeScript adapters to JS.
adapters:
	./scripts/build-adapters.sh

# Build both Swift packages (debug).
build:
	cd packages/StatusCore && swift build
	cd apps/StatusBar && swift build

# Run the menubar app from source (Ctrl-C to stop).
run: adapters
	cd apps/StatusBar && STATUSBAR_ADAPTERS_DIR=$(CURDIR)/adapters swift run StatusBar

# Headless: check every configured site once and print the result.
check: adapters
	cd apps/StatusBar && STATUSBAR_ADAPTERS_DIR=$(CURDIR)/adapters swift run StatusBar --check

# Run the StatusCore test suite.
test:
	cd packages/StatusCore && swift test

# Package a distributable Site Status.app (with bundled adapters) into dist/.
app:
	./scripts/build-app.sh

# Build and install the app into /Applications.
install: app
	rm -rf "/Applications/Site Status.app"
	cp -R "dist/Site Status.app" "/Applications/Site Status.app"
	@echo "Installed to /Applications. Enable 'Launch at login' from Settings (⌘,)."

clean:
	rm -rf packages/StatusCore/.build apps/StatusBar/.build dist
	rm -rf adapters/node_modules adapters/*/dist
