# Baut den Empfangskern, Werkzeuge und Tests mit dem GStreamer des Systems
# (Linux: Paketverwaltung; macOS: GStreamer.framework über PKG_CONFIG_PATH).
CC ?= cc
PKGS = gstreamer-1.0 gstreamer-app-1.0 gstreamer-video-1.0 gstreamer-net-1.0 gio-2.0
CFLAGS += -std=c11 -D_GNU_SOURCE -D_DARWIN_C_SOURCE -O2 -g -Wall -Wextra -Wno-unused-parameter -Iinclude -Isrc $(shell pkg-config --cflags $(PKGS))
LDLIBS += $(shell pkg-config --libs $(PKGS)) -lm
BUILD = build
SRC = src/st_sdp.c src/st_mediaclock.c src/st_socket.c src/st_receiver.c
OBJ = $(SRC:src/%.c=$(BUILD)/%.o)

all: $(BUILD)/st2110-probe $(BUILD)/st2110-testsender $(BUILD)/test_unit

$(BUILD)/%.o: src/%.c include/st2110core.h src/st_internal.h | $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD)/libst2110core.a: $(OBJ)
	ar rcs $@ $^

$(BUILD)/st2110-probe: tools/st2110_probe.c $(BUILD)/libst2110core.a
	$(CC) $(CFLAGS) $^ -o $@ $(LDLIBS)

$(BUILD)/st2110-testsender: tools/st2110_testsender.c
	$(CC) $(CFLAGS) $^ -o $@ $(LDLIBS)

$(BUILD)/test_unit: tests/test_unit.c $(BUILD)/libst2110core.a
	$(CC) $(CFLAGS) $^ -o $@ $(LDLIBS)

$(BUILD):
	mkdir -p $(BUILD)

test: all
	./$(BUILD)/test_unit tests/sdp
	./tests/run_loopback_tests.sh

clean:
	rm -rf $(BUILD)

.PHONY: all test clean
