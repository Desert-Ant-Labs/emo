// Optional bundled model for Emo on Android; the ai.desertant.model-resources
// convention plugin packages the LiteRT files staged by `mise run android-natives`.
plugins { id("ai.desertant.model-resources") }
version = "0.10.1"
desertAntResources { tfliteFiles = listOf("emo.tflite", "emo_meta.json", "emo_tokenizer.bin") }
