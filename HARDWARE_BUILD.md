# ER-301 TXo I2C Output — Hardware Build Guide

## What This Is

A custom ER-301 firmware mod that adds I2C master (leader) capability,
allowing the ER-301 to send CV and gate data to TELEXo (TXo) modules
over the I2C bus. This gives the ER-301 CV/gate output through the
TXo's 4 CV + 4 TR hardware outputs.

## What Has Been Done (on macOS)

- Forked ER-301 repo: https://github.com/stolmine/er-301-stolmine
- Branch: `feature/txo-i2c-output`
- Extended the I2C HAL with master TX API (`hal/i2c.h`)
- AM335x hardware driver: `arch/am335x/hal/i2cMaster.c`
- TXo mod package: `mods/txo/` (C++ objects, SWIG bindings, Lua units)
- Two units: TXo CV (with gain control + V/Oct mode) and TXo TR (gate output with threshold)
- Emulator testing confirmed working on macOS — voltage scaling verified:
  - Gain 1.0 = ±5V, Gain 2.0 = ±10V, Gain 0.5 = ±2.5V
- Build system fixes: darwin gcc-15 compat, mod linker flags

## What Needs To Be Done (on this Linux machine)

Cross-compile the firmware and TXo mod for the AM335x (ER-301 hardware).

### 1. Install Dependencies

```bash
# Arch/Endeavour
sudo pacman -S base-devel swig python zip lib32-glibc wget

# Ubuntu/Debian (if using a VM instead)
sudo apt install build-essential swig python3 zip gcc-multilib wget
```

### 2. Install TI Processor SDK RTOS

**Must be version 04.01.00.06. Must install to ~/ti.**

```bash
wget http://software-dl.ti.com/processor-sdk-rtos/esd/AM335X/04_01_00_06/exports/ti-processor-sdk-rtos-am335x-evm-04.01.00.06-Linux-x86-Install.bin -O ti-sdk.bin
chmod +x ti-sdk.bin
./ti-sdk.bin --prefix ~/ti --mode unattended
rm ti-sdk.bin
```

Verify it installed correctly:
```bash
ls ~/ti/gcc-arm-none-eabi-4_9-2015q3/bin/arm-none-eabi-gcc
ls ~/ti/xdctools_3_32_01_22_core/xs
ls ~/ti/bios_6_46_05_55/packages
ls ~/ti/pdk_am335x_1_0_8/packages
```

### 3. Clone and Build

```bash
git clone git@github.com:stolmine/er-301-stolmine.git
cd er-301-stolmine
git checkout feature/txo-i2c-output

# Build firmware (includes the I2C master HAL changes)
make firmware ARCH=am335x

# Build the TXo mod package
make txo ARCH=am335x
```

If TI SDK is not in ~/ti, pass the path:
```bash
make firmware ARCH=am335x TI_INSTALL_DIR=/path/to/ti
make txo ARCH=am335x TI_INSTALL_DIR=/path/to/ti
```

### 4. Collect Build Outputs

The files you need for the ER-301 SD card:

```bash
# Firmware binary
find . -name 'kernel.bin' -path '*/am335x/*'

# TXo mod package
ls testing/am335x/mods/txo-*.pkg
```

### 5. Install on ER-301 Hardware

1. **Firmware**: Copy `kernel.bin` to the ER-301's rear SD card root
   (this replaces the stock firmware — keep a backup of the original!)
2. **TXo package**: Copy `txo-*.pkg` to `front SD/ER-301/packages/`
3. Boot the ER-301
4. Go to Package Manager, install the TXo package
5. Open the TXo Library config menu, enable I2C master
6. Insert TXo CV or TXo TR units in your signal chains

### 6. Hardware I2C Wiring

Connect the ER-301's I2C header to the TXo's I2C header:
- GND → GND
- SCL → SCL
- SDA → SDA

**Pin order varies between modules — check documentation before connecting.**

The TXo default address is 0x60 (set via jumpers on the TXo PCB).

## Architecture Overview

```
ER-301 signal chain
       │
   ┌───▼───┐
   │TXo CV │  (captures signal, applies gain)
   │ unit   │
   └───┬───┘
       │ writes to shared state
   ┌───▼──────────┐
   │TXo Dispatcher│  (Task on audio thread, rate-limited)
   │              │  sends I2C commands via HAL
   └───┬──────────┘
       │ I2c_sendMessage()
   ┌───▼──────────┐
   │AM335x I2C2   │  (polled master TX, lock-free queue)
   │  hardware    │
   └───┬──────────┘
       │ I2C bus (SCL/SDA)
   ┌───▼───┐
   │ TXo   │  (follower at 0x60, 16-bit DAC)
   │module  │
   └───────┘
```

## Troubleshooting

- **Build fails with missing TI tools**: Verify TI SDK paths with the `ls` commands in step 2
- **lib32-glibc errors on Arch**: The TI installer is 32-bit x86, needs multilib
- **I2C not working on hardware**: Pre-Rev 10 ER-301 boards may need diode D3 shorted for SDA line
- **Bus lockup**: Only occurs if two masters transmit to the same address simultaneously. Keep Teletype/other masters addressing different followers.
