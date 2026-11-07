# Ethers Prism

**Don't ask the AI for the thing. Ask it for an instrument to make the thing.**

Ethers Prism is a Mac app where you describe a goal and get dials (sliders) instead of a single answer. You play the dials, watch quick previews change, branch off in new directions, and render the version you choose. Your path is saved as an authorship log.

## Run it

Requires macOS 14 (Sonoma) or later and Xcode 15 or later.

1. Unzip, then double-click `Package.swift` to open it in Xcode.
2. Pick the **EthersPrism** scheme and **My Mac**, then press **⌘R**.
3. Run the tests with **⌘U**.

From Terminal: `swift run EthersPrism` to launch, `swift test` for the tests.

The app starts in **Offline demo** mode so you can try everything without a key. For real results, open **Settings (⌘,)**, paste an Anthropic API key from console.anthropic.com, and save it. The key is stored in your Keychain. The model name is editable there too.

## How to use it

1. **Goal.** Pick a field (Writing, Image, Video, Music, Code, Research) and describe what you want.
2. **Suggest Dials.** The AI proposes six dials, each with two named ends. Rename, redefine, delete or add your own with the pencil and the Add Dial button. Choosing the dials is part of the authorship.
3. **Play.** Release a slider and a quick preview appears. **Explore Nearby** nudges every unlocked dial. Use the lock to hold a dial fixed.
4. **Sweep.** Choose one dial to see five previews from 0 to 100 side by side, so you can feel what that dial does. Then pick one.
5. **History.** Every state is kept as a tree. Click any earlier state to go back, then move a dial to branch.
6. **Compare.** Put two states side by side and see which dials changed.
7. **Render Full Quality** when you're happy, ★ it, and **Export** to save the result with its authorship log (plus an `.svg` file for images).

## What each field produces

| Field | Preview / result |
|---|---|
| Writing, Music, Research | Formatted text (a music sketch for Music: tempo, key, sections, chords) |
| Image | SVG illustration drawn by the model |
| Video | Scene-by-scene storyboard (a cheap preview of a video before any expensive render) |
| Code | A single code file |

## Layout

```
Sources/EthersPrismCore   engine, no UI: dials, history tree, compiler, adapters, providers, storage
Sources/Ethers Prism       SwiftUI app
Tests/EthersPrismCoreTests
```

Sessions are saved as JSON in `~/Library/Application Support/Ethers Prism/Sessions`.

## Add a new field

Each field is a `DomainAdapter`. For most fields, add one entry to `Domains` in `Adapters.swift`:

```swift
public static let recipe = BasicAdapter(
    id: "recipe", name: "Recipe", symbol: "fork.knife", outputKind: .text,
    axisHint: "spice, effort, tradition vs fusion, richness, portion size",
    role: "You are a chef.",
    format: "Ingredients list, then numbered steps.",
    previewTokens: 500, renderTokens: 2500)
```

Then add `recipe` to `Domains.all`. It appears in the Field picker automatically.

If a field needs its own output type (audio, real video, 3D), add a case to `OutputKind`, a view for it in `OutputView`, and write a custom type that conforms to `DomainAdapter`. To use a different AI service or a local model, write a type that conforms to `ModelProvider`.
