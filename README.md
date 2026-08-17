# MCUboot on Nucleo L496ZG: A/B Firmware Swap via Reset

Implementation notes for running MCUboot with Zephyr on the STM32L496ZG-NUCLEO,
with a working A/B firmware toggle: pressing the physical reset button alone
alternates which image runs, no reflashing needed between presses.

References:

- [Building and using MCUboot with Zephyr](https://docs.mcuboot.com/readme-zephyr.html)
- [MCUBoot Implementation Guide (UTAT)](https://git.janel.la/jjanella/mcuboot-guide-utat)

## 1. Repo scope: what's actually pushed here

This repo is the `zephyr-mcuboot/` folder, containing the `utat-mcuboot/`
and `utat-mcuboot-v2/` app folders, the Makefile, and this README. It does
**not** include the rest of the Zephyr workspace it sits inside: `zephyr/`,
`bootloader/mcuboot/`, the `build/` output, the board devicetree edit, or the
Python venv. Anyone cloning this repo needs to follow **Clean Build Steps**
below to recreate the full workspace around it.

## 2. Overview

- **Zephyr**: the RTOS the application runs on.
- **MCUboot**: a bootloader, itself a small Zephyr app, that runs first and
  decides which application image to boot.
- **Sysbuild**: builds MCUboot and the application together, coordinated,
  in one command, instead of building/flashing each manually.

Two image slots are used:

- **slot0 (primary)** and **slot1 (secondary)**: each holds a complete
  firmware image.

This project went through two different swap mechanisms before landing on
the final one. See **Section 10** for why the first two didn't give real
button-only A/B swapping, and what the actual working approach turned out
to be.

## 3. Final architecture: swap-using-move + app-triggered toggle

**MCUboot mode:** `swap-using-move` (a physical-swap algorithm, using the
classic image trailer mechanism).

**The toggle mechanism:** every image, right after boot, calls two MCUboot
APIs from `zephyr/dfu/mcuboot.h`:

```c
if (!boot_is_img_confirmed()) {
    boot_write_img_confirmed();
}
boot_request_upgrade(BOOT_UPGRADE_PERMANENT);
```

- `boot_write_img_confirmed()`: marks the currently running image as good,
  so MCUboot won't revert it.
- `boot_request_upgrade(BOOT_UPGRADE_PERMANENT)`: writes to the image
  trailer, telling MCUboot "swap to the other slot, permanently, on the
  next reset."

Because every image runs this same code on boot, each boot arms the
swap for whichever slot isn't currently running. The next physical reset
performs that swap and boots the other image. Which then arms the swap
back. Result: alternation on every reset, driven entirely by the app, no
reflashing required between presses.

## 4. Board flash layout

Chip: STM32L496ZG, 1 MB flash, 2 KB erase page size.

Defined in `zephyr/boards/st/nucleo_l496zg/nucleo_l496zg.dts`:

```dts
chosen {
	...
	zephyr,code-partition = &slot0_partition;
};

&flash0 {
	partitions {
		compatible = "fixed-partitions";
		#address-cells = <1>;
		#size-cells = <1>;

		boot_partition: partition@0 {
			label = "mcuboot";
			reg = <0x00000000 DT_SIZE_K(64)>;
			read-only;
		};

		slot0_partition: partition@10000 {
			label = "image-0";
			reg = <0x00010000 DT_SIZE_K(480)>;
		};

		slot1_partition: partition@88000 {
			label = "image-1";
			reg = <0x00088000 DT_SIZE_K(480)>;
		};
	};
};
```

## 5. Signing

RSA-2048, using MCUboot's bundled example key:

```
bootloader/mcuboot/root-rsa-2048.pem
```

This key is public in the MCUboot repo, so it's
not suitable for anything deployed. Generate a project-specific keypair
before any real use.

## 6. Project structure

Full local workspace (only `zephyr-mcuboot/` is pushed to this repo):

```
zephyrproject/
├── .venv/                    # Python virtual environment (not pushed)
├── .west/                    # west workspace config (not pushed)
├── bootloader/mcuboot/       # MCUboot source (not pushed, pulled by west)
├── build/                    # sysbuild output — MCUboot + v0 (not pushed)
├── modules/                  # other west-managed dependencies (not pushed)
├── tools/                    # (not pushed)
├── zephyr/                   # Zephyr RTOS source (not pushed, pulled by west)
└── zephyr-mcuboot/            <- this repo
    ├── utat-mcuboot/          # v0 app, built via sysbuild, lives in slot0
    ├── utat-mcuboot-v2/       # v1 app, built standalone, flashed to slot1
    ├── Makefile               # automation
    └── README.md              # this file
```

## 7. Automated workflow (Makefile)

```makefile
# MCUboot swap-using-move automation, app-triggered A/B toggle.
# Both apps call boot_request_upgrade() on boot, arming a swap to the
# other slot for the next reset - alternates on reset alone, no reflashing.

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
```

Key targets:

| Target          | What it does                                               |
| --------------- | ---------------------------------------------------------- |
| `make flash-v0` | Builds MCUboot + v0 app together (sysbuild), flashes slot0 |
| `make flash-v1` | Builds v1 app standalone, signs+pads for slot1, flashes it |
| `make erase`    | Full chip erase. See **Section 10** for why this matters   |
| `make all`      | Runs flash-v0 then flash-v1 in sequence                    |
| `make reset`    | Resets the board only, no reflashing                       |
| `make serial`   | Opens a serial terminal to watch boot/swap logs            |
| `make clean`    | Wipes the build directory                                  |

Before first use, edit these values at the top of the Makefile to match
your setup:

- `ZEPHYR_WS`: your actual workspace path, if different
- `SERIAL_PORT`: your board's current `/dev/cu.usbmodemXXXX`

## 8. Typical test cycle

1. `make erase`: start from a fully clean chip (see Section 10. This
   avoids a stale trailer from a previous test session silently overriding
   what you're about to flash).
2. `make flash-v0`: flashes the v0 app to slot0.
3. `make flash-v1`:flashes the v1 app to slot1.
4. `make serial`: watch the boot log.
5. Press reset: MCUboot performs a `test` swap the first time, then `perm`
   on each subsequent reset, alternating which image runs. No further
   flashing needed.

## 9. Known limitations / not yet done

- **Example signing key**
- **pyocd unsupported for this chip family**: pyocd's bundled CMSIS pack
  index has no entry for STM32L496 (or STM32G431, tried as an alternative)
  at time of writing; STM32CubeProgrammer is used instead for all flashing.

## 10. Debugging history: what didn't work, and why

This project went through three different approaches before landing on the
one described above. Documented here so the same dead ends aren't repeated.

### Attempt 1: swap-using-offset (manual re-flash only)

The first working version used `swap-using-offset` mode, with slot1 images
manually re-signed and re-flashed via STM32CubeProgrammer for every test.
This proved the swap/revert mechanism works, but required a full
rebuild+sign+reflash cycle to change which image would win, not real A/B
switching by reset alone. This mode also required sector-offset math
(image starts one erase-sector past the slot's base address, and is signed
one sector smaller than the slot) because of how it reserves space for its
own move operation, a source of significant early debugging (`magic=unset`,
`wrong upload address` errors) before the root cause was understood.

### Attempt 2: direct-xip / direct-xip-with-revert (dead end for this goal)

To avoid needing a reflash per swap, the project switched to `direct-xip`
mode, where both slots hold permanent, independent images and MCUboot picks
whichever has the higher signed version number, no data movement. This
gave real, reliable version-based switching, but not app-triggered
alternation: an app's `boot_request_upgrade()` call was added expecting it
to arm a switch to the other slot, but testing (a raw flash
memory dump comparison before/after reset) proved nothing was being written
by that call in direct-xip mode. This turned out to be architecturally
correct, direct-xip's boot decision is based on the image's _signed_
version header, which is intentionally immutable at runtime; there is no
writable "next boot" flag for the app to set. The classic
`boot_request_upgrade()` / trailer mechanism only exists in swap-based
modes. This was confirmed against MCUboot's own API documentation
(consistently describing the API in "swap" terms) and real-world reports of
the same limitation.

### Attempt 3 (final): swap-using-move + app-triggered toggle

Since real app-triggered alternation requires the writable trailer that
only swap-based modes have, the project moved to `swap-using-move`,
functionally similar to swap-using-offset, but without its sector-offset
math, since move mode doesn't reserve a sector the same way. Combined with
both apps calling `boot_request_upgrade(BOOT_UPGRADE_PERMANENT)` on every
boot, this produced real, reset-only alternation. See Section 3 for the
final working mechanism.

### The "stale trailer" bug that looked like a flash failure

While testing Attempt 3, a confusing bug appeared: flashing a clearly
updated v0 image (confirmed via `printf` identifier lines and a clean
rebuild log) had no visible effect, the board kept running the other
image after reset, as if the new flash had silently failed, even though the
STM32CubeProgrammer log reported success.

**Root cause:** each slot's image trailer (the small MCUboot-owned status
area at the end of the slot, separate from the image itself) is not
touched by a raw STM32CubeProgrammer flash, that tool only writes the
image data at the address you give it. If slot1's trailer still held an
older "permanently swap to me" request from a previous test session, that
stale request would override whatever was newly flashed into slot0:
MCUboot reads the trailer's instruction before considering which image
is "new," and would swap to slot1 regardless of what had just been written
elsewhere. The new v0 flash was real and correct; MCUboot simply never
reached it, because the trailer told it to go straight to slot1 instead.

**Fix:** a full chip erase (`make erase`, added specifically for this)
before starting a fresh test cycle, clearing every slot's trailer along
with the image data, so no stale swap request can survive between sessions.
This is why Section 8's test cycle starts with `make erase`.
