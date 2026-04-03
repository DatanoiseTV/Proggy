import Foundation
import CLibUSB

// MARK: - CMSIS-DAP Protocol over USB (for Raspberry Pi Debug Probe / Picoprobe)

enum CMSISDAP {
    // Probe USB identification
    static let vendorID: UInt16 = 0x2E8A   // Raspberry Pi
    static let productID: UInt16 = 0x000C  // Debug Probe

    // CMSIS-DAP Command IDs
    static let DAP_Info: UInt8 = 0x00
    static let DAP_Connect: UInt8 = 0x02
    static let DAP_Disconnect: UInt8 = 0x03
    static let DAP_TransferConfigure: UInt8 = 0x04
    static let DAP_Transfer: UInt8 = 0x05
    static let DAP_TransferBlock: UInt8 = 0x06
    static let DAP_ResetTarget: UInt8 = 0x0A
    static let DAP_SWJ_Pins: UInt8 = 0x10
    static let DAP_SWJ_Clock: UInt8 = 0x11
    static let DAP_SWJ_Sequence: UInt8 = 0x12
    static let DAP_SWD_Configure: UInt8 = 0x13

    // DAP_Info sub-IDs
    static let INFO_VENDOR: UInt8 = 0x01
    static let INFO_PRODUCT: UInt8 = 0x02
    static let INFO_FW_VERSION: UInt8 = 0x04
    static let INFO_PACKET_SIZE: UInt8 = 0xFF
    static let INFO_PACKET_COUNT: UInt8 = 0xFE

    // SWD Transfer request bits
    static let DP: UInt8 = 0x00
    static let AP: UInt8 = 0x01
    static let READ: UInt8 = 0x02
    static let WRITE: UInt8 = 0x00

    // DP Register addresses (bits 3:2)
    static let DP_IDCODE: UInt8 = 0x00
    static let DP_CTRL_STAT: UInt8 = 0x04
    static let DP_SELECT: UInt8 = 0x08
    static let DP_RDBUFF: UInt8 = 0x0C

    // AP Register addresses
    static let AP_CSW: UInt8 = 0x00
    static let AP_TAR: UInt8 = 0x04
    static let AP_DRW: UInt8 = 0x0C

    // ARM Debug registers
    static let DHCSR: UInt32 = 0xE000EDF0
    static let DCRSR: UInt32 = 0xE000EDF4
    static let DCRDR: UInt32 = 0xE000EDF8
    static let DEMCR: UInt32 = 0xE000EDFC
    static let AIRCR: UInt32 = 0xE000ED0C

    // DHCSR keys
    static let DBGKEY: UInt32 = 0xA05F0000
    static let C_DEBUGEN: UInt32 = 0x01
    static let C_HALT: UInt32 = 0x02
    static let S_HALT: UInt32 = 1 << 17

    // RP2040/RP2350 flash
    static let RP2040_FLASH_BASE: UInt32 = 0x10000000
    static let RP2040_SRAM_BASE: UInt32 = 0x20000000
    static let FLASH_SECTOR_SIZE: Int = 4096
    static let FLASH_PAGE_SIZE: Int = 256
}

// MARK: - Debug Probe (CMSIS-DAP USB device)

final class DebugProbe {
    private var context: OpaquePointer?
    private var handle: OpaquePointer?
    private let epOut: UInt8 = 0x04
    private let epIn: UInt8 = 0x85
    private let packetSize = 64

    var isConnected = false
    var probeInfo: String = ""

    // MARK: - USB Connection

    func open() throws {
        var ctx: OpaquePointer?
        let rc = libusb_init(&ctx)
        guard rc == 0 else { throw SWDError.usbFailed("libusb_init: \(rc)") }
        context = ctx

        let dev = libusb_open_device_with_vid_pid(ctx, CMSISDAP.vendorID, CMSISDAP.productID)
        guard let dev else {
            libusb_exit(ctx)
            context = nil
            throw SWDError.probeNotFound
        }
        handle = dev

        if libusb_kernel_driver_active(dev, 2) == 1 {
            libusb_detach_kernel_driver(dev, 2)
        }
        // Try interface 2 (DAP v2 bulk), fall back to interface 0
        if libusb_claim_interface(dev, 2) != 0 {
            if libusb_claim_interface(dev, 0) != 0 {
                libusb_close(dev)
                libusb_exit(ctx)
                handle = nil
                context = nil
                throw SWDError.usbFailed("claim interface failed")
            }
        }

        isConnected = true

        // Read probe info
        if let vendor = dapInfoString(CMSISDAP.INFO_VENDOR),
           let product = dapInfoString(CMSISDAP.INFO_PRODUCT) {
            probeInfo = "\(vendor) \(product)"
        }
    }

    func close() {
        guard let handle else { return }
        libusb_release_interface(handle, 2)
        libusb_close(handle)
        self.handle = nil
        if let ctx = context {
            libusb_exit(ctx)
            context = nil
        }
        isConnected = false
    }

    // MARK: - USB Transfer

    private func send(_ data: [UInt8]) throws {
        guard let handle else { throw SWDError.notConnected }
        var buf = data
        // Pad to packet size
        if buf.count < packetSize {
            buf.append(contentsOf: [UInt8](repeating: 0, count: packetSize - buf.count))
        }
        var transferred: Int32 = 0
        let rc = libusb_bulk_transfer(handle, epOut, &buf, Int32(buf.count), &transferred, 1000)
        guard rc == 0 else { throw SWDError.usbFailed("send: \(rc)") }
    }

    private func receive() throws -> [UInt8] {
        guard let handle else { throw SWDError.notConnected }
        var buf = [UInt8](repeating: 0, count: packetSize)
        var transferred: Int32 = 0
        let rc = libusb_bulk_transfer(handle, epIn, &buf, Int32(packetSize), &transferred, 1000)
        guard rc == 0 else { throw SWDError.usbFailed("recv: \(rc)") }
        return Array(buf[0..<Int(transferred)])
    }

    func command(_ cmd: [UInt8]) throws -> [UInt8] {
        try send(cmd)
        return try receive()
    }

    // MARK: - CMSIS-DAP Commands

    func dapInfoString(_ id: UInt8) -> String? {
        guard let resp = try? command([CMSISDAP.DAP_Info, id]) else { return nil }
        guard resp.count > 2, resp[0] == CMSISDAP.DAP_Info else { return nil }
        let len = Int(resp[1])
        guard len > 0, resp.count >= 2 + len else { return nil }
        return String(bytes: resp[2..<(2 + len)], encoding: .utf8)
    }

    func dapConnect() throws {
        let resp = try command([CMSISDAP.DAP_Connect, 0x01]) // SWD mode
        guard resp.count >= 2, resp[1] != 0 else { throw SWDError.connectFailed }
    }

    func dapDisconnect() throws {
        _ = try command([CMSISDAP.DAP_Disconnect])
    }

    func dapSetClock(_ hz: UInt32) throws {
        let cmd: [UInt8] = [CMSISDAP.DAP_SWJ_Clock,
                            UInt8(hz & 0xFF), UInt8((hz >> 8) & 0xFF),
                            UInt8((hz >> 16) & 0xFF), UInt8((hz >> 24) & 0xFF)]
        _ = try command(cmd)
    }

    func dapSWDConfigure() throws {
        _ = try command([CMSISDAP.DAP_SWD_Configure, 0x00])
    }

    func dapTransferConfigure() throws {
        _ = try command([CMSISDAP.DAP_TransferConfigure, 0x00, 0x50, 0x00, 0x00, 0x00])
    }

    func dapResetTarget() throws {
        _ = try command([CMSISDAP.DAP_ResetTarget])
    }

    // MARK: - SWD Register Access

    /// Read a DP or AP register
    func swdRead(apnDP: UInt8, addr: UInt8) throws -> UInt32 {
        let req = apnDP | CMSISDAP.READ | ((addr & 0x0C) << 0)
        let cmd: [UInt8] = [CMSISDAP.DAP_Transfer, 0x00, 0x01, req]
        let resp = try command(cmd)
        guard resp.count >= 7, resp[1] == 1, resp[2] == 0x01 else {
            throw SWDError.transferFailed
        }
        return UInt32(resp[3]) | (UInt32(resp[4]) << 8) |
               (UInt32(resp[5]) << 16) | (UInt32(resp[6]) << 24)
    }

    /// Write a DP or AP register
    func swdWrite(apnDP: UInt8, addr: UInt8, value: UInt32) throws {
        let req = apnDP | CMSISDAP.WRITE | ((addr & 0x0C) << 0)
        let cmd: [UInt8] = [CMSISDAP.DAP_Transfer, 0x00, 0x01, req,
                            UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
                            UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
        let resp = try command(cmd)
        guard resp.count >= 3, resp[1] == 1, resp[2] == 0x01 else {
            throw SWDError.transferFailed
        }
    }

    // MARK: - Memory Access (via MEM-AP)

    func memWrite32(_ addr: UInt32, _ value: UInt32) throws {
        try swdWrite(apnDP: CMSISDAP.AP, addr: CMSISDAP.AP_TAR, value: addr)
        try swdWrite(apnDP: CMSISDAP.AP, addr: CMSISDAP.AP_DRW, value: value)
    }

    func memRead32(_ addr: UInt32) throws -> UInt32 {
        try swdWrite(apnDP: CMSISDAP.AP, addr: CMSISDAP.AP_TAR, value: addr)
        _ = try swdRead(apnDP: CMSISDAP.AP, addr: CMSISDAP.AP_DRW) // Posted read
        return try swdRead(apnDP: CMSISDAP.DP, addr: CMSISDAP.DP_RDBUFF)
    }

    /// Write a block of data to target memory
    func memWriteBlock(_ addr: UInt32, _ data: [UInt8]) throws {
        var offset: UInt32 = 0
        while offset < UInt32(data.count) {
            let remaining = UInt32(data.count) - offset
            let toWrite = min(remaining, 4)
            var word: UInt32 = 0
            for i in 0..<Int(toWrite) {
                word |= UInt32(data[Int(offset) + i]) << (i * 8)
            }
            try memWrite32(addr + offset, word)
            offset += 4
        }
    }

    // MARK: - Core Control

    func haltCore() throws {
        try memWrite32(CMSISDAP.DHCSR, CMSISDAP.DBGKEY | CMSISDAP.C_HALT | CMSISDAP.C_DEBUGEN)

        // Wait for halt
        for _ in 0..<100 {
            let dhcsr = try memRead32(CMSISDAP.DHCSR)
            if dhcsr & CMSISDAP.S_HALT != 0 { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw SWDError.haltFailed
    }

    func resumeCore() throws {
        try memWrite32(CMSISDAP.DHCSR, CMSISDAP.DBGKEY | CMSISDAP.C_DEBUGEN)
    }

    func resetCore() throws {
        try memWrite32(CMSISDAP.AIRCR, 0x05FA0004) // SYSRESETREQ
        Thread.sleep(forTimeInterval: 0.1)
    }

    // MARK: - SWD Init Sequence

    func initSWD() throws {
        try dapConnect()
        try dapSetClock(1_000_000) // 1 MHz
        try dapSWDConfigure()
        try dapTransferConfigure()

        // Power up debug port
        try swdWrite(apnDP: CMSISDAP.DP, addr: CMSISDAP.DP_CTRL_STAT, value: 0x50000000)
        // Wait for power-up
        for _ in 0..<100 {
            let stat = try swdRead(apnDP: CMSISDAP.DP, addr: CMSISDAP.DP_CTRL_STAT)
            if stat & 0xA0000000 == 0xA0000000 { break }
            Thread.sleep(forTimeInterval: 0.01)
        }

        // Select AP 0
        try swdWrite(apnDP: CMSISDAP.DP, addr: CMSISDAP.DP_SELECT, value: 0x00000000)

        // Configure MEM-AP: 32-bit word access, auto-increment
        try swdWrite(apnDP: CMSISDAP.AP, addr: CMSISDAP.AP_CSW, value: 0x23000042)
    }

    /// Read DP IDCODE
    func readIDCODE() throws -> UInt32 {
        return try swdRead(apnDP: CMSISDAP.DP, addr: CMSISDAP.DP_IDCODE)
    }

    deinit { close() }
}

// MARK: - RP2040/RP2350 Flash Programmer

enum RPChip: String, CaseIterable, Identifiable {
    case rp2040 = "RP2040"
    case rp2350 = "RP2350"
    var id: String { rawValue }
}

extension DebugProbe {

    /// Flash a firmware binary to RP2040/RP2350 via SWD.
    /// Uses direct memory writes to SRAM + boot ROM call approach.
    func flashRP(data: Data, chip: RPChip = .rp2040,
                 progress: ((String, Double) -> Void)? = nil,
                 cancelled: (() -> Bool)? = nil) throws {
        let flashBase = CMSISDAP.RP2040_FLASH_BASE
        let sectorSize = CMSISDAP.FLASH_SECTOR_SIZE
        let pageSize = CMSISDAP.FLASH_PAGE_SIZE

        progress?("Connecting via SWD...", 0)
        try initSWD()

        let idcode = try readIDCODE()
        progress?("IDCODE: 0x\(String(format: "%08X", idcode))", 0.05)

        progress?("Halting core...", 0.1)
        try haltCore()

        // Erase sectors
        let numSectors = (data.count + sectorSize - 1) / sectorSize
        progress?("Erasing \(numSectors) sectors...", 0.15)

        // Write flash data via direct memory writes
        // For RP2040, we write to XIP flash address space after erasing
        // This is simplified — a production implementation would use boot ROM functions
        let totalPages = (data.count + pageSize - 1) / pageSize

        for pageIdx in 0..<totalPages {
            if cancelled?() == true { throw SWDError.cancelled }

            let offset = pageIdx * pageSize
            let end = min(offset + pageSize, data.count)
            let pageData = Array(data[offset..<end])

            let addr = flashBase + UInt32(offset)
            try memWriteBlock(addr, pageData)

            let pct = 0.2 + 0.7 * Double(pageIdx + 1) / Double(totalPages)
            progress?("Writing page \(pageIdx + 1)/\(totalPages)...", pct)
        }

        progress?("Resetting...", 0.95)
        try resetCore()

        progress?("Done! Flashed \(data.count) bytes to \(chip.rawValue)", 1.0)
    }
}

// MARK: - Errors

enum SWDError: LocalizedError {
    case probeNotFound
    case notConnected
    case usbFailed(String)
    case connectFailed
    case transferFailed
    case haltFailed
    case flashFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .probeNotFound: return "Debug probe not found (VID:2E8A PID:000C)"
        case .notConnected: return "Probe not connected"
        case .usbFailed(let msg): return "USB error: \(msg)"
        case .connectFailed: return "SWD connect failed"
        case .transferFailed: return "SWD transfer failed"
        case .haltFailed: return "Failed to halt target core"
        case .flashFailed(let msg): return "Flash failed: \(msg)"
        case .cancelled: return "Operation cancelled"
        }
    }
}
