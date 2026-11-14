# Ethers Prism

**Don't ask the AI for the thing. Ask it for an instrument to make the thing.**

**Version 1.4.0** (shown in the sidebar under the logo and in Ethers Prism → About). See [Versions](#versions).

Describe a goal and Ethers Prism builds you an editor: dials with named ends, plus fixed requirements. Move the dials, watch previews change, sweep one dial across its range, branch through history, compare states, render the version you choose, and export it with an authorship log. Choosing and editing the dials is part of the authorship.

Eight fields, all working and all local: **Text**, **Image**, **3D Stage (Blender)**, **3D from Image (Blender)**, **Animation (Blender)**, **Line Logo (Grease Pencil)**, **Blender Script (from Claude)** and **Beats (your samples)**.

Retired fields (Video Storyboard, Music Sketch, Code, Research, Text to Video, Image to Video) are no longer offered for new work, but sessions made with them still open with their results. Text to Video and Image to Video are parked on the `ltx-mlx` branch until LTX runs on this Mac.

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
| Writer | The Text field | LM Studio · Qwen3 8B |
| Art Director | Turns dials and requirements into image prompts | LM Studio · Qwen3 8B |
| Checker | Reviews each result against the fixed requirements; flags with quoted evidence, never rewrites | LM Studio · Qwen3 8B |
| Music Producer | For Beats: reads the goal and your sample library, picks the style, up to three kits and the starting dial positions | LM Studio · Qwen3 8B |

Each agent can use Claude (Anthropic), LM Studio, Ollama or Mock. **Teach by example** (on by default): before each job, the Writer, Art Director and Dial Designer see up to 3 of your recent starred results or hand edits, so they learn your taste. Nothing is trained and nothing leaves your Mac. Agents that must return data (dials, image prompts, reviews) ask local servers for JSON-schema output, and small slips are repaired.

**Memory hand-off:** large local models (20B+) and ComfyUI can't share 24 GB. With hand-off on, ComfyUI releases its model before a large agent runs, and LM Studio unloads large models before ComfyUI renders. Small models stay loaded.

**Models on an external drive:** point LM Studio's models folder at the drive (My Models → folder). Models load into memory once, so a fast SSD keeps loading quick.

## Mixar (Settings → Mixar)

Mixar is an AI 3D editor built on Blender. Ethers Prism connects through Mixar's **Connect MCP** (profile menu → Connect MCP → Turn on) and lists Mixar's tools. Inspecting and rendering in Mixar are free; Mixar's AI generation costs Mixar credits. The **3D Stage (Blender)** field is the free, local alternative: type the path to a GLB, GLTF, OBJ or FBX file as the goal (or anything else for a sample model). Its dials set camera orbit, height, lens, lighting contrast and mood. Previews render with Eevee, full renders with Cycles on the GPU; the first Cycles render compiles GPU code and is slow, later ones are fast.

**Animation (Blender)** renders a spinning planet as an MP4, free and local. Press **Choose Song…** and the planet and its atmosphere pulse to the music, and the song is in the clip (with no song it pulses at 90 BPM). **Choose Planet Image…** wraps your own image around it; otherwise the surface is generated. Dials: Spin speed, Beat strength, Glow, Mood (warm fire to cool ice), Camera drift, Length (2–10 seconds, never longer than the song). Previews are 2 seconds at 640×360 and start only when you press Preview; full renders are 720p at 24 fps with Eevee.

## Video (retired for now)

Text to Video and Image to Video (LTX) are hidden, along with Settings → Video. LTX through ComfyUI and LTX-2.5 natively with MLX are both kept on the `ltx-mlx` branch; see `Support/ltx-mlx/STATUS.md` there for why it doesn't run on the 24 GB M4 yet.

## 3D from Image (Blender)

Turns any picture into a 3D model, renders it, and saves the model as a GLB. **Relief** (Mode toward the left) raises the light parts and sinks the dark parts, like a carved plaque; **Extrude** (toward the right) pulls the picture's outline, or a logo's lines, out into a solid with bevelled edges. Pictures with a transparent background are cut out to their shape; on others the background colour is treated as empty. Dials: Mode, Depth, Bevel, Material (metal ↔ glass ↔ neon), Detail, Color (one tint ↔ the picture's colors), Light angle, Camera angle. Previews take a few seconds; Render Full Quality makes a 1080p picture and keeps the model in Documents → Ethers Prism Exports → 3D Models. **Open in 3D Stage** starts a 3D Stage session with the model.

## Line Logo (Grease Pencil)

Blender traces a logo image into Grease Pencil lines that draw themselves on, as an MP4. Leave the goal empty to use the Ether Frequency emblem (`Examples/ether-frequency-emblem.png`), or press **Choose Logo…**. Lines keep the logo's own colors (or glow white), draw from the centre outward, boil slightly like hand-drawn animation, and can hold on 2s or 3s; glow lines and bloom make it neon. Dials: Draw speed, Line weight, Wobble, Timing, Glow, Detail, Ink, Camera push, Length. Previews are 2 seconds at 640×360 and take a few seconds; full renders are 720p, 3–12 seconds.

## Blender Script (from Claude)

Ask Claude for a scene and copy the script it writes. With this field open, Prism picks the script up from the clipboard by itself (or press **Paste Script**), saves it in `~/Documents/Ethers Prism Exports/Blender Scripts/`, and previews one frame. **Render Full Quality** renders the whole animation as MP4 (kept in the same folder). **Library** reopens any saved script; **Open in Blender** opens it in Blender's window to tweak by hand; **Copy Error** copies a failed script's error to paste back into Claude. **Copy Instructions for Claude** copies text for a Claude project's instructions so its scripts suit this field (title line, no render calls, Blender 5.2 Grease Pencil notes). Only text that imports `bpy` is picked up, and only while this field is open and Prism is in front.

## Blender cheat sheet

[Docs/Blender-Cheat-Sheet.md](Docs/Blender-Cheat-Sheet.md) is a full Blender 5.2 reference for Prism: the command line, the Python API, Grease Pencil, modifiers and effects, Line Art, rendering and video, the compositor, and recipes for line-art and animatic work. It is built into the app:

- The **Coder** agent gets it automatically whenever a goal mentions Blender, bpy, Grease Pencil, Line Art or EEVEE.
- In the Blender Script field, **Cheat Sheet** saves it to `~/Documents/Ethers Prism Exports/` and shows it in Finder, ready to add to your Claude project's knowledge. The Claude Instructions tell Claude to follow it.

After editing the doc, run `python3 scripts/sync-blender-reference.py` to rebuild the built-in copy (a test checks they match).

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

## Versions

The number lives in `Sources/EthersPrismCore/Core/AppVersion.swift` and `Support/Info.plist` (a test keeps them in step). The middle number goes up for new fields or features, the last for fixes. After an update, run `./install-app.sh` to refresh the copy in Applications.

- **1.4.0** (Nov 11, 2026): Cleaner macOS look: sessions grouped by field with search, Preview and Render in the toolbar and at the bottom of the controls, grouped settings-style controls, History in a side inspector, results shown on a canvas. Blender Script errors show only the script's own lines.
- **1.3.0** (Nov 11, 2026): Blender Script (from Claude) field: scripts copied from Claude fill in by themselves, are saved in a library, preview as one frame and render as MP4.
- **1.2.0** (Nov 11, 2026): 3D from Image (Blender) field with Relief and Extrude, metal/glass/neon materials, and Open in 3D Stage.
- **1.1.0** (Nov 11, 2026): Line Logo (Grease Pencil) field. One app with six working fields; unfinished and LTX fields retired (old sessions still open). Line Logo, Animation and 3D Stage run with an empty goal. Version shown in the sidebar and About box.
- **1.0**: Text, Image, 3D Stage, Animation, Beats, agents, Teach by Example, Mixar connector.
