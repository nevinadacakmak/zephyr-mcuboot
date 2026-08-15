# MCUboot direct-xip automation
# Usage: make <target>
#   make flash-v0      -> build+flash MCUboot + v0 app to slot0 (full sysbuild)
#   make flash-v1      -> build+sign+flash v1 app to slot1 (higher version boots)
#   make reset         -> reset the board only (no flashing)
#   make serial         -> open serial terminal
#   make all           -> flash-v0 then flash-v1 in sequence
#
# direct-xip mode: both slots hold complete, independent images at all times.
# MCUboot compares version numbers and boots whichever is higher directly -
# nothing is moved or copied, so no sector-offset math is needed (unlike
# swap-using-offset, which this Makefile previously used).

ZEPHYR_WS   := /Users/nevinadacakmak/Desktop/Projects/UTAT/zephyrproject
BOARD       := nucleo_l496zg
APP_V0      := zephyr-mcuboot/utat-mcuboot
APP_V1      := zephyr-mcuboot/utat-mcuboot-v2
MCUBOOT_KEY := $(ZEPHYR_WS)/bootloader/mcuboot/root-rsa-2048.pem
IMGTOOL     := python3 $(ZEPHYR_WS)/bootloader/mcuboot/scripts/imgtool.py

CUBEPROG    := /Applications/STMicroelectronics/STM32Cube/STM32CubeProgrammer/STM32CubeProgrammer.app/Contents/Resources/bin/STM32_Programmer_CLI

# slot1 partition base address and full size - direct-xip uses the whole
# partition, no reserved sector like swap-using-offset needed
SLOT1_ADDR      := 0x08088000
SLOT1_SIZE      := 0x78000
HEADER_SIZE     := 0x200
ALIGN           := 8

# both versions are explicit and controllable - whichever is higher wins
# on the next reset. Flip which one you want to run by bumping its number
# above the other and reflashing that slot.
#
# V1 is set higher than V0 on purpose: this makes utat-mcuboot-v2 the
# "candidate" image MCUboot will pick on the next reset after flash-v1.
# Since v2's main.c deliberately never confirms itself, this sets up the
# direct-xip-with-revert test: it boots once as an unconfirmed candidate,
# then gets reverted back to v0 on the reset *after* that.
V0_VERSION      := 3.0.0
V1_VERSION      := 4.0.0

SERIAL_PORT := /dev/cu.usbmodem1403
BAUD        := 115200

.PHONY: all flash-v0 flash-v1 build-v0 build-v1 sign-v1 reset serial clean

all: flash-v0 flash-v1

# --- v0: MCUboot + app, built together via sysbuild, flashed to slot0 ---
# --- v0: MCUboot + app, built together via sysbuild, flashed to slot0 ---
# App version is set via a VERSION file in the app root (Zephyr's app
# version system), not a Kconfig flag - generate it from V0_VERSION here.
build-v0:
	@MAJOR=$$(echo $(V0_VERSION) | cut -d. -f1); \
	MINOR=$$(echo $(V0_VERSION) | cut -d. -f2); \
	PATCH=$$(echo $(V0_VERSION) | cut -d. -f3); \
	printf 'VERSION_MAJOR = %s\nVERSION_MINOR = %s\nPATCHLEVEL = %s\nVERSION_TWEAK = 0\nEXTRAVERSION =\n' \
		"$$MAJOR" "$$MINOR" "$$PATCH" > $(ZEPHYR_WS)/$(APP_V0)/VERSION
	cd $(ZEPHYR_WS) && west build -p always -b $(BOARD) $(APP_V0) --sysbuild -- \
		-DSB_CONFIG_BOOTLOADER_MCUBOOT=y \
		-DSB_CONFIG_MCUBOOT_MODE_DIRECT_XIP_WITH_REVERT=y \
		-DCONFIG_BOOTLOADER_MCUBOOT=y

flash-v0: build-v0
	cd $(ZEPHYR_WS) && west flash

# --- v1: standalone app build, signed for slot1 (direct-xip, full slot size) ---
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

serial:
	screen $(SERIAL_PORT) $(BAUD)

clean:
	rm -rf $(ZEPHYR_WS)/build