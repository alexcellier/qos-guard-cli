# QoS Guard CLI — Makefile
#
# Usage:
#   make install    Install to /usr/local/bin
#   make uninstall  Remove from /usr/local/bin
#   make test       Run tests
#   make lint       Lint the script
#   make clean      Remove temporary files
#   make help       Show available targets

PREFIX      ?= /usr/local
BINDIR       = $(PREFIX)/bin
INSTALL_MODE = 755

BINARY       = qos-guard

# Proxy variables
PROXY_DIR       = qos-proxy
PROXY_BINARY   = $(PROXY_DIR)/qos-proxy
PROXY_SRC        = $(PROXY_DIR)/qos-proxy.go

.PHONY: all install uninstall test lint clean help proxy-build proxy-clean proxy-cross proxy-install proxy-uninstall

all: $(BINARY) proxy-build

install: $(BINARY) proxy-install

proxy-install: $(PROXY_BINARY)
	cp $(PROXY_BINARY) /usr/local/bin/qos-proxy
	chmod +x /usr/local/bin/qos-proxy
	@echo "Installed qos-proxy to /usr/local/bin/"

uninstall: proxy-uninstall
	rm -f $(DESTDIR)$(BINDIR)/$(BINARY)
	@echo "Removed $(BINARY) from $(DESTDIR)$(BINDIR)/"

test:
	@if command -v bats >/dev/null 2>&1; then \
		bats tests/; \
	else \
		echo "bats framework not found. Install with: brew install bats-core"; \
		exit 1; \
	fi

lint:
	@echo "Linting $(BINARY)..."
	shellcheck $(BINARY)
	@echo "Lint passed."

clean: proxy-clean
	rm -f .qosguard-*.pf
	@echo "Cleaned temporary files."

help:
	@echo "Available targets:"
	@echo "  install         Install qos-guard and qos-proxy to /usr/local/bin"
	@echo "  uninstall       Remove qos-guard from /usr/local/bin"
	@echo "  test            Run tests"
	@echo "  lint            Lint the script"
	@echo "  clean           Remove temporary files"
	@echo "  proxy-build     Build the qos-proxy binary"
	@echo "  proxy-clean     Remove the qos-proxy binary"
	@echo "  proxy-cross     Cross-compile qos-proxy for macOS amd64/arm64"
	@echo "  proxy-install   Install qos-proxy to /usr/local/bin"
	@echo "  proxy-uninstall Remove qos-proxy from /usr/local/bin"
	@echo "  help            Show this help message"

# Proxy targets
proxy-build:
	cd $(PROXY_DIR) && go build -o $(PROXY_BINARY) $(PROXY_SRC)

proxy-clean:
	rm -f $(PROXY_BINARY)

proxy-cross:
	GOOS=darwin GOARCH=amd64 go build -o $(PROXY_BINARY)-amd64 $(PROXY_SRC)
	GOOS=darwin GOARCH=arm64 go build -o $(PROXY_BINARY)-arm64 $(PROXY_SRC)

proxy-uninstall:
	rm -f /usr/local/bin/qos-proxy
