# MCUboot swap-using-move automation - app-triggered A/B toggle
# Usage: make <target>
#   make flash-v0      -> build+flash MCUboot + v0 app to slot0
#   make flash-v1      -> build+sign+flash v1 app to slot1
#   make reset         -> reset the board only (no flashing)
#   make serial        -> open serial terminal
#   make all           -> flash-v0 then flash-v1 in sequence
#
# swap-using-move: each running image calls boot_request_upgrade() on boot,
# arming a permanent swap to the OTHER slot. The next physical reset
# performs that swap and boots the other image - which does the same thing
# in reverse. This is what makes it alternate on a plain reset, with no
# reflashing between presses. (direct-xip cannot do this - it has no
# writable trailer bit for the app to set; that's why we moved back to a
# swap-based mode.)
#
# IMPORTANT: unlike direct-xip, every image here must be built assuming it
# runs from slot0 - swap-using-move physically copies images into slot0
# before running them. Do NOT add a slot1 code-partition overlay to v1.

ZEPHYR_WS   := /Users/nevinadacakmak/Desktop/Projects/UTAT/zephyrproject
BOARD       := nucleo_l496zg
APP_V0      := zephyr-mcuboot/utat-mcuboot
APP_V1      := zephyr-mcuboot/utat-mcuboot-v2
MCUBOOT_KEY := $(ZEPHYR_WS)/bootloader/mcuboot/root-rsa-2048.pem
IMGTOOL     := python3 $(ZEPHYR_WS)/bootloader/mcuboot/scripts/imgtool.py

CUBEPROG    := /Applications/STMicroelectronics/STM32Cube/STM32CubeProgrammer/STM32CubeProgrammer.app/Contents/Resources/bin/STM32_Programmer_CLI

# slot1 partition base address and full size.
# NOTE: swap-using-offset needed a +0x800 address shift and a smaller
# slot size to leave room for its bookkeeping sector. swap-using-move does
# NOT use that reserved-sector trick - flash at the exact partition base,
# full slot size. If imgtool or the flash step errors about address/size,
# that's the first thing to double check against build/mcuboot/zephyr/.config.
SLOT1_ADDR      := 0x08088000
SLOT1_SIZE      := 0x78000
HEADER_SIZE     := 0x200
ALIGN           := 8

# Versions no longer matter for WHO boots - swap-using-move's decision is
# driven entirely by the trailer state that boot_request_upgrade() writes,
# not by comparing version numbers (that was direct-xip's rule, not this
# mode's). Kept here only because imgtool requires a version to sign with.
V0_VERSION      := 3.0.0
V1_VERSION      := 4.0.0

SERIAL_PORT := /dev/cu.usbmodem1403
BAUD        := 115200

.PHONY: all flash-v0 flash-v1 build-v0 build-v1 sign-v1 reset erase serial clean

all: flash-v0 flash-v1

# --- v0: MCUboot + app, built together via sysbuild, flashed to slot0 ---
# App version is set via a VERSION file in the app root (Zephyr's app
# version system), not a Kconfig flag - generate it from V0_VERSION here.
#
# SB_CONFIG_MCUBOOT_MODE_SWAP_USING_MOVE is the sysbuild-level symbol name
# by the same naming pattern as MCUBOOT_MODE_DIRECT_XIP_WITH_REVERT, which
# we confirmed earlier via `west build -t sysbuild_menuconfig`. This one
# has NOT been confirmed the same way yet - after your first build, run:
#   grep -i "SWAP_USING\|DIRECT_XIP" build/mcuboot/zephyr/.config
# to verify CONFIG_BOOT_SWAP_USING_MOVE=y actually landed before trusting it.
build-v0:
	@MAJOR=$$(echo $(V0_VERSION) | cut -d. -f1); \
	MINOR=$$(echo $(V0_VERSION) | cut -d. -f2); \
	PATCH=$$(echo $(V0_VERSION) | cut -d. -f3); \
	printf 'VERSION_MAJOR = %s\nVERSION_MINOR = %s\nPATCHLEVEL = %s\nVERSION_TWEAK = 0\nEXTRAVERSION =\n' \
		"$$MAJOR" "$$MINOR" "$$PATCH" > $(ZEPHYR_WS)/$(APP_V0)/VERSION
	cd $(ZEPHYR_WS) && west build -p always -b $(BOARD) $(APP_V0) --sysbuild -- \
		-DSB_CONFIG_BOOTLOADER_MCUBOOT=y \
		-DSB_CONFIG_MCUBOOT_MODE_SWAP_USING_MOVE=y

flash-v0: build-v0
	cd $(ZEPHYR_WS) && west flash

# --- v1: standalone app build, signed for slot1 ---
# No code-partition overlay here (removed - see note at top of file).
build-v1:
	cd $(ZEPHYR_WS) && west build -p always -b $(BOARD) $(APP_V1) -d build/slot1_test -- \
		-DCONFIG_BOOTLOADER_MCUBOOT=y \
		-DCONFIG_MCUBOOT_SIGNATURE_KEY_FILE=\"$(MCUBOOT_KEY)\"

sign-v1: build-v1
	$(IMGTOOL) sign \
		--key $(MCUBOOT_KEY) \
		--align $(ALIGN) \
		--header-size $(HEADER_SIZE) \
		--slot-size $(SLOT1_SIZE) \
		--pad \
		--version $(V1_VERSION) \
		$(ZEPHYR_WS)/build/slot1_test/zephyr/zephyr.bin \
		$(ZEPHYR_WS)/build/slot1_test/zephyr/zephyr.slot1.bin

flash-v1: sign-v1
	$(CUBEPROG) --connect port=swd reset=HWrst \
		--download $(ZEPHYR_WS)/build/slot1_test/zephyr/zephyr.slot1.bin $(SLOT1_ADDR)

# --- helpers ---
reset:
	$(CUBEPROG) --connect port=swd reset=HWrst -hardRst

# Full chip erase - wipes BOTH slots' image trailers, not just their image
# data. Needed before a fresh test cycle whenever a slot was last written
# via raw flash-v1 (STM32CubeProgrammer), since that path never touches the
# trailer and a stale "pending swap" flag from an earlier boot can silently
# override whatever you flash next. Run this before flash-v0 if a reset
# ever boots something other than what you just flashed.
erase:
	$(CUBEPROG) --connect port=swd reset=HWrst --erase all

serial:
	screen $(SERIAL_PORT) $(BAUD)

clean:
	rm -rf $(ZEPHYR_WS)/build