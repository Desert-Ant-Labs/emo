#if !os(WASI)
@_spi(EmoBindings) import Emo
import FFIBuffer
import Inference   // InferenceContext.withCallGroup(id:), for grouped runs
import PlatformSupport

// C ABI over the Emo core, called by the Swift JNI entry points in
// `AndroidJNI.swift` (and usable from any other host language). Kept
// Foundation-free so the Android build ships without the ~50 MB Foundation/ICU
// stack. Instance-based, mirroring the Swift SDK (one `Emo` per handle).
//
//   emo_create(cacheRootUTF8, dirUTF8|NULL)                    -> handle | NULL
//   emo_create_bundled(metaUTF8, tok,tokLen, model,modelLen)   -> handle | NULL
//   emo_create_bundled_path(metaUTF8, tok,tokLen, modelPath)   -> handle | NULL
//   emo_is_downloaded(handle)                                  -> 0/1
//   emo_download(handle)                                       -> 0/-1  (blocks)
//   emo_run(handle, textUTF8, limit, skinTone)                 -> buffer | NULL
//   emo_run_grouped(handle, textUTF8, limit, skinTone, groupId)-> buffer | NULL
//   emo_destroy(handle)
//   emo_string_free(ptr)
//
// Suggestions come back as a self-describing binary buffer (no hand-rolled
// JSON): a big-endian uint32 payload length, then u32 count, then for each
// suggestion a length-prefixed UTF-8 emoji string followed by an f64 confidence.
// `skinTone` is 0 default, 1 light, 2 mediumLight, 3 medium, 4 mediumDark,
// 5 dark. The async core API is bridged synchronously (host worker threads).

/// A retained box so the opaque handle keeps its `Emo` alive.
private final class Handle { let emo: Emo; init(_ emo: Emo) { self.emo = emo } }

private func emo(_ handle: UnsafeMutableRawPointer?) -> Emo? {
    guard let handle else { return nil }
    return Unmanaged<Handle>.fromOpaque(handle).takeUnretainedValue().emo
}

private func skinTone(_ raw: Int32) -> EmojiSkinTone {
    switch raw {
    case 1: .light
    case 2: .mediumLight
    case 3: .medium
    case 4: .mediumDark
    case 5: .dark
    default: .default
    }
}

/// Create a suggester. `cacheRoot` is the app cache dir (the base for the
/// managed nested layout). `directory` is an explicit model directory (adopt
/// files there, else download; direct layout), or NULL for the managed nested
/// layout under `cacheRoot`. Loading is lazy, like the Swift SDK.
@_cdecl("emo_create")
public func emo_create(
    _ cacheRoot: UnsafePointer<CChar>?, _ directory: UnsafePointer<CChar>?
) -> UnsafeMutableRawPointer? {
    let emo = Emo(
        directory: directory.map { String(cString: $0) },
        cacheRoot: cacheRoot.map { String(cString: $0) })
    return Unmanaged.passRetained(Handle(emo)).toOpaque()
}

/// Create a suggester from in-memory bundled model files (the Android AAR path).
@_cdecl("emo_create_bundled")
public func emo_create_bundled(
    _ metaJSON: UnsafePointer<CChar>?,
    _ tokenizer: UnsafePointer<UInt8>?, _ tokenizerLen: Int32,
    _ model: UnsafePointer<UInt8>?, _ modelLen: Int32
) -> UnsafeMutableRawPointer? {
    guard let metaJSON, let tokenizer, let model, tokenizerLen > 0, modelLen > 0 else { return nil }
    guard let assets = try? ModelAssets(
        metaJSON: String(cString: metaJSON),
        tokenizerBytes: Array(UnsafeBufferPointer(start: tokenizer, count: Int(tokenizerLen))),
        modelBytes: Array(UnsafeBufferPointer(start: model, count: Int(modelLen)))) else { return nil }
    return Unmanaged.passRetained(Handle(Emo(assets: assets))).toOpaque()
}

/// Create a suggester from a bundled model **file path** (the Node server-side
/// native, Linux + macOS). `inferenceSession(modelPath:)` inside picks Core ML
/// on Apple hosts (a `.mlmodelc` directory) and LiteRT on Linux (a `.tflite`),
/// so one primitive covers both runtimes. The meta/tokenizer sidecars still
/// cross as bytes; only the model artifact is a path (mmap, no giant copy).
@_cdecl("emo_create_bundled_path")
public func emo_create_bundled_path(
    _ metaJSON: UnsafePointer<CChar>?,
    _ tokenizer: UnsafePointer<UInt8>?, _ tokenizerLen: Int32,
    _ modelPath: UnsafePointer<CChar>?
) -> UnsafeMutableRawPointer? {
    guard let metaJSON, let tokenizer, let modelPath, tokenizerLen > 0 else { return nil }
    guard let assets = try? ModelAssets(
        metaJSON: String(cString: metaJSON),
        tokenizerBytes: Array(UnsafeBufferPointer(start: tokenizer, count: Int(tokenizerLen))),
        modelPath: String(cString: modelPath)) else { return nil }
    return Unmanaged.passRetained(Handle(Emo(assets: assets))).toOpaque()
}

@_cdecl("emo_destroy")
public func emo_destroy(_ handle: UnsafeMutableRawPointer?) {
    guard let handle else { return }
    Unmanaged<Handle>.fromOpaque(handle).release()
}

@_cdecl("emo_is_downloaded")
public func emo_is_downloaded(_ handle: UnsafeMutableRawPointer?) -> Int32 {
    (emo(handle)?.isDownloaded() ?? false) ? 1 : 0
}

/// Download/verify the model ahead of time (blocks). 0 on success, -1 on failure.
@_cdecl("emo_download")
public func emo_download(_ handle: UnsafeMutableRawPointer?) -> Int32 {
    guard let emo = emo(handle) else { return -1 }
    let ok: Bool = blockingValue {
        do { try await emo.download(); return true } catch { return false }
    }
    return ok ? 0 : -1
}

@_cdecl("emo_run")
public func emo_run(
    _ handle: UnsafeMutableRawPointer?, _ text: UnsafePointer<CChar>?,
    _ limit: Int32, _ skinToneRaw: Int32
) -> UnsafeMutablePointer<CChar>? {
    runSuggestions(handle, text, limit, skinToneRaw, groupId: nil)
}

/// Like `emo_run`, but attributes usage to the shared call group named `groupId`
/// (reused across SDKs, via desert-ant-core): every run sharing the id bills as
/// one call, and to a specific end-user `deviceId` (multi-tenant hosts serving
/// many users). Both are optional — pass NULL to omit either. Used by the Node
/// build; each call binds its own device, safe under concurrency. Release the
/// call group with `dal_call_group_end`. (Android calls plain `emo_run` and
/// resolves its own device via the host bridge, so it needs no `deviceId` here.)
@_cdecl("emo_run_grouped")
public func emo_run_grouped(
    _ handle: UnsafeMutableRawPointer?, _ text: UnsafePointer<CChar>?,
    _ limit: Int32, _ skinToneRaw: Int32,
    _ groupId: UnsafePointer<CChar>?, _ deviceId: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>? {
    runSuggestions(
        handle, text, limit, skinToneRaw,
        groupId: groupId.map { String(cString: $0) },
        deviceId: deviceId.map { String(cString: $0) })
}

/// Shared body for `emo_run`/`emo_run_grouped`: run and encode suggestions,
/// binding the shared call group `groupId` and the end-user `deviceId` into the
/// InferenceContext when set.
private func runSuggestions(
    _ handle: UnsafeMutableRawPointer?, _ text: UnsafePointer<CChar>?,
    _ limit: Int32, _ skinToneRaw: Int32, groupId: String?, deviceId: String? = nil
) -> UnsafeMutablePointer<CChar>? {
    guard let emo = emo(handle), let text else { return nil }
    let phrase = String(cString: text)
    let tone = skinTone(skinToneRaw)
    let payload: [UInt8]? = blockingValue {
        let suggestions = await InferenceContext.$deviceId.withValue(deviceId) {
            await InferenceContext.withCallGroup(id: groupId) {
                (try? await emo.suggestions(for: phrase, limit: Int(limit), skinTone: tone)) ?? []
            }
        }
        var w = FFIWriter()
        w.u32(suggestions.count)
        for s in suggestions {
            w.string(s.emoji)
            w.f64(s.confidence)
        }
        return w.bytes
    }
    return payload.flatMap(ffiEmit)
}

@_cdecl("emo_string_free")
public func emo_string_free(_ ptr: UnsafeMutablePointer<CChar>?) {
    ffiFree(ptr)
}
#endif
