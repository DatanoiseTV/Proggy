import Foundation
import CLibUSB

final class CH341Device {
    private var context: OpaquePointer?
    private var handle: OpaquePointer?
    private let queue = DispatchQueue(label: "ch341.usb", qos: .userInitiated)

    private(set) var isConnected = false
    private(set) var deviceRevision: String = ""

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

        // Detach kernel driver if active
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

        // Read device descriptor for revision
        var desc = libusb_device_descriptor()
        if libusb_get_device_descriptor(libusb_get_device(dev), &desc) == 0 {
            deviceRevision = String(format: "%d.%02d", desc.bcdDevice >> 8, desc.bcdDevice & 0xFF)
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
        var buf = data
        var transferred: Int32 = 0
        let rc = libusb_bulk_transfer(handle, CH341.bulkWriteEndpoint, &buf, Int32(buf.count), &transferred, CH341.usbTimeout)
        guard rc == 0 else { throw CH341Error.transferFailed(rc) }
        return Int(transferred)
    }

    func bulkRead(_ length: Int) throws -> [UInt8] {
        guard let handle else { throw CH341Error.notConnected }
        var buf = [UInt8](repeating: 0, count: length)
        var transferred: Int32 = 0
        let rc = libusb_bulk_transfer(handle, CH341.bulkReadEndpoint, &buf, Int32(length), &transferred, CH341.usbTimeout)
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

    // MARK: - Configuration

    func setStream(speed: CH341Speed, spiDouble: Bool = false) throws {
        var speedByte = speed.rawValue
        if spiDouble { speedByte |= 0x04 }
        let buf: [UInt8] = [CH341.cmdI2CStream, CH341.i2cSet | speedByte, CH341.i2cEnd]
        _ = try bulkWrite(buf)
    }
}
