# Emo

On-device multilingual emoji suggestion for Swift, Android, and JavaScript. Give Emo a short task, calendar entry, note, or message and it returns ranked emoji, across 23 languages. Everything runs locally, so the text never leaves the device or browser.

A hashed script-aware n-gram stream and a small transformer over a pruned multilingual token sequence run through one shared pipeline, so it reads meaning rather than matching keywords, and the results are the same on every platform.

```text
"Pay my bills"   ->   💰  💳  🧾
"犬の散歩"        ->   🐕  🐾
"go for a run"   ->   🏃   (with a skin tone: 🏃🏽)
```

- [Features](#features)
- [Swift](#swift)
  - [Install](#install)
  - [Usage](#usage)
  - [Example](#example)
- [Android](#android)
  - [Install](#install-1)
  - [Usage](#usage-1)
  - [Example](#example-1)
- [JavaScript and TypeScript](#javascript-and-typescript)
  - [Install](#install-2)
  - [Usage](#usage-2)
  - [Example](#example-2)
- [Suggestions](#suggestions)
- [Model and caching](#model-and-caching)
- [License](#license)

## Features

- Runs fully on device or in the local runtime. The text never leaves the machine.
- Suggests from a curated vocabulary of ~800 everyday emoji, with optional skin tones.
- Multilingual: 23 languages, including CJK, Arabic, Thai, and Hindi.
- One and the same pipeline on every platform, so results match: Core ML on Apple, LiteRT on Android and Linux, LiteRT.js in the browser, and a native Core ML / LiteRT core for server-side Node.
- Small model bundled by default (about 5 MB on Apple, ~11 MB LiteRT), with explicit-directory download/adopt still available; a suggestion is typically well under 2 ms.

## Swift

### Install

Requirements: iOS 16+, macOS 13+, tvOS 16+, watchOS 9+, visionOS 1+, and Swift 5.9+.

Add Emo with Swift Package Manager:

```swift
.package(url: "https://github.com/Desert-Ant-Labs/emo.git", from: "0.10.2")
```

Then add the `Emo` product to your app target.

The Core ML model is bundled by default because Emo is small. `EmoCoreMLResources` remains available for explicit bundle construction and tests. SwiftPM consumers who prefer on-demand download or an explicit model directory can disable the default `BundledModel` trait:

```swift
.package(url: "https://github.com/Desert-Ant-Labs/emo.git", from: "0.10.2", traits: [])
```

With the trait disabled, `Emo()` downloads on demand and `Emo(directory:)` loads from or downloads into your chosen directory.

### Usage

Create one `Emo` and reuse it. Construction is cheap and non-blocking. The model loads on first use, or earlier if you call `download`.

```swift
import Emo

let emo = Emo()
let suggestions = try await emo.suggestions(for: "Pay my bills")
// [EmoSuggestion(emoji: "💰", confidence: ...), ...]

let best = try await emo.suggestions(for: "犬の散歩", limit: 1).first?.emoji            // "🐕"
let toned = try await emo.suggestions(for: "go for a run", limit: 1, skinTone: .medium).first?.emoji  // "🏃🏽"
```

Choose where the model comes from:

```swift
let emo = Emo()                       // bundled model by default
let emo = Emo(directory: myModelDir)  // explicit model directory
let emo = Emo(bundle: myBundle)       // bundled model resources
```

Download ahead of time, for example from an onboarding screen:

```swift
let emo = Emo()
if !emo.isDownloaded() {
    try await emo.download { fraction in
        print("\(Int(fraction * 100))%")
    }
}
```

Bundle the model in an Apple app:

```swift
import Emo
import EmoCoreMLResources

let emo = Emo(bundle: EmoCoreMLResourcesBundle.bundle)
```

### Example

[SwiftUI example app](Examples/EmoExample)

## Android

### Install

Requirements: Android API 24+. The AAR contains prebuilt arm64-v8a and x86_64 native libraries.

Emo is published to Maven Central.

```kotlin
// settings.gradle.kts
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
}

// build.gradle.kts
dependencies {
    implementation("ai.desertant:emo:0.7.0")
}
```

`ai.desertant:emo` bundles the small LiteRT model by default, so normal installs work offline. To disable bundling, exclude the transitive resources artifact:

```kotlin
dependencies {
    implementation("ai.desertant:emo:0.7.0") {
        exclude(group = "ai.desertant", module = "emo-tflite-resources")
    }
}
```

With that exclusion, `Emo(context)` downloads on demand and caches the model. `Emo(context, directory = modelDir)` loads from or downloads into your chosen directory.

### Usage

```kotlin
import ai.desertant.emo.Emo
import ai.desertant.emo.EmojiSkinTone

val emo = Emo(context)                                  // bundled model by default
val suggestions = emo.suggestions("Pay my bills")       // List<EmoSuggestion>

val toned = emo.suggestions("go for a run", limit = 1, skinTone = EmojiSkinTone.MEDIUM)
emo.close()
```

`suggestions` and `download` are `suspend` functions. Use `use` to close the native handle automatically:

```kotlin
Emo(context).use { emo ->
    val suggestions = emo.suggestions("Pay my bills")
}
```

Download before first use:

```kotlin
val emo = Emo(context)
if (!emo.isDownloaded()) {
    emo.download()
}
```

Use an explicit model directory or bundled resources:

```kotlin
val cached = Emo(context)                         // managed cache
val explicit = Emo(context, directory = modelDir) // explicit model directory
val offline = Emo.bundled()                       // explicit bundled constructor
```

### Example

[Android example app](Examples/EmoAndroidExample)

## JavaScript and TypeScript

Two entries share one `Emo` API. The default `@desert-ant-labs/emo` is the browser build (WebAssembly + LiteRT.js); it has no native dependencies, so it bundles cleanly for every target of a multi-target bundler (Next.js, Remix, SvelteKit, Nuxt), including the browser bundle and the Client-Component SSR pass those frameworks render in Node. `@desert-ant-labs/emo/native` is a prebuilt native core for server-side inference in Node.

```bash
# Browser (default entry):
npm i @desert-ant-labs/emo @litertjs/core

# Server-side inference in Node (/native entry) needs no extra install:
npm i @desert-ant-labs/emo
```

The default import is safe to *import* during server-side rendering, but LiteRT.js initializes only in a browser or Web Worker, so `Emo.load()` runs inference in the browser; in plain Node it throws an actionable error pointing you to `@desert-ant-labs/emo/native`. The native build ships for linux-x64, linux-arm64 (LiteRT), and darwin-arm64 (Core ML); other platforms fall back to a clear error, so use the Swift package or a browser there.

### Usage

```ts
import { Emo } from "@desert-ant-labs/emo";           // browser; use "@desert-ant-labs/emo/native" server-side

const emo = await Emo.load();                               // downloads + caches on first use
const suggestions = await emo.suggestions("Pay my bills");  // [{ emoji, confidence }, ...]

const toned = await emo.suggestions("go for a run", { limit: 1, skinTone: "medium" });
emo.dispose();                                              // frees native resources in the /native build; no-op otherwise
```

For server-side inference, import the same API from the native subpath:

```ts
import { Emo } from "@desert-ant-labs/emo/native";    // server only
```

Unlike the Swift and Android packages, the JavaScript package does not bundle the
model: `Emo.load()` downloads it from the Hugging Face Hub at the SDK's pinned tag
on first use and caches it (the OS cache dir for the native build, the fetch cache
in the browser). To self-host or run offline, pass `directory` (native build) or
`modelBaseUrl` (browser):

```js
const emo = await Emo.load({
  directory: "/var/cache/emo",          // native build: adopt/download files here
  modelBaseUrl: "/assets/emo/",         // browser: serve the files yourself
  onProgress: (fraction) => console.log(fraction),
});
```

Bring your own LiteRT.js module (browser), useful for bundlers and React Native:

```js
import * as litert from "@litertjs/core";
import { Emo } from "@desert-ant-labs/emo";

const emo = await Emo.load({ litert, litertWasmDir: "/path/to/@litertjs/core/wasm/" });
```

### Example

[JavaScript examples](Examples/EmoWasmExample)

## Suggestions

All platforms return the same suggestion shape: an emoji and its confidence, ranked most likely first.

- `emoji` - the suggested emoji, with the requested skin tone already applied.
- `confidence` - the model's normalized score in `0...1`.

The field names are identical across Swift (`EmoSuggestion`), Kotlin (`EmoSuggestion`), and TypeScript. `limit` caps how many suggestions come back. `skinTone` (`default`, `light`, `mediumLight`, `medium`, `mediumDark`, `dark`) is applied to skin-tone-capable emoji; empty input returns no suggestions.

## Model and caching

The model artifacts are published at [`desert-ant-labs/emo`](https://huggingface.co/desert-ant-labs/emo) on Hugging Face. Each SDK pins the model revision to its own package version, and downloads are SHA-256 verified.

Default behavior:

- Swift: bundles the Core ML model by default, with explicit-directory download/adopt still available.
- Android: bundles the LiteRT model by default through the normal `ai.desertant:emo` dependency.
- JavaScript: downloads the model from Hugging Face on `Emo.load()` and caches it; the browser build (`@desert-ant-labs/emo`) runs LiteRT.js, and the native build (`@desert-ant-labs/emo/native`) runs Core ML on macOS and LiteRT on Linux for server-side Node. The native build uses `directory` and the browser uses `modelBaseUrl` for self-hosted or offline files.

Passing an explicit `directory` makes that directory the model home. Existing valid files are adopted for offline use; otherwise Emo downloads into that directory and reuses it later.

## License

[Desert Ant Labs Source-Available License](https://license.desertant.com/1.0). Free for
most apps; a commercial license is required at scale. Full terms are at the link.
Licensing: <licensing@desertant.com>.
