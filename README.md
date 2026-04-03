# Proggy

A native macOS application for programming flash, EEPROM, and SigmaDSP devices via the **CH341A** USB programmer.

Built in Swift/SwiftUI. No Electron, no web views — just a fast, native tool for embedded engineers.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange)
![License](https://img.shields.io/badge/license-MIT-green)

## Features

### Flash / EEPROM Programming
- **SPI Flash** — Read, write, erase, verify, blank check for 25xx series (Winbond, GigaDevice, Macronix, ISSI, Micron, Spansion, SST, Atmel, XTX, Puya, Boya)
- **I2C EEPROM** — Full page-aware read/write for 24Cxx series (1-byte and 2-byte addressing, ACK polling, proper write cycle timing)
- **Auto-detection** — JEDEC ID (0x9F), REMS (0x90), RDID (0xAB) for SPI; bus scan + capacity probing for I2C
- **70+ chips** in the built-in part selector, searchable by manufacturer
- **Verify after write** with optional toggle
- **Hex editor** — NSTableView-backed for smooth scrolling even with multi-MB files; byte editing with undo/redo
- **Checksums** — CRC32, MD5, SHA256

### SPI Terminal
- Raw hex SPI transfers with response display
- Manual chip select control (keep CS low between transfers)
- Transaction history with timestamps

### I2C Terminal
- Read/write to any 7-bit address
- Register read (write-then-read) pattern
- **Bus scanner** — visual grid showing all responding devices (0x03–0x77)
- Speed selection: 20 kHz / 100 kHz / 400 kHz / 750 kHz

### SigmaDSP (ADAU14xx)
- **SPI-based firmware upload** to ADAU1401/1701/1452/1462/1466
- Parses SigmaStudio `.dat` exports (TxBuffer + NumBytes) or pre-compiled `.bin`
- Full init sequence: SPI mode entry, soft reset, PLL config, lock wait, firmware upload, core start
- **Safeload** — glitch-free parameter updates with float/dB/hex input
- **Register read/write** — 16-bit control registers and 32-bit parameter RAM with fixed-point display
- **Live diagnostics** — core status, PLL lock, execute count, panic flag decoder, ASRC lock status
- Configurable pre-PLL record skip with built-in explanation

### File Format Support
- **Binary** (`.bin`) — raw read/write
- **Intel HEX** (`.hex`, `.ihex`) — full import/export with extended address records
- **SigmaStudio** (`.dat`) — TxBuffer/NumBytes conversion with chip-size padding for EEPROM images
- **URL download** — fetch firmware directly from a web URL
- **Auto-reload** — watches loaded file for changes, reloads automatically (paused during flash operations)
- **Drag & drop** — drop files onto the window

### Hardware
- **CH341A hotplug** — automatic detection when the programmer is plugged in or removed
- **ZIF-16 socket diagram** — visual pinout showing I2C (top 8 pins) and SPI (bottom 8 pins) placement
- Buffer size validation with utilization bar

## Requirements

- macOS 14 (Sonoma) or later
- [libusb](https://libusb.info/) — `brew install libusb`
- A CH341A USB programmer

## Building

```bash
# Install libusb
brew install libusb

# Build and run as .app bundle
make run

# Or build release
make bundle
open .build/Proggy.app
```

To open in Xcode:
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
| Undo | `Cmd+Z` |
| Redo | `Cmd+Shift+Z` |
| Connect | `Cmd+K` |
| Disconnect | `Cmd+Shift+K` |
| Auto-Detect | `Cmd+D` |
| Read Chip | `Cmd+Shift+R` |
| Write Chip | `Cmd+Shift+W` |
| Verify Chip | `Cmd+Shift+V` |
| Cancel Operation | `Cmd+.` |

## Architecture

```
Sources/
  CLibUSB/              # libusb system library bridge
  Proggy/
    App/                 # App entry point, icon generator
    Core/                # CH341A protocol: USB, SPI, I2C, Flash, DSP
    Models/              # Chip database, hex buffer, file formats
    ViewModels/          # Device manager, SPI/I2C/DSP view models
    Views/               # SwiftUI views, hex editor, ZIF socket graphic
```

## License

MIT
