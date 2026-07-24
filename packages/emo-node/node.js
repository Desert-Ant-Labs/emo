// On-device multilingual emoji suggestion for JavaScript, server-side (Node).
// This is the `node` conditional-exports entry: it runs the same Emo pipeline as
// the browser build, but natively via the prebuilt Swift core (LiteRT under the
// hood) instead of WebAssembly + LiteRT.js. Consumers just `import { Emo }` —
// Node resolves this file, browsers resolve `browser.js`. No flags, no setup.
//
// The koffi harness (resolve native/<platform>-<arch>, load the LiteRT runtime
// first, bind the C ABI, run blocking calls off the event loop) and the FFI
// buffer decode live in @desert-ant-labs/core/node; this file supplies the C
// ABI, the model decode, and the public API.
import { fileURLToPath } from "node:url";
import path from "node:path";
import { loadNative } from "@desert-ant-labs/core/node";

const HERE = path.dirname(fileURLToPath(import.meta.url));

const SKIN_TONES = { default: 0, light: 1, mediumLight: 2, medium: 3, mediumDark: 4, dark: 5 };
const MODEL_REPO = "desert-ant-labs/emo";
const MODEL_REVISION = "v0.7.0";

// The prebuilt native for this host lives in native/<platform>-<arch>/ next to
// this file (built by `mise run node-natives`): the self-contained Swift core
// (libEmoNode) plus the LiteRT runtime it links (libLiteRt).
const core = loadNative({
  here: HERE,
  packageName: "@desert-ant-labs/emo",
  coreName: "EmoNode",
  symbols: {
    create: "void* emo_create(const char*, const char*)",
    isDownloaded: "int emo_is_downloaded(void*)",
    download: "int emo_download(void*)",
    run: "void* emo_run(void*, const char*, int, int)",
    destroy: "void emo_destroy(void*)",
    stringFree: "void emo_string_free(void*)",
  },
});
const { lib, callAsync, decodeResult } = core;

/** Decode the FFI buffer the core returns: a u32 count, then per suggestion a
 *  u32-length UTF-8 emoji string and an IEEE-754 double confidence, read off the
 *  shared FfiReader. Mirrors `emo_run` in Sources/EmoAndroid/CABI.swift. */
function decodeSuggestions(r) {
  const count = r.u32();
  const out = [];
  for (let i = 0; i < count; i++) {
    const emoji = r.str();
    const confidence = r.f64();
    out.push({ emoji, confidence });
  }
  return out;
}

/**
 * On-device multilingual emoji suggestion. Create one with `await Emo.load(...)`
 * and reuse it, mirroring the browser SDK and the iOS/Swift SDK.
 *
 * ```js
 * const emo = await Emo.load();                        // downloads the model on first use, cached
 * const suggestions = await emo.suggestions("Pay my bills");  // [{ emoji, confidence }, ...]
 * emo.dispose();                                       // free the native handle when done
 * ```
 */
export class Emo {
  #handle;
  constructor(handle) { this.#handle = handle; }

  /**
   * Load the model and return a ready suggester. By default the model is
   * downloaded from the Hugging Face Hub at the pinned revision, SHA-256
   * verified, and cached under the OS cache dir by the native core; the repo
   * and revision are pinned to the SDK. Pass a `directory` to adopt self-hosted
   * files (offline) instead of downloading.
   *
   * The server-side native runs LiteRT on Linux (from the `.tflite`) and Core ML
   * on macOS (from the compiled `.mlmodelc` directory); the core downloads only
   * this host's artifact and loads it by path - one primitive, both runtimes.
   */
  static async load(options = {}) {
    const onProgress = typeof options.onProgress === "function" ? options.onProgress : undefined;
    // The Swift package still supports bundled resources for native apps. The
    // npm package does not ship that bundle, so Node always passes an explicit
    // model directory. By default it mirrors the native managed-cache layout;
    // `directory` still adopts a consumer-provided folder for offline use.
    const cacheRoot = options.cacheRoot ?? core.defaultCacheRoot();
    const modelDirectory = options.directory ?? path.join(cacheRoot, "desert-ant-models", MODEL_REPO, MODEL_REVISION);
    const handle = lib.create(cacheRoot, modelDirectory);
    if (!handle) throw new Error("@desert-ant-labs/emo: failed to create suggester");
    const emo = new Emo(handle);
    // Ready the model now (download if needed) so the first suggestion is instant
    // and load() surfaces any download error.
    if (lib.isDownloaded(handle) === 0) {
      onProgress?.(0);
      const rc = await callAsync(lib.download, handle);
      if (rc !== 0) { emo.dispose(); throw new Error("@desert-ant-labs/emo: model download failed"); }
    }
    onProgress?.(1);
    return emo;
  }

  /**
   * Suggest emojis for `text`, most likely first. Returns up to `limit`
   * `{ emoji, confidence }` suggestions; empty input returns `[]`.
   */
  async suggestions(text, options = {}) {
    if (!this.#handle) throw new Error("@desert-ant-labs/emo: suggester disposed");
    const phrase = String(text ?? "");
    if (phrase.trim() === "") return [];
    const limit = options.limit ?? 3;
    const skinTone = SKIN_TONES[options.skinTone ?? "default"] ?? 0;
    const ptr = await callAsync(lib.run, this.#handle, phrase, limit, skinTone);
    if (!ptr) throw new Error("@desert-ant-labs/emo: suggestion failed");
    try {
      return decodeSuggestions(decodeResult(ptr));
    } finally {
      lib.stringFree(ptr);
    }
  }

  /** Free the native handle. Call when you are done with the suggester. */
  dispose() {
    if (this.#handle) { lib.destroy(this.#handle); this.#handle = null; }
  }
}
