import Foundation
import IOKit
import IOKit.serial

// MARK: - Serial Port Enumeration & Communication (macOS native)

final class SerialPort {
    let path: String
    private var fd: Int32 = -1
    private var originalTermios = termios()

    var isOpen: Bool { fd >= 0 }

    init(path: String) {
        self.path = path
    }

    // MARK: - Enumerate Available Ports

    static func availablePorts() -> [(path: String, name: String)] {
        var ports: [(String, String)] = []

        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching(kIOSerialBSDServiceValue)
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard kr == KERN_SUCCESS else { return ports }

        var service: io_object_t = IOIteratorNext(iterator)
        while service != 0 {
            if let pathCF = IORegistryEntryCreateCFProperty(service, kIOCalloutDeviceKey as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String {
                // Get friendly name
                var name = pathCF.components(separatedBy: "/").last ?? pathCF
                if let nameCF = IORegistryEntryCreateCFProperty(service, "USB Product Name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String {
                    name = nameCF
                }
                ports.append((pathCF, name))
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        IOObjectRelease(iterator)

        return ports.sorted { $0.0 < $1.0 }
    }

    // MARK: - Open / Close

    func open(baudRate: Int = 115200) throws {
        fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw SerialError.openFailed(path) }

        // Remove non-blocking after open
        var flags = fcntl(fd, F_GETFL)
        flags &= ~O_NONBLOCK
        fcntl(fd, F_SETFL, flags)

        // Save original settings
        tcgetattr(fd, &originalTermios)

        // Configure port
        var settings = termios()
        cfmakeraw(&settings)

        let speed = baudRateConstant(baudRate)
        cfsetispeed(&settings, speed)
        cfsetospeed(&settings, speed)

        settings.c_cflag |= UInt(CLOCAL | CREAD)
        settings.c_cflag &= ~UInt(PARENB)     // No parity
        settings.c_cflag &= ~UInt(CSTOPB)     // 1 stop bit
        settings.c_cflag &= ~UInt(CSIZE)
        settings.c_cflag |= UInt(CS8)          // 8 data bits

        // Timeouts: 1 second
        settings.c_cc.16 = 10  // VTIME = 1.0s (in tenths)
        settings.c_cc.17 = 0   // VMIN = 0

        tcsetattr(fd, TCSANOW, &settings)
        tcflush(fd, TCIOFLUSH)
    }

    func close() {
        guard fd >= 0 else { return }
        tcsetattr(fd, TCSANOW, &originalTermios)
        Darwin.close(fd)
        fd = -1
    }

    func setBaudRate(_ rate: Int) throws {
        guard fd >= 0 else { throw SerialError.notOpen }
        var settings = termios()
        tcgetattr(fd, &settings)
        let speed = baudRateConstant(rate)
        cfsetispeed(&settings, speed)
        cfsetospeed(&settings, speed)
        tcsetattr(fd, TCSANOW, &settings)
    }

    // MARK: - Read / Write

    func write(_ data: [UInt8]) throws {
        guard fd >= 0 else { throw SerialError.notOpen }
        var buf = data
        let written = Darwin.write(fd, &buf, buf.count)
        guard written == buf.count else { throw SerialError.writeFailed }
    }

    func read(count: Int, timeout: TimeInterval = 3.0) throws -> [UInt8] {
        guard fd >= 0 else { throw SerialError.notOpen }
        var result = [UInt8]()
        var buf = [UInt8](repeating: 0, count: 1024)
        let deadline = Date().addingTimeInterval(timeout)

        while result.count < count && Date() < deadline {
            let toRead = min(1024, count - result.count)
            let n = Darwin.read(fd, &buf, toRead)
            if n > 0 {
                result.append(contentsOf: buf[0..<n])
            } else if n == 0 {
                Thread.sleep(forTimeInterval: 0.001)
            } else {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    Thread.sleep(forTimeInterval: 0.001)
                } else {
                    throw SerialError.readFailed
                }
            }
        }
        return result
    }

    func readAvailable() -> [UInt8] {
        guard fd >= 0 else { return [] }
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = Darwin.read(fd, &buf, 4096)
        return n > 0 ? Array(buf[0..<n]) : []
    }

    func flush() {
        guard fd >= 0 else { return }
        tcflush(fd, TCIOFLUSH)
    }

    // MARK: - DTR/RTS Control (for ESP boot mode)

    func setDTR(_ state: Bool) {
        guard fd >= 0 else { return }
        var flag: Int32 = TIOCM_DTR
        if state {
            ioctl(fd, UInt(TIOCMBIS), &flag)
        } else {
            ioctl(fd, UInt(TIOCMBIC), &flag)
        }
    }

    func setRTS(_ state: Bool) {
        guard fd >= 0 else { return }
        var flag: Int32 = TIOCM_RTS
        if state {
            ioctl(fd, UInt(TIOCMBIS), &flag)
        } else {
            ioctl(fd, UInt(TIOCMBIC), &flag)
        }
    }

    // MARK: - Helpers

    private func baudRateConstant(_ rate: Int) -> speed_t {
        switch rate {
        case 9600: return speed_t(B9600)
        case 19200: return speed_t(B19200)
        case 38400: return speed_t(B38400)
        case 57600: return speed_t(B57600)
        case 115200: return speed_t(B115200)
        case 230400: return speed_t(B230400)
        case 460800: return speed_t(460800)
        case 921600: return speed_t(921600)
        case 1500000: return speed_t(1500000)
        case 2000000: return speed_t(2000000)
        default: return speed_t(B115200)
        }
    }

    deinit {
        close()
    }
}

// MARK: - Errors

enum SerialError: LocalizedError {
    case openFailed(String)
    case notOpen
    case writeFailed
    case readFailed
    case timeout

    var errorDescription: String? {
        switch self {
        case .openFailed(let path): return "Failed to open serial port: \(path)"
        case .notOpen: return "Serial port not open"
        case .writeFailed: return "Serial write failed"
        case .readFailed: return "Serial read failed"
        case .timeout: return "Serial timeout"
        }
    }
}
