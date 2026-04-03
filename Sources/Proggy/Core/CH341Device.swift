import Foundation
import CLibUSB

final class CH341Device {
    private var context: OpaquePointer?
    private var handle: OpaquePointer?
    private let queue = DispatchQueue(label: "ch341.usb", qos: .userInitiated)

    private(set) var isConnected = false
    private(set) var deviceRevision: String = ""

    /// Debug log closure for SPI troubleshooting
    var spiDebugLog: ((String) -> Void)?

    // MARK: - Connection

    func open() throws {
        var ctx: OpaquePointer?
        let rc = libusb_init(&ctx)
        guard rc == 0 else {
            throw CH341Error.openFailed("libusb_init failed: \(rc)")
        }
        self.context = ctx

        let dev = libusb_open_device_with_vid_pid(ctx, CH341.usbVendorID, CH341.usbProductID)
        guard let dev else {
            libusb_exit(ctx)
            self.context = nil
            throw CH341Error.openFailed("Device not found (VID:PID \(String(format: "%04X:%04X", CH341.usbVendorID, CH341.usbProductID)))")
        }
        self.handle = dev

        // Detach kernel driver if active (Linux only, no-op on macOS)
        if libusb_kernel_driver_active(dev, 0) == 1 {
            libusb_detach_kernel_driver(dev, 0)
        }

        let claimRC = libusb_claim_interface(dev, 0)
        guard claimRC == 0 else {
            libusb_close(dev)
            libusb_exit(ctx)
            self.handle = nil
            self.context = nil
            throw CH341Error.claimFailed
        }

        // Read device descriptor via USB control transfer (matches ch341prog)
        // This is NOT the same as libusb_get_device_descriptor — it sends an actual
        // USB request to the device which may be needed to initialize the CH341A.
        var desc = [UInt8](repeating: 0, count: 0x12)
        let descRC = libusb_get_descriptor(dev, 1 /* LIBUSB_DT_DEVICE */, 0x00, &desc, 0x12)
        if descRC >= 0 {
            deviceRevision = String(format: "%d.%02d", desc[12], desc[13])
        }

        isConnected = true
    }

    func close() {
        guard let handle else { return }
        libusb_release_interface(handle, 0)
        libusb_close(handle)
        self.handle = nil

        if let context {
            libusb_exit(context)
            self.context = nil
        }

        isConnected = false
        deviceRevision = ""
    }

    // MARK: - USB Transfer

    func bulkWrite(_ data: [UInt8]) throws -> Int {
        guard let handle else { throw CH341Error.notConnected }
        // Send exact byte count — no padding (CH341A processes all bytes sent)
        var buf = data
        var transferred: Int32 = 0
        let rc = libusb_bulk_transfer(handle, CH341.bulkWriteEndpoint, &buf, Int32(buf.count), &transferred, CH341.usbTimeout)
        guard rc == 0 else { throw CH341Error.transferFailed(rc) }
        return Int(transferred)
    }

    func bulkRead(_ length: Int) throws -> [UInt8] {
        guard let handle else { throw CH341Error.notConnected }
        // CH341A always returns full 32-byte packets — allocate at least one packet
        let bufSize = max(length, CH341.packetLength)
        var buf = [UInt8](repeating: 0, count: bufSize)
        var transferred: Int32 = 0
        let rc = libusb_bulk_transfer(handle, CH341.bulkReadEndpoint, &buf, Int32(bufSize), &transferred, CH341.usbTimeout)
        guard rc == 0 else { throw CH341Error.transferFailed(rc) }
        return Array(buf[0..<Int(transferred)])
    }

    /// Perform a synchronized USB operation on the dedicated queue
    func perform<T>(_ operation: @escaping (CH341Device) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let result = try operation(self)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Drain any leftover bytes from the read endpoint
    func flushRead() {
        guard let handle else { return }
        var buf = [UInt8](repeating: 0, count: CH341.maxTransferSize)
        var transferred: Int32 = 0
        // Non-blocking drain — read with short timeout until empty
        for _ in 0..<4 {
            let rc = libusb_bulk_transfer(handle, CH341.bulkReadEndpoint, &buf, Int32(buf.count), &transferred, 10)
            if rc != 0 || transferred == 0 { break }
        }
    }

    // MARK: - Configuration

    func setStream(speed: CH341Speed, spiDouble: Bool = false) throws {
        var speedByte = speed.rawValue
        if spiDouble { speedByte |= 0x04 }
        let buf: [UInt8] = [CH341.cmdI2CStream, CH341.i2cSet | speedByte, CH341.i2cEnd]
        _ = try bulkWrite(buf)
    }
}
