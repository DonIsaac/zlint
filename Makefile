ZIG ?= zig

PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin

.PHONY: all build install clean

all: build

build:
	$(ZIG) build --error-style minimal --summary all $(ZIGFLAGS)

install: build
	install -d $(BINDIR)
	install -m 0755 zig-out/bin/zlint $(BINDIR)/zlint

clean:
	rm -rf zig-out .zig-cache
