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

    // Additional registers
    static let PLL_WATCHDOG_REG: UInt16 = 0xF006
    static let CLK_GEN1_M: UInt16     = 0xF020
    static let CLK_GEN1_N: UInt16     = 0xF021
    static let SERIAL_BYTE_0_BASE: UInt16 = 0xF200
    static let SOUT_SOURCE_BASE: UInt16   = 0xF180
    static let ASRC_INPUT_BASE: UInt16    = 0xF100
    static let ASRC_OUT_RATE_BASE: UInt16 = 0xF140
    static let ASRC_MUTE: UInt16          = 0xF581
    static let ASRC_RATIO_BASE: UInt16    = 0xF582
    static let MP_MODE_BASE: UInt16       = 0xF510
    static let MP_WRITE_BASE: UInt16      = 0xF520
    static let MP_READ_BASE: UInt16       = 0xF530
    static let AUX_ADC_BASE: UInt16       = 0xF5A0
    static let WATCHDOG_MAXCOUNT: UInt16  = 0xF443
    static let WATCHDOG_PRESCALE: UInt16  = 0xF444
    static let START_ADDRESS: UInt16      = 0xF404
    static let PANIC_PARITY_MASK: UInt16  = 0xF422
    static let PANIC_WD_MASK: UInt16      = 0xF424

    // Safeload timing: minimum delay between consecutive safeloads
    static func safeloadIntervalUs(sampleRate: Int = 48000) -> Int {
        2_000_000 / sampleRate  // 2 frames, e.g. 41 us @ 48 kHz
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

    // MARK: - Safeload (28-byte burst write for atomic frame-boundary update)

    /// Perform a safeload write of 1–5 parameters atomically.
    /// Packs all 7 registers (data0-4, target addr, trigger) into a single SPI burst
    /// of 28 bytes so the DSP applies them at the next audio frame boundary.
    func dspSafeload(targetAddr: UInt16, values: [UInt32]) throws {
        guard values.count >= 1 && values.count <= 5 else { return }

        // Build 28-byte payload: 5 data slots (20B) + target addr (4B) + trigger (4B)
        var burst = [UInt8](repeating: 0, count: 28)

        // Data slots 0-4 (offsets 0-19)
        for (i, val) in values.enumerated() {
            let off = i * 4
            burst[off + 0] = UInt8((val >> 24) & 0xFF)
            burst[off + 1] = UInt8((val >> 16) & 0xFF)
            burst[off + 2] = UInt8((val >> 8) & 0xFF)
            burst[off + 3] = UInt8(val & 0xFF)
        }

        // Target address at offset 20 (register 0x6005)
        let addr32 = UInt32(targetAddr)
        burst[20] = UInt8((addr32 >> 24) & 0xFF)
        burst[21] = UInt8((addr32 >> 16) & 0xFF)
        burst[22] = UInt8((addr32 >> 8) & 0xFF)
        burst[23] = UInt8(addr32 & 0xFF)

        // Trigger at offset 24 (register 0x6006) — word count
        burst[27] = UInt8(values.count)

        // Single SPI burst write starting at 0x6000
        try dspSPIWrite(reg: ADAU14xx.SAFELOAD_DATA0, data: burst)
    }

    // MARK: - Biquad Coefficients

    /// Biquad coefficients in Audio EQ Cookbook convention (b0, b1, b2, a1, a2)
    struct BiquadCoeffs {
        var b0: Float, b1: Float, b2: Float, a1: Float, a2: Float

        static let unity = BiquadCoeffs(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

        /// Check Schur stability: |a2| < 1 AND |a1| < 1 + a2
        var isStable: Bool {
            abs(a2) < 1.0 && abs(a1) < 1.0 + a2
        }
    }

    /// Write biquad coefficients to DSP via safeload.
    /// ADAU14xx stores in order: B2, B1, B0, A2, A1 at 5 consecutive addresses.
    /// ADAU convention negates a1/a2 compared to standard EQ Cookbook.
    /// Returns true if coefficients were stable; forces unity if unstable.
    @discardableResult
    func dspWriteBiquad(baseAddr: UInt16, coeffs: BiquadCoeffs) throws -> Bool {
        let c: BiquadCoeffs
        if coeffs.isStable {
            c = coeffs
        } else {
            c = .unity
        }

        // ADAU order: B2, B1, B0, A2, A1 — with a1/a2 negated
        let values: [UInt32] = [
            DSPFixedPoint.fromFloat(c.b2),
            DSPFixedPoint.fromFloat(c.b1),
            DSPFixedPoint.fromFloat(c.b0),
            DSPFixedPoint.fromFloat(-c.a2),  // Negate for ADAU convention
            DSPFixedPoint.fromFloat(-c.a1),  // Negate for ADAU convention
        ]

        try dspSafeload(targetAddr: baseAddr, values: values)
        return coeffs.isStable
    }

    /// Read biquad coefficients from DSP. Returns in standard EQ Cookbook convention.
    func dspReadBiquad(baseAddr: UInt16) throws -> BiquadCoeffs {
        // Read 5 consecutive 32-bit values: B2, B1, B0, A2, A1
        let b2 = DSPFixedPoint.toFloat(try dspReadParam(baseAddr))
        let b1 = DSPFixedPoint.toFloat(try dspReadParam(baseAddr + 1))
        let b0 = DSPFixedPoint.toFloat(try dspReadParam(baseAddr + 2))
        let a2_neg = DSPFixedPoint.toFloat(try dspReadParam(baseAddr + 3))
        let a1_neg = DSPFixedPoint.toFloat(try dspReadParam(baseAddr + 4))

        // Un-negate for standard convention
        return BiquadCoeffs(b0: b0, b1: b1, b2: b2, a1: -a1_neg, a2: -a2_neg)
    }

    // MARK: - Level Meters

    /// Read a single level meter value as linear float (0.0–1.0+)
    func dspReadLevel(addr: UInt16) throws -> Float {
        let raw = try dspReadParam(addr)
        return DSPFixedPoint.toFloat(raw)
    }

    /// Read multiple level meters
    func dspReadLevels(addrs: [UInt16]) throws -> [Float] {
        try addrs.map { try dspReadLevel(addr: $0) }
    }

    // MARK: - Multipurpose Pins (GPIO)

    func dspMPWrite(pin: Int, value: Bool) throws {
        guard pin >= 0 && pin <= 13 else { return }
        try dspWriteReg(ADAU14xx.MP_WRITE_BASE + UInt16(pin), value: value ? 1 : 0)
    }

    func dspMPRead(pin: Int) throws -> Bool {
        guard pin >= 0 && pin <= 13 else { return false }
        return try dspReadReg(ADAU14xx.MP_READ_BASE + UInt16(pin)) != 0
    }

    // MARK: - Aux ADC

    /// Read auxiliary ADC channel (0-5). Returns 0–1023.
    func dspAuxADCRead(channel: Int) throws -> UInt16 {
        guard channel >= 0 && channel <= 5 else { return 0 }
        let raw = try dspReadReg(ADAU14xx.AUX_ADC_BASE + UInt16(channel))
        return raw & 0x03FF
    }

    // MARK: - Config Readback

    /// Read serial port configuration (TDM mode, data format, word length)
    func dspReadSerialConfig(port: Int) throws -> (ctrl0: UInt16, ctrl1: UInt16) {
        let base = ADAU14xx.SERIAL_BYTE_0_BASE + UInt16(port * 4)
        let ctrl0 = try dspReadReg(base)
        let ctrl1 = try dspReadReg(base + 1)
        return (ctrl0, ctrl1)
    }

    /// Read power enable registers
    func dspReadPower() throws -> (enable0: UInt16, enable1: UInt16) {
        let e0 = try dspReadReg(ADAU14xx.POWER_ENABLE0)
        let e1 = try dspReadReg(ADAU14xx.POWER_ENABLE1)
        return (e0, e1)
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
