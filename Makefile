.PHONY: build test run app package clean

APP_NAME := Serv
APP_DIR := .build/$(APP_NAME).app
RELEASE_BIN := .build/release/$(APP_NAME)
ZIP_PATH := .build/$(APP_NAME).app.zip

build:
	swift build

test:
	swift test

run:
	swift run $(APP_NAME)

app:
	swift build -c release
	rm -rf "$(APP_DIR)"
	mkdir -p "$(APP_DIR)/Contents/MacOS" "$(APP_DIR)/Contents/Resources"
	cp "$(RELEASE_BIN)" "$(APP_DIR)/Contents/MacOS/$(APP_NAME)"
	cp Resources/Info.plist "$(APP_DIR)/Contents/Info.plist"

package: app
	rm -f "$(ZIP_PATH)"
	ditto -c -k --keepParent "$(APP_DIR)" "$(ZIP_PATH)"

clean:
	rm -rf .build
