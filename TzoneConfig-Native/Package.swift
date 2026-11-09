// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TzoneConfig",
    platforms: [.macOS(.v12)],
    targets: [
        .target(
            name: "CSCSI",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),
        .executableTarget(name: "TzoneConfig", dependencies: ["CSCSI"]),
    ]
)
