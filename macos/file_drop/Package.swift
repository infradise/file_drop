// swift-tools-version: 5.9

import PackageDescription

let package = Package(
  name: "file_drop",
  platforms: [
    .macOS("11.0")
  ],
  products: [
    .library(name: "file-drop", targets: ["file_drop"])
  ],
  dependencies: [
    .package(name: "FlutterFramework", path: "../FlutterFramework")
  ],
  targets: [
    .target(
      name: "file_drop",
      dependencies: [
        .product(name: "FlutterFramework", package: "FlutterFramework")
      ],
      resources: [
        .process("Resources")
      ]
    )
  ]
)
