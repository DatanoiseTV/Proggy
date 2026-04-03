import Foundation

struct ChipInfo: Identifiable {
    let id: UInt32  // (manufacturerID << 16) | memoryType
    let name: String
    let capacity: Int
    let sectorSize: Int
    let pageSize: Int

    init(mfr: UInt8, type: UInt16, name: String, capacity: Int, sectorSize: Int = 4096, pageSize: Int = 256) {
        self.id = (UInt32(mfr) << 16) | UInt32(type)
        self.name = name
        self.capacity = capacity
        self.sectorSize = sectorSize
        self.pageSize = pageSize
    }
}

enum ChipDatabase {
    // MARK: - Manufacturer Names

    private static let manufacturers: [UInt8: String] = [
        0xEF: "Winbond",
        0xC8: "GigaDevice",
        0xC2: "Macronix",
        0x20: "Micron/Numonyx",
        0x01: "Spansion/Cypress",
        0x1F: "Atmel/Adesto",
        0xBF: "SST/Microchip",
        0x37: "AMIC",
        0x9D: "ISSI",
        0x0B: "XTX",
        0x68: "Boya/Boyamicro",
        0x5E: "Zbit",
        0x25: "Zetta",
        0x85: "Puya",
    ]

    static func manufacturerName(for id: UInt8) -> String {
        manufacturers[id] ?? String(format: "Unknown (0x%02X)", id)
    }

    // MARK: - Known Chips

    static let knownChips: [UInt32: ChipInfo] = {
        let chips: [ChipInfo] = [
            // Winbond
            ChipInfo(mfr: 0xEF, type: 0x4014, name: "W25Q80", capacity: 1_048_576),
            ChipInfo(mfr: 0xEF, type: 0x4015, name: "W25Q16", capacity: 2_097_152),
            ChipInfo(mfr: 0xEF, type: 0x4016, name: "W25Q32", capacity: 4_194_304),
            ChipInfo(mfr: 0xEF, type: 0x4017, name: "W25Q64", capacity: 8_388_608),
            ChipInfo(mfr: 0xEF, type: 0x4018, name: "W25Q128", capacity: 16_777_216),
            ChipInfo(mfr: 0xEF, type: 0x4019, name: "W25Q256", capacity: 33_554_432),
            ChipInfo(mfr: 0xEF, type: 0x7018, name: "W25Q128JV", capacity: 16_777_216),
            // GigaDevice
            ChipInfo(mfr: 0xC8, type: 0x4014, name: "GD25Q80", capacity: 1_048_576),
            ChipInfo(mfr: 0xC8, type: 0x4015, name: "GD25Q16", capacity: 2_097_152),
            ChipInfo(mfr: 0xC8, type: 0x4016, name: "GD25Q32", capacity: 4_194_304),
            ChipInfo(mfr: 0xC8, type: 0x4017, name: "GD25Q64", capacity: 8_388_608),
            ChipInfo(mfr: 0xC8, type: 0x4018, name: "GD25Q128", capacity: 16_777_216),
            // Macronix
            ChipInfo(mfr: 0xC2, type: 0x2014, name: "MX25L80", capacity: 1_048_576),
            ChipInfo(mfr: 0xC2, type: 0x2015, name: "MX25L16", capacity: 2_097_152),
            ChipInfo(mfr: 0xC2, type: 0x2016, name: "MX25L32", capacity: 4_194_304),
            ChipInfo(mfr: 0xC2, type: 0x2017, name: "MX25L64", capacity: 8_388_608),
            ChipInfo(mfr: 0xC2, type: 0x2018, name: "MX25L128", capacity: 16_777_216),
            // Micron
            ChipInfo(mfr: 0x20, type: 0xBA16, name: "N25Q32", capacity: 4_194_304),
            ChipInfo(mfr: 0x20, type: 0xBA17, name: "N25Q64", capacity: 8_388_608),
            ChipInfo(mfr: 0x20, type: 0xBA18, name: "N25Q128", capacity: 16_777_216),
            // ISSI
            ChipInfo(mfr: 0x9D, type: 0x6016, name: "IS25LP032", capacity: 4_194_304),
            ChipInfo(mfr: 0x9D, type: 0x6017, name: "IS25LP064", capacity: 8_388_608),
            ChipInfo(mfr: 0x9D, type: 0x6018, name: "IS25LP128", capacity: 16_777_216),
            // SST
            ChipInfo(mfr: 0xBF, type: 0x254A, name: "SST25VF032B", capacity: 4_194_304),
            // Spansion
            ChipInfo(mfr: 0x01, type: 0x0215, name: "S25FL016", capacity: 2_097_152),
            ChipInfo(mfr: 0x01, type: 0x0216, name: "S25FL032", capacity: 4_194_304),
            ChipInfo(mfr: 0x01, type: 0x0217, name: "S25FL064", capacity: 8_388_608),
            // Atmel
            ChipInfo(mfr: 0x1F, type: 0x4501, name: "AT25SF041", capacity: 524_288),
            ChipInfo(mfr: 0x1F, type: 0x8601, name: "AT25SF161", capacity: 2_097_152),
        ]
        var dict = [UInt32: ChipInfo]()
        for chip in chips {
            dict[chip.id] = chip
        }
        return dict
    }()

    static func lookup(jedec: JEDECInfo) -> ChipInfo? {
        let key = (UInt32(jedec.manufacturerID) << 16) | UInt32(jedec.memoryType)
        return knownChips[key]
    }

    static func lookup(manufacturerID: UInt8, memoryType: UInt16) -> ChipInfo? {
        let key = (UInt32(manufacturerID) << 16) | UInt32(memoryType)
        return knownChips[key]
    }
}
