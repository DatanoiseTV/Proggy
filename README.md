# Proggy

A native macOS tool for programming flash, EEPROM, FRAM, SigmaDSP, ESP32, and RP2040/RP2350 devices. Built for embedded engineers who need a fast, no-nonsense programmer that just works.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange)
![License](https://img.shields.io/badge/license-MIT-green)

<img width="1100" height="865" alt="Screenshot 2026-04-03 at 14 46 17" src="https://github.com/user-attachments/assets/5a5f1e47-dad2-4e5b-a88e-808ad9bc115d" />
<img width="1100" height="865" alt="Screenshot 2026-04-03 at 14 46 30" src="https://github.com/user-attachments/assets/007ffe8d-91d2-404d-a4b3-2a6a5a7ee604" />
<img width="1100" height="865" alt="Screenshot 2026-04-03 at 14 46 40" src="https://github.com/user-attachments/assets/c9e34d19-2347-4f8e-99f2-de320fd3332f" />
<img width="1100" height="865" alt="Screenshot 2026-04-03 at 14 46 48" src="https://github.com/user-attachments/assets/16bd0b76-2328-4cb9-91fa-f34418ffb1c8" />
<img width="1100" height="865" alt="Screenshot 2026-04-03 at 14 47 01" src="https://github.com/user-attachments/assets/97f68cf1-b581-4990-a2d0-9fcf30f4d3a8" />


## What it does

- **Flash / EEPROM / FRAM** programming via CH341A (SPI + I2C)
- **ESP32 flashing** via any USB-UART adapter (serial port) with serial monitor
- **RP2040/RP2350 flashing** via Raspberry Pi Debug Probe (CMSIS-DAP/SWD)
- **ADAU14xx SigmaDSP** firmware upload, safeload, biquad EQ, and diagnostics via SPI
- **SPI & I2C terminals** for raw bus communication
- **550+ supported devices** with auto-detection

## Supported Hardware

| Programmer | Interface | Use |
|-----------|-----------|-----|
| CH341A mini programmer | USB (libusb) | SPI flash, I2C EEPROM/FRAM, SPI FRAM, SigmaDSP |
| Any USB-UART adapter | Serial port | ESP32 family flashing |

## Features

### Flash / EEPROM / FRAM Programming (CH341A)
- **SPI Flash** (489 chips) — Read, write, erase, verify, blank check
- **SPI EEPROM** (22 chips) — Microchip 25AA/25LC series
- **SPI FRAM** (16 chips) — Cypress FM25, Fujitsu MB85RS (no erase, instant writes)
- **I2C EEPROM** (32 chips) — 24Cxx series with page-aware writes and ACK polling
- **I2C FRAM** (12 chips) — Cypress FM24, Fujitsu MB85RC (no write delay)
- Auto-detection: JEDEC ID, REMS, RDID for SPI; bus scan + capacity probing for I2C
- Part selector with 550+ devices, searchable, with recently used chips
- Hex editor (NSTableView-backed, smooth at multi-MB), byte editing, undo/redo
- Checksums: CRC32, MD5, SHA256
- Verify after write, blank check, buffer size validation

### ESP32 Flasher (Serial Port)
- Supports **ESP32, ESP32-S2/S3, ESP32-C2/C3/C5/C6/C61, ESP32-H2, ESP32-P4**
- Multi-image: firmware + optional bootloader + partition table, each with offset
- SLIP-framed ROM bootloader protocol with auto chip detection
- Configurable baud rate (115.2k to 2M), erase/verify/reset options
- DTR/RTS reset-to-bootloader sequence
- Built-in serial monitor with baud rate picker and hex mode

### SWD / Pico (Debug Probe)
- **RP2040 and RP2350** flash programming via SWD
- CMSIS-DAP v2 protocol over USB (Raspberry Pi Debug Probe / Picoprobe)
- Auto-detect probe, read target IDCODE
- Halt/resume/reset ARM Cortex-M0+/M33 core
- Firmware loading: `.bin`, `.uf2`, `.elf`
- Pinout reference for debug probe wiring

### SigmaDSP (ADAU14xx) via SPI
- Firmware upload from SigmaStudio `.dat` or `.bin` with full init sequence
- **Safeload** — 28-byte atomic burst write, 1-5 params, float/dB/hex input
- **Biquad EQ** — 5 coefficient write/read with stability check and ADAU negation convention
- Register read/write (16-bit control + 32-bit param RAM with fixed-point display)
- Level meter readback with dB bars
- Live diagnostics: core status, PLL lock, execute count, panic decoder, ASRC lock
- GPIO (MP pin) control, aux ADC read

### SPI Terminal
- Raw hex transfers with chip select control
- Transaction history

### I2C Terminal
- Read/write to any address, register access pattern
- Bus scanner (0x03-0x77 visual grid)
- 20 / 100 / 400 / 750 kHz speed selection

### File Formats
- Binary `.bin`, Intel HEX `.hex`/`.ihex`, SigmaStudio `.dat`
- Open from URL (`Cmd+U`)
- Auto-reload on file change (paused during operations)
- Drag & drop onto window

## Quick Start

```bash
# 1. Install libusb
brew install libusb

# 2. Clone and build
git clone https://github.com/DatanoiseTV/Proggy.git
cd Proggy
make run
```

That's it. The app opens with your CH341A auto-detected.

### Build Variants

```bash
make run           # Debug build, launch .app
make run-release   # Release build, launch .app
make bundle        # Release .app bundle in .build/
```

### Open in Xcode

```bash
open Package.swift
```

## Keyboard Shortcuts

| Action | Shortcut |
|--------|----------|
| Open Binary | `Cmd+O` |
| Open Intel HEX | `Cmd+Shift+O` |
| Open from URL | `Cmd+U` |
| Save as Binary | `Cmd+S` |
| Save as Intel HEX | `Cmd+Shift+S` |
| Undo / Redo | `Cmd+Z` / `Cmd+Shift+Z` |
| Connect / Disconnect | `Cmd+K` / `Cmd+Shift+K` |
| Auto-Detect | `Cmd+D` |
| Read / Write / Verify | `Cmd+Shift+R` / `W` / `V` |
| Cancel | `Cmd+.` |

## Project Structure

```
Sources/
  CLibUSB/                  # libusb C bridge (system library)
  Proggy/
    App/                    # SwiftUI app, menus, icon
    Core/
      CH341Device.swift     # USB layer (libusb)
      CH341SPI.swift        # SPI protocol (bit-reversal, CS control)
      CH341I2C.swift        # I2C protocol (start/stop/read/write/scan)
      CH341Flash.swift      # SPI flash operations (JEDEC, page program)
      CH341I2CEEPROM.swift  # I2C EEPROM page-aware R/W
      CH341FRAM.swift       # SPI + I2C FRAM (no erase, no delay)
      CH341AutoDetect.swift # Multi-method chip detection
      CH341DSP.swift        # ADAU14xx SigmaDSP over SPI
      ESPProtocol.swift     # ESP32 SLIP bootloader protocol
      SWDProtocol.swift     # CMSIS-DAP/SWD for RP2040/RP2350
      SerialPort.swift      # macOS serial port (IOKit + termios)
    Models/
      ChipDatabase.swift    # JEDEC ID lookup
      FileFormats.swift     # Intel HEX + SigmaStudio parsers
      HexDataBuffer.swift   # Buffer with undo/redo + checksums
    ViewModels/             # @Observable state for each tab
    Views/                  # SwiftUI (hex editor, ZIF graphic, etc.)
```

## Requirements

- macOS 14 (Sonoma) or later
- `brew install libusb`
- CH341A programmer (for flash/EEPROM/FRAM/DSP)
- Any USB-UART adapter (for ESP32 flashing)
- Raspberry Pi Debug Probe or Picoprobe (for RP2040/RP2350 via SWD)

## License

MIT
