import Foundation

// MARK: - ADAU14xx SigmaDSP over I2C via CH341A

struct ADAU14xx {
    // I2C addresses (7-bit, based on ADDR0/ADDR1 pins)
    static let defaultAddress: UInt8 = 0x38

    // Control Register Map
    static let PLL_CTRL0: UInt16    = 0xF000
    static let PLL_CTRL1: UInt16    = 0xF001
    static let PLL_CLK_SRC: UInt16  = 0xF002
    static let PLL_ENABLE: UInt16   = 0xF003
    static let PLL_LOCK: UInt16     = 0xF004
    static let MCLK_OUT: UInt16     = 0xF005
    static let PLL_WATCHDOG: UInt16 = 0xF006

    static let POWER_ENABLE0: UInt16 = 0xF050
    static let POWER_ENABLE1: UInt16 = 0xF051

    static let HIBERNATE: UInt16     = 0xF400
    static let CORE_STATUS: UInt16   = 0xF401
    static let START_CORE: UInt16    = 0xF402
    static let KILL_CORE: UInt16     = 0xF403
    static let START_PULSE: UInt16   = 0xF404

    static let PANIC_FLAG: UInt16    = 0xF428
    static let PANIC_CODE: UInt16    = 0xF429
    static let PANIC_CLEAR: UInt16   = 0xF42A
    static let EXECUTE_COUNT: UInt16 = 0xF432

    static let ASRC_LOCK: UInt16     = 0xF580
    static let SOFT_RESET: UInt16    = 0xF890

    // Safeload registers
    static let SAFELOAD_DATA0: UInt16  = 0x6000
    static let SAFELOAD_ADDR: UInt16   = 0x6005
    static let SAFELOAD_TRIGGER: UInt16 = 0x6006

    // Memory regions
    static let PROGRAM_RAM_START: UInt16 = 0x0000
    static let PROGRAM_RAM_END: UInt16   = 0x3FFF
    static let DATA_MEM_START: UInt16    = 0x4000
    static let DATA_MEM_END: UInt16      = 0xEFFF
    static let CONTROL_REG_START: UInt16 = 0xF000

    // Core status values
    enum CoreStatus: UInt16 {
        case notRunning = 0
        case running = 1
        case paused = 2
        case sleeping = 3
        case stalled = 4
        case unknown = 0xFFFF

        var description: String {
            switch self {
            case .notRunning: return "Not Running"
            case .running: return "Running"
            case .paused: return "Paused"
            case .sleeping: return "Sleeping"
            case .stalled: return "Stalled"
            case .unknown: return "Unknown"
            }
        }
    }

    /// Bytes per word for a given address region
    static func bytesPerWord(address: UInt16) -> Int {
        if address >= CONTROL_REG_START { return 2 }
        if address >= DATA_MEM_START { return 4 }
        return 5  // Program RAM = 40-bit instructions
    }
}

// MARK: - DSP SPI Operations
//
// ADAU14xx SPI protocol (Mode 3, CPOL=1 CPHA=1, MSB-first):
//   Write: [0x00] [addr_hi] [addr_lo] [data...]   (chip_addr=0 + W bit=0)
//   Read:  [0x01] [addr_hi] [addr_lo] [dummy...]   (chip_addr=0 + R bit=1)
//
// The CH341A SPI stream handles bit-reversal internally via spiExchange().
// We use raw CS control + SPI transfer for each DSP transaction.

extension CH341Device {

    // MARK: - SPI Low-Level

    /// SPI write to DSP: [0x00][addr_hi][addr_lo][data...]
    func dspSPIWrite(reg: UInt16, data: [UInt8]) throws {
        var packet: [UInt8] = [0x00, UInt8((reg >> 8) & 0xFF), UInt8(reg & 0xFF)]
        packet.append(contentsOf: data)
        _ = try spiExchange(data: packet)
    }

    /// SPI read from DSP: [0x01][addr_hi][addr_lo][dummy * count] → response bytes after header
    func dspSPIRead(reg: UInt16, count: Int) throws -> [UInt8] {
        var packet: [UInt8] = [0x01, UInt8((reg >> 8) & 0xFF), UInt8(reg & 0xFF)]
        packet.append(contentsOf: [UInt8](repeating: 0x00, count: count))
        let response = try spiExchange(data: packet)
        // Response: first 3 bytes are header echo, data starts at index 3
        guard response.count >= 3 + count else { throw CH341Error.transferFailed(-1) }
        return Array(response[3..<(3 + count)])
    }

    // MARK: - Register Access

    /// Write a 16-bit control register
    func dspWriteReg(_ reg: UInt16, value: UInt16) throws {
        try dspSPIWrite(reg: reg, data: [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }

    /// Read a 16-bit control register
    func dspReadReg(_ reg: UInt16) throws -> UInt16 {
        let data = try dspSPIRead(reg: reg, count: 2)
        return (UInt16(data[0]) << 8) | UInt16(data[1])
    }

    /// Write a block of data to DSP memory (burst write with chunking)
    func dspWriteBlock(startAddr: UInt16, data: [UInt8]) throws {
        // CH341A SPI payload limit per transfer is ~29 bytes (31 - 2 for cmd overhead)
        // Chunk to 24 bytes data per SPI transfer, aligned to word boundaries
        let maxPayload = 24
        var offset = 0
        let bpw = ADAU14xx.bytesPerWord(address: startAddr)

        while offset < data.count {
            let remaining = data.count - offset
            let chunkSize = min(maxPayload, remaining)
            // Align to word boundary
            let aligned = max((chunkSize / bpw) * bpw, min(bpw, remaining))
            let toSend = min(aligned, remaining)

            let currentAddr = startAddr + UInt16(offset / bpw)
            try dspSPIWrite(reg: currentAddr, data: Array(data[offset..<(offset + toSend)]))
            offset += toSend
        }
    }

    /// Read a 32-bit parameter/data memory value
    func dspReadParam(_ addr: UInt16) throws -> UInt32 {
        let data = try dspSPIRead(reg: addr, count: 4)
        return (UInt32(data[0]) << 24) | (UInt32(data[1]) << 16) |
               (UInt32(data[2]) << 8) | UInt32(data[3])
    }

    // MARK: - Edge-triggered register helpers

    /// Pulse a register: write 0 then 1 (for edge-triggered registers like PLL_ENABLE, START_CORE)
    func dspPulseReg(_ reg: UInt16) throws {
        try dspWriteReg(reg, value: 0x0000)
        try dspWriteReg(reg, value: 0x0001)
    }

    // MARK: - SPI Mode Entry

    /// After power-on or soft reset, DSP defaults to I2C.
    /// To enter SPI mode: send 3 dummy bytes on MOSI with CS HIGH, then proceed normally.
    func dspEnterSPIMode() throws {
        // Deassert CS (HIGH), send dummy bytes
        try spiChipSelect(false)
        // Small delay, then assert CS and send 3 dummy bytes
        // Actually: just toggle CS with some dummy traffic
        _ = try spiExchange(data: [0xFF, 0xFF, 0xFF])
    }

    // MARK: - High-level DSP Operations

    func dspSoftReset() throws {
        try dspPulseReg(ADAU14xx.SOFT_RESET)
        Thread.sleep(forTimeInterval: 0.05)
        // After soft reset, DSP returns to I2C mode — re-enter SPI
        try dspEnterSPIMode()
    }

    func dspHibernate(_ enable: Bool) throws {
        if enable {
            try dspPulseReg(ADAU14xx.HIBERNATE)
        } else {
            try dspWriteReg(ADAU14xx.HIBERNATE, value: 0x0000)
        }
    }

    func dspKillCore() throws {
        try dspPulseReg(ADAU14xx.KILL_CORE)
    }

    func dspStartCore() throws {
        try dspPulseReg(ADAU14xx.START_CORE)
    }

    func dspCoreStatus() throws -> ADAU14xx.CoreStatus {
        let val = try dspReadReg(ADAU14xx.CORE_STATUS)
        return ADAU14xx.CoreStatus(rawValue: val & 0x07) ?? .unknown
    }

    func dspExecuteCount() throws -> UInt16 {
        return try dspReadReg(ADAU14xx.EXECUTE_COUNT)
    }

    func dspPanicFlag() throws -> (flag: Bool, code: UInt16) {
        let flag = try dspReadReg(ADAU14xx.PANIC_FLAG)
        let code = try dspReadReg(ADAU14xx.PANIC_CODE)
        return (flag != 0, code)
    }

    func dspClearPanic() throws {
        try dspWriteReg(ADAU14xx.PANIC_CLEAR, value: 0x0001)
    }

    func dspPLLLocked() throws -> Bool {
        let val = try dspReadReg(ADAU14xx.PLL_LOCK)
        return (val & 0x0001) != 0
    }

    func dspASRCLockStatus() throws -> UInt16 {
        // NOTE: Bit polarity inverted — 0 = locked, 1 = unlocked
        return try dspReadReg(ADAU14xx.ASRC_LOCK)
    }

    // MARK: - Safeload (via SPI burst write)

    /// Perform a safeload write of up to 5 parameters atomically.
    /// Writes all 7 registers (data0-4, addr, trigger) as individual SPI transactions.
    func dspSafeload(targetAddr: UInt16, values: [UInt32]) throws {
        guard values.count >= 1 && values.count <= 5 else { return }

        // Write data slots (0x6000-0x6004)
        for (i, val) in values.enumerated() {
            let reg = ADAU14xx.SAFELOAD_DATA0 + UInt16(i)
            try dspSPIWrite(reg: reg, data: [
                UInt8((val >> 24) & 0xFF), UInt8((val >> 16) & 0xFF),
                UInt8((val >> 8) & 0xFF), UInt8(val & 0xFF)
            ])
        }

        // Write target address (0x6005)
        let addrVal = UInt32(targetAddr)
        try dspSPIWrite(reg: ADAU14xx.SAFELOAD_ADDR, data: [
            UInt8((addrVal >> 24) & 0xFF), UInt8((addrVal >> 16) & 0xFF),
            UInt8((addrVal >> 8) & 0xFF), UInt8(addrVal & 0xFF)
        ])

        // Trigger (0x6006) — write word count
        try dspSPIWrite(reg: ADAU14xx.SAFELOAD_TRIGGER, data: [0, 0, 0, UInt8(values.count)])
    }

    // MARK: - Firmware Upload (via SPI)

    /// Upload parsed SigmaStudio firmware records to the DSP over SPI.
    /// Records format: [addr_hi, addr_lo, len_hi, len_lo, data...]
    func dspUploadFirmware(records: Data, skipPrePLL: Int = 0,
                           progress: ((Double) -> Void)? = nil,
                           cancelled: (() -> Bool)? = nil) throws {
        var offset = 0
        var recordIndex = 0
        let total = records.count

        while offset + 4 <= records.count {
            if cancelled?() == true { throw CH341Error.cancelled }

            let addr = (UInt16(records[offset]) << 8) | UInt16(records[offset + 1])
            let len = Int((UInt16(records[offset + 2]) << 8) | UInt16(records[offset + 3]))
            offset += 4

            guard offset + len <= records.count else { break }

            if recordIndex < skipPrePLL {
                offset += len
                recordIndex += 1
                progress?(Double(offset) / Double(total))
                continue
            }

            if addr == 0x0000 && len == 2 {
                // Delay record
                let delayMS = Int((UInt16(records[offset]) << 8) | UInt16(records[offset + 1]))
                Thread.sleep(forTimeInterval: Double(delayMS) / 1000.0)
            } else {
                // Data record — SPI write to DSP
                let data = Array(records[offset..<(offset + len)])
                try dspWriteBlock(startAddr: addr, data: data)
            }

            offset += len
            recordIndex += 1
            progress?(Double(offset) / Double(total))
        }
    }
}

// MARK: - Fixed-Point Conversion (8.24)

enum DSPFixedPoint {
    static func fromFloat(_ value: Float) -> UInt32 {
        var v = value
        if v > 127.0 { v = 127.0 }
        if v < -128.0 { v = -128.0 }
        if v.isNaN { v = 0 }
        var scaled = v * 16777216.0 // 2^24
        if scaled >= 0 { scaled += 0.5 } else { scaled -= 0.5 }
        return UInt32(bitPattern: Int32(scaled))
    }

    static func toFloat(_ value: UInt32) -> Float {
        return Float(Int32(bitPattern: value)) / 16777216.0
    }

    static func toDecibels(_ value: UInt32) -> Float {
        let linear = toFloat(value)
        guard linear > 0 else { return -144.0 }
        return 20.0 * log10(linear)
    }

    static func fromDecibels(_ dB: Float) -> UInt32 {
        let linear = powf(10.0, dB / 20.0)
        return fromFloat(linear)
    }
}
