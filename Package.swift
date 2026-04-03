// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Proggy",
    platforms: [.macOS(.v14)],
    targets: [
        .systemLibrary(
            name: "CLibUSB",
            pkgConfig: "libusb-1.0",
            providers: [.brew(["libusb"])]
        ),
        .executableTarget(
            name: "Proggy",
            dependencies: ["CLibUSB"],
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ],
            linkerSettings: [
                .linkedLibrary("usb-1.0"),
                .unsafeFlags(["-L/opt/homebrew/lib"]),
            ]
        ),
    ]
)
