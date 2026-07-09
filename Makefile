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

clean:
	rm -rf packages/StatusCore/.build apps/StatusBar/.build dist
