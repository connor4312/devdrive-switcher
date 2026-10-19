SWIFTC := xcrun swiftc
BINARY := .build/dev-cache
APP := .build/DevCache.app
SOURCES := Sources/main.swift Sources/MenuBar.swift

.PHONY: all test test-router test-menu app

all: $(BINARY)

$(BINARY): $(SOURCES)
	mkdir -p .build
	$(SWIFTC) -O -warnings-as-errors $(SOURCES) -o $@

test: test-router test-menu

test-router: $(BINARY)
	$(BINARY) self-test

test-menu: $(BINARY)
	$(BINARY) menu-test

app: $(BINARY) resources/Info.plist
	mkdir -p $(APP)/Contents/MacOS
	cp $(BINARY) $(APP)/Contents/MacOS/dev-cache
	cp resources/Info.plist $(APP)/Contents/Info.plist
	codesign --force --sign - $(APP)
	codesign --verify --deep --strict $(APP)
