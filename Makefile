# Makefile for ExifCleaner AutoSend (SafeSend)
CC ?= gcc
CFLAGS ?= -O2 -Wall -fPIC
LDFLAGS ?= -shared -ldl -lpthread

BUILD_DIR = build
SRC_DIR = src
BIN_DIR = bin
DESKTOP_DIR = desktop

TARGET = $(BUILD_DIR)/libcleanupload.so
SRC = $(SRC_DIR)/libcleanupload.c

PREFIX ?= /usr/local
BIN_INSTALL_DIR = $(PREFIX)/bin
LIB_INSTALL_DIR = $(PREFIX)/lib
APP_INSTALL_DIR = /usr/share/applications

.PHONY: all build clean install uninstall test status

all: build

build: $(TARGET)

$(TARGET): $(SRC)
	@mkdir -p $(BUILD_DIR)
	$(CC) $(CFLAGS) $< $(LDFLAGS) -o $@
	@echo "Build complete: $@"

clean:
	rm -rf $(BUILD_DIR)
	@echo "Clean complete."

install: build
	@echo "Installing SafeSend components to $(PREFIX)..."
	@mkdir -p $(LIB_INSTALL_DIR) $(BIN_INSTALL_DIR)
	install -m 755 $(TARGET) $(LIB_INSTALL_DIR)/libcleanupload.so
	install -m 755 $(BIN_DIR)/clean-for-send $(BIN_INSTALL_DIR)/
	install -m 755 $(BIN_DIR)/clean-auto-purge $(BIN_INSTALL_DIR)/
	install -m 755 $(BIN_DIR)/clean-clipboard-send $(BIN_INSTALL_DIR)/
	install -m 755 $(BIN_DIR)/safesend $(BIN_INSTALL_DIR)/
	install -m 755 $(BIN_DIR)/safesend-watcher $(BIN_INSTALL_DIR)/
	install -m 755 $(BIN_DIR)/safesend-clipboard $(BIN_INSTALL_DIR)/
	@if [ -d $(APP_INSTALL_DIR) ]; then \
		install -m 644 $(DESKTOP_DIR)/SafeSend.desktop $(APP_INSTALL_DIR)/; \
	fi
	@mkdir -p -m 01777 /dev/shm/.clean_send
	@chmod 01777 /dev/shm/.clean_send
	@ldconfig 2>/dev/null || true
	@echo "Binaries and library installed successfully."

uninstall:
	@echo "Uninstalling SafeSend..."
	rm -f $(LIB_INSTALL_DIR)/libcleanupload.so
	rm -f $(BIN_INSTALL_DIR)/clean-for-send
	rm -f $(BIN_INSTALL_DIR)/clean-auto-purge
	rm -f $(BIN_INSTALL_DIR)/clean-clipboard-send
	rm -f $(BIN_INSTALL_DIR)/safesend
	rm -f $(BIN_INSTALL_DIR)/safesend-watcher
	rm -f $(BIN_INSTALL_DIR)/safesend-clipboard
	rm -f $(APP_INSTALL_DIR)/SafeSend.desktop
	rm -rf /dev/shm/.clean_send
	@ldconfig 2>/dev/null || true
	@echo "Uninstall complete."

test: build
	python3 tests/test_clean.py

status:
	@safesend --status || echo "Run 'sudo make install' first."
