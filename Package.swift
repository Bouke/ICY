// swift-tools-version:4.2

import PackageDescription

let package = Package(
    name: "ICY",
	products: [
        .library(name: "ICY", targets: ["ICY"]),
    ],
    targets: [
        .target(name: "ICY", path: "Sources"),
    ]
)
