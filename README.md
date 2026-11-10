# Ethers Prism

**Don't ask the AI for the thing. Ask it for an instrument to make the thing.**

Describe a goal and Ethers Prism builds you an editor: dials with named ends, plus fixed requirements. Move the dials, watch previews change, sweep one dial across its range, branch through history, compare states, render the version you choose, and export it with an authorship log. Choosing and editing the dials is part of the authorship.

Text, Image, 3D Stage and Beats are fully working. Video (storyboards), Music Sketch (written sketches), Code (previews) and Research (plans) are labeled unfinished.

## Setup

Needs macOS 14 or later, Xcode 15 or later, Apple Silicon.

1. Double-click `Package.swift` to open it in Xcode.
2. Choose the **EthersPrism** scheme and **My Mac**, then press **⌘R** to run. Press **⌘U** to run the tests.

**Put it in Applications:** in Terminal, in this folder, run `./install-app.sh`. It builds a release version and installs **Ethers Prism.app** (with its icon) in your Applications folder, so it opens from Launchpad, Spotlight or the Dock without Xcode. Run it again after pulling updates.

After building once, you can also start it by double-clicking **Ethers Prism.app** in this folder. It launches your latest Xcode build. From Terminal: `swift run EthersPrism` and `swift test`.

## Agents (Settings → Agents)

Each job has its own agent and model. You still choose the dials and the results; agents only do the job they're given.

| Agent | Job | Default |
|---|---|---|
| Dial Designer | Proposes dials for a goal | LM Studio · Qwen3 8B |
| Writer | Text, music sketches, storyboards, research plans | LM Studio · Qwen3 8B |
| Art Director | Turns dials and requirements into image prompts | LM Studio · Qwen3 8B |
| Coder | The Code field | LM Studio · Qwen3 Coder 30B |
| Checker | Reviews each result against the fixed requirements; flags with quoted evidence, never rewrites | LM Studio · Qwen3 8B |
| Music Producer | For Beats: reads the goal and your sample library, picks the style, up to three kits and the starting dial positions | LM Studio · Qwen3 8B |

Each agent can use Claude (Anthropic), LM Studio, Ollama or Mock. **Teach by example** (on by default): before each job, the Writer, Coder, Art Director and Dial Designer see up to 3 of your recent starred results or hand edits, so they learn your taste. Nothing is trained and nothing leaves your Mac. Agents that must return data (dials, image prompts, reviews) ask local servers for JSON-schema output, and small slips are repaired.

**Memory hand-off:** large local models (20B+) and ComfyUI can't share 24 GB. With hand-off on, ComfyUI releases its model before a large agent runs, and LM Studio unloads large models before ComfyUI renders. Small models stay loaded.

**Models on an external drive:** point LM Studio's models folder at the drive (My Models → folder). Models load into memory once, so a fast SSD keeps loading quick.

## Mixar (Settings → Mixar)

Mixar is an AI 3D editor built on Blender. Ethers Prism connects through Mixar's **Connect MCP** (profile menu → Connect MCP → Turn on) and lists Mixar's tools. Inspecting and rendering in Mixar are free; Mixar's AI generation costs Mixar credits. The **3D Stage (Blender)** field is the free, local alternative: type the path to a GLB, GLTF, OBJ or FBX file as the goal (or anything else for a sample model). Its dials set camera orbit, height, lens, lighting contrast and mood. Previews render with Eevee, full renders with Cycles on the GPU; the first Cycles render compiles GPU code and is slow, later ones are fast.

**Animation (Blender)** renders a spinning planet as an MP4, free and local. Press **Choose Song…** and the planet and its atmosphere pulse to the music, and the song is in the clip (with no song it pulses at 90 BPM). **Choose Planet Image…** wraps your own image around it; otherwise the surface is generated. Dials: Spin speed, Beat strength, Glow, Mood (warm fire to cool ice), Camera drift, Length (2–10 seconds, never longer than the song). Previews are 2 seconds at 640×360 and start only when you press Preview; full renders are 720p at 24 fps with Eevee.

## Video (Settings → Video)

Two separate fields make real clips on this Mac with **LTX Video** through ComfyUI (the same ComfyUI address as images):

- **Text to Video**: describe the shot. Dials: Motion, Camera move, Realism, Mood, Length.
- **Image to Video**: press **Choose Image…** and add a few words about how it should move. Dials: Motion, Camera move, Faithfulness (how closely the clip keeps your image), Atmosphere, Length.

The Art Director agent turns the goal and dials into the long, descriptive prompt LTX Video needs; Length and Faithfulness also set numbers directly. Previews are 1 second at 512 px; full renders run 1–8 seconds at 768 px and can take a long time on a Mac, so video previews start only when you press Preview. Starting another job stops the one in progress, and LM Studio's models are unloaded while a clip renders.

ComfyUI needs two files: `ltx-video-2b-v0.9.5.safetensors` in `models/checkpoints` and `t5xxl_fp16.safetensors` in `models/text_encoders` (the fp8 encoder doesn't run on Apple Silicon). Settings → Video → Check ComfyUI confirms both. Clips are saved as MP4 (animated WebP on older ComfyUI).

## Beats (Settings → Sounds)

The **Beats (your samples)** field makes real audio from your own one-shot samples: Native Instruments Maschine expansions, Battery kits and any folders of WAV, AIFF or FLAC files. No AI and no internet are involved, and the same dials always give the same beat.

1. **Settings → Sounds → Add Folders…** and pick the drive or folders with your samples, for example the Native Instruments drive. The scan sorts every file into kick, snare, clap, closed hat, open hat, percussion, tom, cymbal or bass by its name and folders, and groups files by kit or expansion. Loops, FX and vocals are skipped. The result is saved, so the next launch doesn't rescan.
2. Pick the **Beats** field and type a goal that names a style: *boom bap*, *trap*, *house*, *techno*, *drum and bass*, *lo-fi*, *afro / amapiano* or *reggaeton*. Add a kit or expansion name to use only that kit (for example "dusty lo-fi with Lazer Dice").
3. **Music Producer agent:** when it's set up (Settings → Agents), Suggest Dials asks it to pick the style, up to three kits from your library and where each dial starts. Its picks appear as *Style:* and *Kit:* requirements and dial positions, all of which you can change or delete; suggesting again replaces only its own picks. With no AI at all (Mock), or if the model can't answer, the **built-in producer** takes over: it reads mood words in your goal (slow, dusty, dark, bright, busy, heavy bass…), picks the style and kits whose names match, and says what it heard.
4. **Suggest Dials** gives Tempo, Swing, Density, Variation, Tone, Bass, Kit and Pattern. Previews are 4 bars; **Render Full Quality** makes 16 bars with fills. Sweep the **Kit** dial to hear the same groove through five different kits.
5. **Fixed requirements:** *Must include* limits the beat to kits with that name; *Must avoid* leaves out any sample whose name or folder contains those words.
6. **Teach it your taste:** under each beat, press **Like** or **Not for me**. Prism remembers which sounds, kits and dial positions you like (in a small file on this Mac), plays liked sounds more often, leaves out ones you turned down, and both producers start from what you've liked. Settings → Sounds → **Forget My Ratings** starts over.
7. **Export** writes the WAV, a MIDI file of the same beat (General MIDI drums on channel 10, bass on channel 2) for Maschine, Logic or any DAW, the session file and the authorship log.

Kontakt instruments store their samples in Native Instruments' locked formats (.ncw, .nkx). Those only play inside Kontakt, so the scan counts and skips them. If a kit has no bass samples, a simple built-in sine sub plays the bassline.

## Providers (Settings, ⌘,)

- **Claude:** paste an API key from console.anthropic.com in Settings → Agents. It is stored in your Keychain and never written to sessions or exports.
- **Images:**
  - **ComfyUI on this Mac:** start your instance, enter its address (often `http://127.0.0.1:8188`; some Comfy Desktop setups use `8000`), press *Check Connection* and pick a model. For SDXL Turbo use about 2 preview steps, 6 render steps and CFG 1. Claude writes the image prompt and ComfyUI renders it. Previews are smaller with fewer steps, so they really are faster, and they share a seed with the full render.
  - **Claude SVG drawing:** vector drawings by Claude. A preview costs about the same as a render.
  - **Mock:** placeholder images for testing.
- **Mock** providers are always labeled in the app, so you can't mistake them for real results.

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
