.PHONY: build run test app clean

# Build both packages (debug).
build:
	cd packages/StatusCore && swift build
	cd apps/StatusBar && swift build

# Run the menubar app from source (Ctrl-C to stop).
run:
	cd apps/StatusBar && swift run StatusBar

# Run the StatusCore test suite.
test:
	cd packages/StatusCore && swift test

# Package a distributable Site Status.app into dist/.
app:
	./scripts/build-app.sh

# Build and install the app into /Applications.
install: app
	rm -rf "/Applications/Site Status.app"
	cp -R "dist/Site Status.app" "/Applications/Site Status.app"
	@echo "Installed to /Applications. Enable 'Launch at login' from Settings (⌘,)."

clean:
	rm -rf packages/StatusCore/.build apps/StatusBar/.build dist
