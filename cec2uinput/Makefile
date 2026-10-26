CC ?= cc
CFLAGS ?= -O2 -g
CFLAGS += -std=gnu11 -Wall -Wextra
PREFIX ?= /usr
DESTDIR ?=

cec2uinput: src/cec2uinput.c
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<

install: cec2uinput
	install -Dm755 cec2uinput $(DESTDIR)$(PREFIX)/bin/cec2uinput
	install -Dm644 systemd/cec2uinput.service $(DESTDIR)/lib/systemd/system/cec2uinput.service
	install -Dm644 systemd/cec2uinput.default $(DESTDIR)/etc/default/cec2uinput
	install -Dm644 systemd/modules-load.conf $(DESTDIR)/usr/lib/modules-load.d/cec2uinput.conf

clean:
	rm -f cec2uinput

.PHONY: install clean
