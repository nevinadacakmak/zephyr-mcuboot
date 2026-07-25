# MCUboot on Nucleo L496ZG — Setup & Swap Testing

Implementation notes for running MCUboot with Zephyr on the STM32L496ZG-NUCLEO,
including a working flippable-firmware (slot0/slot1 swap) test setup.

Reference: [Building and using MCUboot with Zephyr](https://docs.mcuboot.com/readme-zephyr.html)
Reference: [MCUBoot Implementation Guide](https://git.jeremyjanella.com/jjanella/mcuboot-guide-utat)

## Overview

- **Zephyr** — the RTOS the application runs on.
- **MCUboot** — a bootloader, itself a small Zephyr app, that runs first and
  decides which application image to boot.
- **Sysbuild** — builds MCUboot and the application together, coordinated, in
  one command, instead of building/flashing each manually.

Two image slots are used:

- **slot0 (primary)** — the currently running image.
- **slot1 (secondary)** — a candidate image. On reboot, MCUboot can swap it
  into slot0, test-boot it, and revert automatically if it's never confirmed.

## Board flash layout

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

No `scratch_partition` is used — per the
[MCUboot docs](https://docs.mcuboot.com/readme-zephyr.html), swap-using-scratch
is not recommended, so this project uses **swap-using-offset** instead
(the current MCUboot default), which needs no scratch partition.

## Swap algorithm: swap-using-offset

Confirmed via:

```
grep -i "SWAP_USING" build/mcuboot/zephyr/.config
```

In this mode, MCUboot reserves the **first flash sector** (2 KB on this chip)
of slot1 for its own bookkeeping. This means:

- The image must be **flashed one sector (0x800) past slot1's base address**
  → `0x08088000 + 0x800 = 0x08088800`
- The signed image must be **padded to the slot size minus one sector**
  → `0x78000 - 0x800 = 0x77800`

Flashing at the raw slot1 base address, or padding to the full slot size,
both fail — MCUboot rejects the image as invalid or the flash tool reports
an out-of-bounds write.

## Signing

Signing is active by default (RSA-2048), using MCUboot's bundled example key:

```
bootloader/mcuboot/root-rsa-2048.pem
```

This is fine for development, but this key is public in the MCUboot repo —
**not suitable for anything deployed**. A project-specific keypair should be
generated before any real use (see the
[MCUboot docs](https://docs.mcuboot.com/readme-zephyr.html) section on
managing signing keys).

## Automated workflow (Makefile)

See `Makefile` in the workspace root. Key targets:

| Target          | What it does                                               |
| --------------- | ---------------------------------------------------------- |
| `make flash-v0` | Builds MCUboot + v0 app together (sysbuild), flashes slot0 |
| `make flash-v1` | Builds v1 app standalone, signs+pads for slot1, flashes it |
| `make all`      | Runs both of the above in sequence                         |
| `make reset`    | Resets the board only, no reflashing                       |
| `make serial`   | Opens a serial terminal to watch boot/swap logs            |
| `make clean`    | Wipes the build directory                                  |

**Before first use**, edit these values at the top of the Makefile to match
your setup:

- `SERIAL_PORT` — your board's current `/dev/cu.usbmodemXXXX` (this can
  change between USB reconnects — check with `ls /dev/cu.usbmodem*`)

## Typical test cycle

1. `make flash-v0` — sets the baseline image in slot0.
2. `make flash-v1` — puts a new candidate image in slot1.
3. `make serial` — watch the boot log.
4. Reset the board — MCUboot detects the slot1 image, swaps it in as a
   **test** boot (`Swap type: test`), and boots it.
5. Reset again **without confirming** — MCUboot reverts back to the
   original slot0 image automatically (`Swap type: revert`).

Note: swap-using-offset (and swap-using-move) **physically move** image data
between slots during a swap. After a full swap or revert completes, the slot
that lost its image is left empty — this is expected, not a bug. To test
swapping again, a fresh image needs to be signed and reflashed into slot1.

## Known limitations / not yet done

- **No permanent confirm** — the running v1 image never calls MCUboot's
  confirm API (e.g. `boot_write_img_confirmed()`), so every swap is
  currently a one-shot test that reverts on the next reset by design.
- **Example signing key** — see Signing section above.
- **Manual flashing only** — slot1 images are flashed via debugger
  (STM32CubeProgrammer), not a real update mechanism (serial/DFU/MCUmgr).
- **pyocd unsupported for this chip** — pyocd's bundled CMSIS pack index has
  no entry for STM32L496 at time of writing; STM32CubeProgrammer is used
  instead for all flashing.
