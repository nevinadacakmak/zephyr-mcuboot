# MCUboot swap test automation
# Usage: make <target>
#   make flash-v0      -> build+flash MCUboot + v0 app to slot0 (full sysbuild)
#   make flash-v1      -> build+sign+flash v1 app to slot1 (triggers swap test)
#   make reset         -> reset the board only (no flashing)
#   make serial         -> open serial terminal
#   make all           -> flash-v0 then flash-v1 in sequence

ZEPHYR_WS   := /Users/nevinadacakmak/Desktop/Projects/UTAT/zephyrproject
BOARD       := nucleo_l496zg
APP_V0      := zephyr-mcuboot/utat-mcuboot
APP_V1      := zephyr-mcuboot/utat-mcuboot-v2
MCUBOOT_KEY := $(ZEPHYR_WS)/bootloader/mcuboot/root-rsa-2048.pem
IMGTOOL     := python3 $(ZEPHYR_WS)/bootloader/mcuboot/scripts/imgtool.py

CUBEPROG    := /Applications/STMicroelectronics/STM32Cube/STM32CubeProgrammer/STM32CubeProgrammer.app/Contents/Resources/bin/STM32_Programmer_CLI

SLOT1_ADDR      := 0x08088800
SLOT1_SIZE      := 0x77800
HEADER_SIZE     := 0x200
ALIGN           := 8
VERSION         := 1.0.0

SERIAL_PORT := /dev/cu.usbmodem11103
BAUD        := 115200

.PHONY: all flash-v0 flash-v1 build-v0 build-v1 sign-v1 reset serial clean

all: flash-v0 flash-v1

# --- v0: MCUboot + app, built together via sysbuild, flashed to slot0 ---
build-v0:
	cd $(ZEPHYR_WS) && west build -p always -b $(BOARD) $(APP_V0) --sysbuild -- \
		-DSB_CONFIG_BOOTLOADER_MCUBOOT=y

flash-v0: build-v0
	cd $(ZEPHYR_WS) && west flash

# --- v1: standalone app build, signed and padded for slot1, offset-mode aware ---
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
		--version $(VERSION) \
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