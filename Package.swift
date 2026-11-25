// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "MacWiFiPicker",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MacWiFiPicker", targets: ["MacWiFiPicker"]),
        .executable(name: "WiFiPickerHost", targets: ["WiFiPickerHost"]),
        .executable(name: "WiFiPickerModelTests", targets: ["WiFiPickerModelTests"])
    ],
    targets: [
        .target(
            name: "MacWiFiPicker",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreLocation"),
                .linkedFramework("CoreWLAN"),
                .linkedFramework("Network")
            ]
        ),
        .executableTarget(
            name: "WiFiPickerHost",
            dependencies: ["MacWiFiPicker"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .executableTarget(
            name: "WiFiPickerModelTests",
            dependencies: ["MacWiFiPicker"],
            path: "Tests/MacWiFiPickerTests"
        )
    ],
    swiftLanguageModes: [.v6]
)
