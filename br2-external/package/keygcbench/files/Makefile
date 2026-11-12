# SPDX-License-Identifier: GPL-2.0-or-later

OUTPUT ?= .output
CC ?= $(CROSS_COMPILE)gcc
CLANG ?= clang
BPFTOOL ?= bpftool
BPF_TARGET ?= bpfel
PKG_CONFIG ?= pkg-config
VMLINUX_BTF ?= /sys/kernel/btf/vmlinux
INSTALL ?= install
PREFIX ?= /usr/local

CFLAGS ?= -O2 -g
PKG_CFLAGS := $(shell $(PKG_CONFIG) --cflags libbpf libcrypto)
PKG_LIBS := $(shell $(PKG_CONFIG) --libs libbpf libcrypto)
BPF_INCDIR := $(shell $(PKG_CONFIG) --variable=includedir libbpf)
BPF_CFLAGS := $(if $(BPF_INCDIR),-isystem $(BPF_INCDIR)) \
	$(shell $(PKG_CONFIG) --cflags libbpf)

ALL_CPPFLAGS = -I$(OUTPUT) $(CPPFLAGS) $(PKG_CFLAGS)
ALL_CFLAGS = $(CFLAGS) -Wall -Wextra -Werror
ALL_LDLIBS = $(LDLIBS) $(PKG_LIBS)

.PHONY: all clean install help
all: $(OUTPUT)/keygcbench

$(OUTPUT):
	mkdir -p $@

$(OUTPUT)/vmlinux.h: $(VMLINUX_BTF) | $(OUTPUT)
	$(BPFTOOL) btf dump file $< format c > $@.tmp
	mv $@.tmp $@

$(OUTPUT)/probe.bpf.o: probe.bpf.c keygcbench.h $(OUTPUT)/vmlinux.h
	$(CLANG) -target $(BPF_TARGET) -mcpu=v3 -O2 -g -Wall -Werror \
		-fms-extensions -Wno-microsoft-anon-tag \
		-I$(OUTPUT) $(BPF_CFLAGS) -c $< -o $@

$(OUTPUT)/probe.skel.h: $(OUTPUT)/probe.bpf.o
	$(BPFTOOL) gen skeleton $< > $@.tmp
	mv $@.tmp $@

$(OUTPUT)/%.o: %.c bench.h keygcbench.h $(OUTPUT)/probe.skel.h
	$(CC) $(ALL_CPPFLAGS) $(ALL_CFLAGS) -c $< -o $@

$(OUTPUT)/keygcbench: $(addprefix $(OUTPUT)/,main.o workload.o load.o)
	$(CC) $(LDFLAGS) $^ $(ALL_LDLIBS) -o $@

install: $(OUTPUT)/keygcbench
	$(INSTALL) -D -m 0755 $(OUTPUT)/keygcbench $(DESTDIR)$(PREFIX)/bin/keygcbench

help:
	@echo 'make [CC=...] [PKG_CONFIG=...] [BPFTOOL=...] [VMLINUX_BTF=...]'
	@echo 'Use a separate OUTPUT directory for each target architecture.'

clean:
	rm -f $(OUTPUT)/keygcbench $(OUTPUT)/*.o $(OUTPUT)/probe.skel.h \
		$(OUTPUT)/probe.skel.h.tmp $(OUTPUT)/vmlinux.h \
		$(OUTPUT)/vmlinux.h.tmp
