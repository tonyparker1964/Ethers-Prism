# Ethers Prism

**Don't ask the AI for the thing. Ask it for an instrument to make the thing.**

Describe a goal and Ethers Prism builds you an editor: dials with named ends, plus fixed requirements. Move the dials, watch previews change, sweep one dial across its range, branch through history, compare states, render the version you choose, and export it with an authorship log. Choosing and editing the dials is part of the authorship.

Text and Image are fully working. Video (storyboards), Music (written sketches), Code (previews) and Research (plans) are labeled unfinished.

## Setup

Needs macOS 14 or later, Xcode 15 or later, Apple Silicon.

1. Double-click `Package.swift` to open it in Xcode.
2. Choose the **EthersPrism** scheme and **My Mac**, then press **⌘R** to run. Press **⌘U** to run the tests.

After building once, you can also start it by double-clicking **Ethers Prism.app** in this folder. It launches your latest Xcode build. From Terminal: `swift run EthersPrism` and `swift test`.

## Providers (Settings, ⌘,)

- **Text:** Anthropic (Claude) or Mock. Paste an API key from console.anthropic.com. It is stored in your Keychain and never written to sessions or exports. The model name is editable.
- **Images:**
  - **ComfyUI on this Mac:** start your instance, enter its address (often `http://127.0.0.1:8188`; some Comfy Desktop setups use `8000`), press *Check Connection* and pick a model. For SDXL Turbo use about 2 preview steps, 6 render steps and CFG 1. Claude writes the image prompt and ComfyUI renders it. Previews are smaller with fewer steps, so they really are faster, and they share a seed with the full render.
  - **Claude SVG drawing:** vector drawings by Claude. A preview costs about the same as a render.
  - **Mock:** placeholder images for testing.
- **Mock** providers are always labeled in the app, so you can't mistake them for real results.
- Ollama and LM Studio are planned and shown as not yet available.

## Using it

1. Pick a field, type a goal, press **Suggest Dials** (4–8 dials). Edit, add, delete, reorder (pencil → Move Up/Down) or lock any dial.
2. Add **fixed requirements** (accuracy, accessibility, must include, must avoid). They are never put on sliders.
3. Release a slider and a preview appears once the dials stop moving. **Explore Nearby** nudges unlocked dials. **Render Full Quality** when you're ready.
4. **Edit Text** to change a result by hand. Saving makes a new history state, and regenerating never overwrites it.
5. **Sweep** one unlocked dial: five previews at 0/25/50/75/100. *Use This* saves it as a branch.
6. **History** is a tree. Click any state to return to it, then change something to branch.
7. **Compare** two states side by side, including differences in goal, dials and requirements.
8. **Templates:** *Save Editor as Template* and *New from Template*. Three editable examples are included.
9. **Export** writes the result, a portable session file and a readable authorship log into a folder. **Import Session** opens a session file.

## Storage

`~/Library/Application Support/Ethers Prism/` holds `Sessions/` (versioned JSON, saved atomically), `Assets/<session>/` (generated media, referenced by relative paths) and `Templates/`. Imported files are validated: newer formats are refused and any path that could leave the Assets folder is dropped.

## Layout

```
Sources/EthersPrismCore/   no UI, no vendor SDKs
  Core/       Dial, Constraint, Session, history tree, sweep, templates
  Compile/    deterministic compiler, dial suggester, output cleaning
  Adapters/   DomainAdapter protocol, Text, Image, unfinished fields
  Providers/  Anthropic, ComfyUI, Claude SVG, Mock
  Storage/    sessions, assets, templates, import validation
  Export/     authorship log, result files
Sources/EthersPrism/       SwiftUI app (Workspace, Displays, Sheets, Settings)
Tests/EthersPrismCoreTests
```

## Add a field (domain adapter)

1. Write a type that conforms to `DomainAdapter` (see `Adapters/Adapters.swift`). Give it an `id`, `name`, `status`, `capabilities`, `dialHint`, a deterministic `compile`, and `preview` and `render` that return a `Generated` (text and/or asset bytes). Most text-shaped fields are just a configured `TextAdapter`.
2. Add it to `Domains.all`.
3. If it produces a new kind of output, add a case to `OutputKind` and one display in `Displays/Displays.swift`.

Sessions, history, sweep, compare, templates, storage and export work automatically. Mark a field `.unfinished("what it can't do yet")` until it truly delivers. `Session.projectID` is reserved for linking sessions across fields under one project later.
