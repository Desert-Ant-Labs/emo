// How Emo obtains and shapes its model: the file manifest, the
// download/adopt/bundle sources, and the `ModelAssets` the pipeline consumes.
// (Running the model is `Model.swift`.) All platform variation is data here
// (which artifact ships where); building the platform's session is
// desert-ant-core's `inferenceSession` factory.
import Inference
import ModelStore
#if EMO_BUNDLED_MODEL && canImport(EmoCoreMLResources)
import EmoCoreMLResources
#endif
#if EMO_BUNDLED_MODEL && canImport(EmoTFLiteResources)
import EmoTFLiteResources
#endif

/// This SDK's usage identity, attached to every emitted telemetry body's `sdk`
/// field so usage attributes to Emo (not the underlying desert-ant-core).
let emoSDKInfo = SDKInfo(name: "Emo", version: emoSDKVersion)

/// The Emo SDK version. Keep in sync with the package version (single-sourced
/// from packages/emo-node/package.json; see `mise run set-version`).
let emoSDKVersion = "0.7.0"

/// The model's file names and per-platform artifacts, in one place.
enum EmoModel {
    static let meta = "emo_meta.json"
    static let tokenizer = "emo_tokenizer.bin"
    static let tflite = "emo.tflite"      // LiteRT platforms (Linux/Android/Windows) + wasm
    static let coreML = "emo.mlmodelc"    // Apple

    /// The runnable artifact on this platform. Both the Core ML and the LiteRT
    /// exports use the same fixed n-gram/semantic window with a `sem_mask` (see
    /// `Model.probabilities`), so there is no per-artifact tensor shaping.
    static var artifact: String { ModelPlatform.current == .apple ? coreML : tflite }
}

/// Loaded model inputs: the sidecar metadata, the semantic tokenizer bytes, and
/// a ready inference session. Also the entry point for the cross-language
/// bindings and custom deployments (not part of the Swift SDK's public API,
/// which loads assets for you).
@_spi(EmoBindings)
public struct ModelAssets: Sendable {
    /// Contents of `emo_meta.json` (labels + featurizer/tokenizer constants).
    public let metaJSON: String
    /// Contents of `emo_tokenizer.bin` (the pruned-unigram semantic tokenizer).
    public let tokenizer: [UInt8]
    /// The platform's ready-to-run session for the model artifact.
    let session: any InferenceSession

    /// Bindings entry point: in-memory model files (e.g. the Android AAR reads
    /// them from classpath resources). The model bytes must be the LiteRT
    /// (`.tflite`) export.
    public init(metaJSON: String, tokenizerBytes: [UInt8], modelBytes: [UInt8]) throws {
        self.init(
            metaJSON: metaJSON,
            tokenizer: tokenizerBytes,
            session: try inferenceSession(modelBytes: modelBytes, sdk: emoSDKInfo))
    }

    /// Bindings entry point: load the artifact from a file path (the Node
    /// server-side native's bundled path). `inferenceSession(modelPath:)`
    /// selects Core ML on Apple hosts (from the `.mlmodelc` directory) and
    /// LiteRT on Linux (from the `.tflite`), so this one call covers both - the
    /// unified Node bundling primitive. It is also mmap-based, sidestepping the
    /// from-bytes buffer-ownership pitfall.
    public init(metaJSON: String, tokenizerBytes: [UInt8], modelPath: String) throws {
        self.init(
            metaJSON: metaJSON,
            tokenizer: tokenizerBytes,
            session: try inferenceSession(modelPath: modelPath, sdk: emoSDKInfo))
    }

    /// Bindings entry point: build from an already-constructed session (e.g. the
    /// wasm host's `JSInferenceSession`) plus the sidecars.
    @_spi(EmoBindings)
    public init(metaJSON: String, tokenizer: [UInt8], session: any InferenceSession) {
        self.metaJSON = metaJSON
        self.tokenizer = tokenizer
        self.session = session
    }

    /// Build from a resolved model directory: read the sidecars and let the core
    /// pick this platform's session for the artifact.
    static func emo(files: StoredModel) async throws -> ModelAssets {
        ModelAssets(
            metaJSON: try files.readString(EmoModel.meta),
            tokenizer: try files.read(EmoModel.tokenizer),
            session: try await files.inferenceSession(model: EmoModel.artifact, hostGlobal: "__EmoHost", sdk: emoSDKInfo))
    }
}

public extension Emo {
    /// The published model repository.
    static var modelRepo: String { "desert-ant-labs/emo" }
    /// The model revision this SDK is built against (pinned; not configurable).
    static var modelRevision: String { "v0.7.0" }

    /// Resolve the model for the default suggester. Emo is small, so the default
    /// uses bundled model resources when no explicit directory is supplied.
    /// Passing a directory keeps the adoption/download behavior.
    internal static func defaultAssets(
        directory: String?,
        cacheRoot: String? = nil,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> ModelAssets {
        if directory == nil, let assets = try bundledDefaultAssets() {
            progress(1)
            return assets
        }
        return try await resolvedAssets(directory: directory, cacheRoot: cacheRoot, progress: progress)
    }

    /// Whether the default suggester is available offline.
    internal static func defaultIsAvailable(directory: String?, cacheRoot: String? = nil) -> Bool {
        if directory == nil, hasBundledDefaultAssets() { return true }
        return isModelAvailable(directory: directory, cacheRoot: cacheRoot)
    }

    /// Resolve the model for `directory` (adopt your files, or download there),
    /// then build loadable assets. `nil` uses the managed cache.
    internal static func resolvedAssets(
        directory: String?,
        cacheRoot: String? = nil,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> ModelAssets {
        let files = try await distribution().resolve(cacheDirectory: directory, cacheRoot: cacheRoot) { progress($0.fraction) }
        return try await .emo(files: files)
    }

    /// Whether the model is available offline for `directory`.
    internal static func isModelAvailable(directory: String?, cacheRoot: String? = nil) -> Bool {
        distribution().isAvailable(cacheDirectory: directory, cacheRoot: cacheRoot)
    }

    private static func bundledDefaultAssets() throws -> ModelAssets? {
#if canImport(CoreML) || os(Linux)
        try ModelAssets.defaultBundle()
#else
        nil
#endif
    }

    private static func hasBundledDefaultAssets() -> Bool {
#if EMO_BUNDLED_MODEL
        true
#else
        false
#endif
    }

    private static func distribution() -> ModelDistribution {
        let tflite = [EmoModel.tflite, EmoModel.meta, EmoModel.tokenizer]
        return ModelDistribution(
            repo: modelRepo,
            revision: modelRevision,
            files: [
                .apple: [EmoModel.coreML + "/", EmoModel.meta, EmoModel.tokenizer],
                .android: tflite,
                .linux: tflite,
                .windows: tflite,
                .web: tflite,
            ]
        )
    }
}

// MARK: app bundling (Apple / Linux)

// Emo is small enough to bundle by default. The explicit bundle initializer
// remains useful for tests and custom package layouts. On Android, the normal
// AAR depends on the resources artifact by default. In JavaScript, the npm
// package ships the LiteRT model files next to browser.js and node.js. This is
// the one platform conditional in the model code: `Bundle` is a Foundation
// type, so the initializer only exists where SwiftPM resource bundles do.
#if canImport(CoreML) || os(Linux)
import Foundation
import ModelResources

public extension Emo {
    /// Load a model from an explicit resource bundle. `Emo()` already uses the
    /// packaged bundle by default for this small model.
    ///
    /// ```swift
    /// import EmoCoreMLResources
    /// let emo = Emo(bundle: EmoCoreMLResourcesBundle.bundle)
    /// ```
    convenience init(bundle: Bundle) {
        self.init(
            resolve: { _ in try ModelAssets.emo(bundle: bundle) },
            isAvailable: { true }
        )
    }
}

extension ModelAssets {
    /// Build from the package's default bundled resource target, when this
    /// platform has one linked.
    static func defaultBundle() throws -> ModelAssets? {
#if EMO_BUNDLED_MODEL && canImport(EmoCoreMLResources)
        return try emo(bundle: EmoCoreMLResourcesBundle.bundle)
#elseif EMO_BUNDLED_MODEL && canImport(EmoTFLiteResources)
        return try emo(bundle: EmoTFLiteResourcesBundle.bundle)
#else
        return nil
#endif
    }

    /// Build from a resource bundle: the sidecars plus this platform's session
    /// for the bundled artifact.
    static func emo(bundle: Bundle) throws -> ModelAssets {
        let resources = BundledResources(bundle)
        do {
            return ModelAssets(
                metaJSON: try resources.readString(EmoModel.meta),
                tokenizer: try resources.read(EmoModel.tokenizer),
                session: try inferenceSession(modelPath: try resources.path(EmoModel.artifact), sdk: emoSDKInfo))
        } catch {
            throw EmoError.modelNotFound
        }
    }
}
#endif
