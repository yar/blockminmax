# Makefile for blockminmax
# Default build: optimized for speed with gcc -O3. You can override variables
# from the command line, e.g.:
#   make CFLAGS='-O2 -g -Wall' LDFLAGS=''

PROG    := blockminmax
SRC     := blockminmax.c
OBJ     := $(SRC:.c=.o)

CC      ?= gcc
CPPFLAGS?=

# Core optimization and warnings. Adjust or override as needed.
BASE_CFLAGS ?= -O3 -DNDEBUG
WARN_CFLAGS ?= -Wall -Wextra -Wpedantic -Wformat=2 -Wshadow
OPT_CFLAGS  ?= -flto
# For maximum speed on the build machine. Remove/override for portability.
NATIVE_CFLAGS ?= -march=native

CFLAGS  ?=
LDFLAGS ?=
LDLIBS  ?=

# Compose final flags (user overrides still respected)
override CFLAGS += $(BASE_CFLAGS) $(WARN_CFLAGS) $(OPT_CFLAGS) $(NATIVE_CFLAGS)
override LDFLAGS += $(OPT_CFLAGS)

.PHONY: all clean release debug install uninstall

all: $(PROG)

$(PROG): $(OBJ)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $^ $(LDLIBS)

%.o: %.c
	$(CC) $(CPPFLAGS) $(CFLAGS) -c -o $@ $<

# Convenience targets
release: CFLAGS := -O3 -DNDEBUG $(WARN_CFLAGS) $(OPT_CFLAGS) $(NATIVE_CFLAGS)
release: LDFLAGS := $(OPT_CFLAGS)
release: clean $(PROG)

debug: CFLAGS := -O0 -g $(WARN_CFLAGS)
debug: LDFLAGS :=
debug: clean $(PROG)

clean:
	$(RM) $(OBJ) $(PROG)

# Optional install
PREFIX ?= /usr/local
BIN_DIR := $(DESTDIR)$(PREFIX)/bin

install: $(PROG)
	install -d $(BIN_DIR)
	install -m 0755 $(PROG) $(BIN_DIR)/$(PROG)

uninstall:
	$(RM) $(BIN_DIR)/$(PROG)

.PHONY: compare
compare: $(PROG)
	bash ./compare_all.sh -R1585520.5/1587224.5/5464422.5/5467728.5 -I1 -P test.xyz || true
