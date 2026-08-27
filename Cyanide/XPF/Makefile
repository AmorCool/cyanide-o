CC = clang

CHOMA_DYLIB_PATH ?= 0
CHOMA_PATH       ?= external/ChOma
CFLAGS            = -O2 -framework Foundation -I$(CHOMA_PATH)/include
CFLAGS_MACOS      = $(CFLAGS)
CFLAGS_IOS        = $(CFLAGS) -isysroot $(shell xcrun --sdk iphoneos --show-sdk-path) -miphoneos-version-min=15.0 -arch arm64 -arch arm64e
CFLAGS_IOSSIM     = $(CFLAGS) -isysroot $(shell xcrun --sdk iphonesimulator --show-sdk-path) -mios-simulator-version-min=17.0 -arch arm64
LDFLAGS           = -lcompression

all: output/macos/libxpf.dylib output/ios/libxpf.dylib output/macos/xpf_test output/ios/xpf_test

ifneq ($(CHOMA_DYLIB_PATH), 0)
CHOMA_DEP = 
LDFLAGS  += -L$(CHOMA_DYLIB_PATH) -lchoma
else
CHOMA_DEP = $(CHOMA_PATH)/src/*.c
endif 

output/macos/libxpf.dylib: $(wildcard src/*.c) $(CHOMA_DEP)
	@mkdir -p $(shell dirname $@)
	$(CC) $(CFLAGS_MACOS) $(LDFLAGS) -dynamiclib -install_name @loader_path/libxpf.dylib -o $@ $^

output/ios/libxpf.dylib: $(wildcard src/*.c) $(CHOMA_DEP)
	@mkdir -p $(shell dirname $@)
	$(CC) $(CFLAGS_IOS) $(LDFLAGS) -dynamiclib -install_name @loader_path/libxpf.dylib -o $@ $^
	# Sign the dylib. Prefer Apple codesign: ldid 2.1.5 (the bottle installed
	# on macOS 15 / Tahoe Apple-Silicon CI runners) emits an EMPTY
	# CODE_SIGNATURE superblob (LC_CODE_SIGNATURE cmd header only, 0 bytes of
	# signature data) on the fat arm64/arm64e dylib. iOS rejects that dylib at
	# dlopen time, which silently breaks KRW on device even though the rest of
	# the binary is identical to a locally-built one. codesign always produces
	# a real code directory blob. Fall back to ldid only if codesign is missing.
	codesign --force --sign - $@ || ldid -S $@
	@codesign -v $@ || { echo "ERROR: libxpf.dylib has no valid code signature (KRW will fail on device)"; exit 1; }

output/iphonesimulator/libxpf.dylib: $(wildcard src/*.c) $(CHOMA_DEP)
	@mkdir -p $(shell dirname $@)
	$(CC) $(CFLAGS_IOSSIM) $(LDFLAGS) -dynamiclib -install_name @loader_path/libxpf.dylib -o $@ $^

output/macos/xpf_test: $(wildcard src/cli/*.c)
	@mkdir -p $(shell dirname $@)
	$(CC) $(CFLAGS_MACOS) $(LDFLAGS) -L$(shell dirname $@) -lxpf -o $@ $^

output/ios/xpf_test: $(wildcard src/cli/*.c)
	@mkdir -p $(shell dirname $@)
	$(CC) $(CFLAGS_IOS) $(LDFLAGS) -L$(shell dirname $@) -lxpf -o $@ $^
	@codesign --force --sign - $@ || ldid -S $@
	@codesign -v $@ || { echo "ERROR: xpf_test has no valid code signature"; exit 1; }

clean:
	@rm -rf output
