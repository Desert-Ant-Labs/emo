// swift-tools-version: 6.1
import PackageDescription
import Foundation

// Emo: on-device emoji suggestion for every platform.
//
//   desert-ant-core             reusable primitives (JSON, ModelStore,
//                               TextNormalization, Inference sessions + factory)
//   Sources/Emo                 shared pipeline (pure Swift; platform variation
//                               is data: artifact names, no tensor branching)
//   Sources/EmoCoreMLResources  Apple/Core ML model files (not LiteRT)
//   Sources/EmoTFLiteResources  LiteRT (.tflite) model files for Linux/Windows
//   Sources/EmoAndroid          C ABI + Swift JNI -> packages/emo-kotlin (+ Node native)
//   Sources/EmoWeb              wasm entry point -> packages/emo-node
//
// Emo is a small model, so the main SDK bundles it by default through the
// BundledModel trait; disable the trait for on-demand download or an explicit
// model directory.
let appleResourcePlatforms: [Platform] = [.macOS, .macCatalyst, .iOS, .tvOS, .watchOS, .visionOS]
let bundledModelTrait = Trait(
    name: "BundledModel",
    description: "Bundle the small Emo model into the default Swift package product. Disable this trait to use on-demand download or an explicit model directory."
)
let packageTraits: Set<Trait> = [
    .default(enabledTraits: ["BundledModel"]),
    bundledModelTrait,
]

// The Android static-stdlib link needs no macros in the build graph, so this
// flag (set by `mise run android-natives`) drops JavaScriptKit and the wasm entry
// point. The wasm/JS code is all `#if os(WASI)`, so it is absent off-wasm anyway.
let noJavaScriptKit = ProcessInfo.processInfo.environment["SWIFT_ANDROID_STATIC_BUILD"] != nil

let jsDependencies: [Package.Dependency] = noJavaScriptKit ? [] : [
    .package(url: "https://github.com/swiftwasm/JavaScriptKit", from: "0.56.1"),
]
let packageDependencies: [Package.Dependency] = [
    // Reusable cross-platform primitives (JSON, ModelStore, TextNormalization,
    // Inference, FFIBuffer, HostBridge, PlatformSupport, ModelResources).
    .package(url: "https://github.com/Desert-Ant-Labs/desert-ant-core.git", from: "0.5.3"),
] + jsDependencies

let wasmProducts: [Product] = noJavaScriptKit ? [] : [
    .executable(name: "EmoWeb", targets: ["EmoWeb"]),
]
let packageProducts: [Product] = [
    .library(name: "Emo", targets: ["Emo"]),
    // Emo is small, so the main SDK bundles the model by default through the
    // BundledModel trait. These resource products remain public for explicit
    // bundle construction or tests.
    .library(name: "EmoCoreMLResources", targets: ["EmoCoreMLResources"]),
    .library(name: "EmoTFLiteResources", targets: ["EmoTFLiteResources"]),
    // Android JNI library (built by `mise run android-natives`).
    .library(name: "EmoAndroid", type: .dynamic, targets: ["EmoAndroid"]),
    // Native library for the Node.js server-side backend (built by
    // `mise run node-natives`). Shares the EmoAndroid target: on a host
    // (Linux/macOS) triple only the C ABI in `CABI.swift` compiles, since
    // `AndroidJNI.swift` is `#if os(Android)`; koffi in packages/emo-node binds
    // the `emo_*` C ABI over the resulting libEmoNode.
    .library(name: "EmoNode", type: .dynamic, targets: ["EmoAndroid"]),
] + wasmProducts

let emoDependencies: [Target.Dependency] = [
    // Reusable, platform-abstracting primitives: the pipeline uses
    // `JSONDecoder`, `String.nfkc`, and the named-tensor session, no platform code.
    .product(name: "JSON", package: "desert-ant-core"),
    .product(name: "ModelStore", package: "desert-ant-core"),
    .product(name: "TextNormalization", package: "desert-ant-core"),
    .product(name: "PlatformSupport", package: "desert-ant-core"),
    .product(name: "ModelResources", package: "desert-ant-core"),
    // Named-tensor inference sessions (Core ML | LiteRT | JS host).
    .product(name: "Inference", package: "desert-ant-core"),
    // Emo is below the small-model threshold, so bundle the runnable artifact by
    // default on SwiftPM platforms that support resource bundles. Disable the
    // BundledModel trait to omit these resource targets and use download or an
    // explicit model directory.
    .target(name: "EmoCoreMLResources", condition: .when(platforms: appleResourcePlatforms, traits: ["BundledModel"])),
    .target(name: "EmoTFLiteResources", condition: .when(platforms: [.linux, .windows], traits: ["BundledModel"])),
]

let emoTarget: Target = .target(
    name: "Emo",
    dependencies: emoDependencies,
    swiftSettings: [
        .define("EMO_BUNDLED_MODEL", .when(traits: ["BundledModel"])),
    ]
)

let resourceTargets: [Target] = [
    // Split so Apple apps do not ship the unused LiteRT model.
    .target(
        name: "EmoCoreMLResources",
        resources: [
            .copy("Resources/emo.mlmodelc"),
            .copy("Resources/emo_meta.json"),
            .copy("Resources/emo_tokenizer.bin"),
        ]
    ),
    .target(
        name: "EmoTFLiteResources",
        resources: [
            .copy("Resources/emo.tflite"),
            .copy("Resources/emo_meta.json"),
            .copy("Resources/emo_tokenizer.bin"),
        ]
    ),
]

let androidTarget: Target = .target(
    name: "EmoAndroid",
    dependencies: [
        "Emo",
        .product(name: "FFIBuffer", package: "desert-ant-core"),
        .product(name: "HostBridge", package: "desert-ant-core", condition: .when(platforms: [.android])),
        .product(name: "ModelStore", package: "desert-ant-core", condition: .when(platforms: [.android])),
        .product(name: "PlatformSupport", package: "desert-ant-core"),
    ]
)

let testTarget: Target = .testTarget(
    name: "EmoTests",
    dependencies: [
        "Emo",
        .target(name: "EmoCoreMLResources", condition: .when(platforms: appleResourcePlatforms)),
        .target(name: "EmoTFLiteResources", condition: .when(platforms: [.linux, .windows])),
    ]
)

let wasmTargets: [Target] = noJavaScriptKit ? [] : [
    .executableTarget(
        name: "EmoWeb",
        dependencies: [
            "Emo",
            .product(name: "JavaScriptKit", package: "JavaScriptKit", condition: .when(platforms: [.wasi])),
            .product(name: "JavaScriptEventLoop", package: "JavaScriptKit", condition: .when(platforms: [.wasi])),
        ],
        // The wasm host bridges JavaScriptKit's non-Sendable JS values across the
        // event-loop executor; keep Swift 5 concurrency semantics here (as under
        // the pre-6.1 tools version) so those crossings stay warnings.
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
]
let packageTargets: [Target] = [emoTarget] + resourceTargets + [androidTarget, testTarget] + wasmTargets

let package = Package(
    name: "Emo",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .macCatalyst(.v16),
        .tvOS(.v16),
        .watchOS(.v9),
        .visionOS(.v1),
    ],
    products: packageProducts,
    traits: packageTraits,
    dependencies: packageDependencies,
    targets: packageTargets
)
