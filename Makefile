# MCUboot swap-using-move automation, app-triggered A/B toggle.
# Both apps call boot_request_upgrade() on boot, arming a swap to the
# other slot for the next reset. alternates on reset alone, no reflashing.

ZEPHYR_WS   := /Users/nevinadacakmak/Desktop/Projects/UTAT/zephyrproject
BOARD       := nucleo_l496zg
APP_V0      := zephyr-mcuboot/utat-mcuboot
APP_V1      := zephyr-mcuboot/utat-mcuboot-v2
MCUBOOT_KEY := $(ZEPHYR_WS)/bootloader/mcuboot/root-rsa-2048.pem
IMGTOOL     := python3 $(ZEPHYR_WS)/bootloader/mcuboot/scripts/imgtool.py

CUBEPROG    := /Applications/STMicroelectronics/STM32Cube/STM32CubeProgrammer/STM32CubeProgrammer.app/Contents/Resources/bin/STM32_Programmer_CLI

SLOT1_ADDR      := 0x08088000
SLOT1_SIZE      := 0x78000
HEADER_SIZE     := 0x200
ALIGN           := 8

# imgtool requires a version to sign with, but swap-using-move doesn't use it
V0_VERSION      := 1.0.0
V1_VERSION      := 2.0.0

SERIAL_PORT := /dev/cu.usbmodem1403
BAUD        := 115200

.PHONY: all flash-v0 flash-v1 build-v0 build-v1 sign-v1 reset erase serial clean

all: flash-v0 flash-v1

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

reset:
	$(CUBEPROG) --connect port=swd reset=HWrst -hardRst

# wipes both slots' trailers too, not just image data, clears any stale
# "pending swap" flag left over from a previous test session
erase:
	$(CUBEPROG) --connect port=swd reset=HWrst --erase all

serial:
	screen $(SERIAL_PORT) $(BAUD)

clean:
	rm -rf $(ZEPHYR_WS)/build