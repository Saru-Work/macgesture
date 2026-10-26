// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacGesture",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "MacGesture", targets: ["MacGesture"]),
        .library(name: "MacGestureCore", targets: ["MacGestureCore"]),
    ],
    targets: [
        // Runtime-loaded bridge to the private MultitouchSupport.framework.
        // Nothing links against the private framework, so the app still
        // launches (and reports the backend as unavailable) if it disappears.
        .target(
            name: "CMultitouchBridge",
            path: "Sources/CMultitouchBridge"
        ),
        .target(
            name: "MacGestureCore",
            dependencies: ["CMultitouchBridge"],
            path: "Sources/MacGestureCore",
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("IOKit"),
            ]
        ),
        .executableTarget(
            name: "MacGesture",
            dependencies: ["MacGestureCore"],
            path: "Sources/MacGesture",
            linkerSettings: [.linkedFramework("ServiceManagement")]
        ),
        // Command-line hardware check: real trackpad input, no actions.
        .executableTarget(
            name: "macgesture-probe",
            dependencies: ["MacGestureCore"],
            path: "Sources/MacGestureProbe"
        ),
        .testTarget(
            name: "MacGestureCoreTests",
            dependencies: ["MacGestureCore"],
            path: "Tests/MacGestureCoreTests"
        ),
    ]
)
