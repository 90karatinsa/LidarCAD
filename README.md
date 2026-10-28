# LidarCAD — iPhone LiDAR 3D Scanner to CAD (Fusion 360, DXF, STL, OBJ, PLY)

**An iOS app that turns iPhone / iPad LiDAR scans into CAD-ready files.** Scan a room, a small region such as a mounting
recess, or a single object, and export clean, metric, axis-aligned geometry for **Autodesk Fusion 360**, Blender, MeshLab,
CloudCompare, Rhino or 3D printing. Everything runs on the device, except Photo Set mode, whose model is built on a Mac at
higher detail.

**Keywords:** iPhone LiDAR scanner, 3D scanning app, LiDAR to CAD, scan to CAD, reverse engineering, photogrammetry,
Apple Object Capture, turntable photogrammetry, ARKit scene reconstruction, RealityKit, mesh export, point cloud, DXF section, floor plan from scan,
room scanning, STL for 3D printing, OBJ, PLY, Fusion 360 workflow, SwiftUI, Swift, iOS 17, iPhone Pro, iPad Pro.

Raw ARKit meshes are a poor fit for CAD: too dense, rotated arbitrarily and in the wrong units. LidarCAD simplifies the mesh,
snaps walls to the X/Y axes, moves the floor to Z = 0, converts to millimetres and slices **DXF cross-sections** at any
height. A DXF section opens directly as a sketch in Fusion 360.

## Four scan modes

| Mode | For | How it works | Default export |
|---|---|---|---|
| **Space** | Rooms, corridors, caves, façades | ARKit scene reconstruction of the whole volume | Medium simplification, wall alignment, 1.2 m floor-plan section, OBJ + STL + DXF |
| **Region** | Recesses, slots, mounting surfaces | Place a crop box; everything outside it is discarded | Fine simplification, no wall alignment, 5 mm point cloud, OBJ + STL + DXF + PLY |
| **Object** | A single free-standing part | Apple Object Capture photogrammetry; walk around the object, the model is reconstructed on device | No simplification, OBJ + STL |
| **Photo Set** | A part you can't walk around | Phone stays fixed, you turn the object; HEIC photos with embedded LiDAR depth, reconstructed on a Mac by `lidarcad-reconstruct` | Full detail, no simplification, OBJ + STL |

All four modes share one export pipeline; only the defaults differ. The cell-based simplification levels (1.2 / 3 / 6 cm)
are sized for rooms; on a small part they erase collars, flanges and threads, so object modes export the mesh as is and the
export screen warns when a chosen level is too coarse for the part. The Mac tool compiles the same `Core` code, so a Photo Set model
goes through exactly the same unit, axis and section steps as an on-device scan.

## Requirements

- iPhone or iPad with LiDAR (Pro models). Developed on iPhone 16 Pro. The simulator has no LiDAR.
- iOS 17 or later (Object Capture requires iOS 17).
- Xcode on a Mac to build (built with Xcode 27). A free Apple ID is enough.
- Photo Set reconstruction: an Apple Silicon Mac. iOS photogrammetry only offers the `reduced` detail level; macOS offers `full` and `raw`.
- No third-party dependencies: only ARKit, RealityKit, Object Capture, AVFoundation, Vision, SwiftUI and simd.

## Build and run

1. Open `LidarCAD.xcodeproj` in Xcode.
2. Copy `Config/Signing.local.xcconfig.example` to `Config/Signing.local.xcconfig` and enter a unique bundle identifier
   (e.g. `com.<yourname>.LidarCAD`) and your Team ID (Xcode → Settings → Accounts). The local file is git-ignored; the
   committed project only carries the `com.example.LidarCAD` placeholder. A bundle ID committed to a public repo can be
   claimed by anyone who builds the project unchanged once a free account's weekly registration lapses, after which Xcode
   refuses your own build with "app identifier is not available".
3. Connect the iPhone, select it as the run destination, press ⌘R.
4. On first launch, trust your developer certificate on the phone: **Settings → General → VPN & Device Management**.

> Apps signed with a free Apple ID stop opening after 7 days; press ⌘R again to renew. A paid Apple Developer account signs for one year.

`project.yml` is a fallback: if the `.xcodeproj` breaks, regenerate it with `brew install xcodegen && xcodegen`.

## Usage

**Space:** scanning starts immediately and the mesh is drawn live over the camera image. Keep 0.5–5 m from surfaces and move
slowly. Finish where you started to close accumulated drift. Tap **Bitir** (Finish) to open the export screen.

**Region:** frame the target and tap **Kutuyu yerleştir** (Place box); the box drops 45 cm in front of you. Resize it between 10 and 150 cm so it
slightly overlaps the target. Scan slowly; anything outside the box is thrown away. The point cloud reads every pixel of the
LiDAR depth map at 30 Hz into 2.5 mm voxels, and only inside the box, so the point budget goes to the region. When you add a section, the app suggests the
model's mid-height.

**Object:** guided flow: detect the object, confirm the bounding box, walk around it, optionally flip it for a second pass of the
underside, finish. Reconstruction runs on device and takes a few minutes. On iOS Apple only allows the `reduced` detail level
(about 25,000 triangles), so the app keeps the photos until the next Object scan: **Tam detay (Mac)** on the export screen sends
them to the Mac, where `lidarcad-reconstruct <zip> --detail raw` rebuilds the same object at several times the detail. The object needs texture and good lighting; shiny metal,
glass and plain white surfaces fail, and a matte spray or powder is the usual fix.

**Photo Set:** for objects you can't walk around. Fix the phone on a stand, put the object on something you can turn (a lazy
susan, a plate, a sheet of card) and rotate it about 10° at a time. Take your hand out of the frame: when the scene settles the app
shoots by itself, so you never touch the phone. About 36 photos make one pass; then lay the object on its side, tap **Nesneyi
çevirdim — yeni tur** (New pass) and go around again to capture the underside. **Bitir** packs the set as a zip for AirDrop.

Lighting decides whether this works. Use diffuse light (a window, ceiling light, overcast daylight). A single hard lamp moves the
shadows across the object as it turns, and photogrammetry reads that as changing geometry (see the verification numbers below).
Let the object fill most of the frame.

## Mac reconstruction (`lidarcad-reconstruct`)

```bash
./mac/build.sh                                  # builds mac/build/lidarcad-reconstruct
./mac/build/lidarcad-reconstruct ~/Downloads/nesne_2026-10-21T201500.zip --sections 0.02,0.05
```

It takes the zip from AirDrop (or the unzipped folder), from either Photo Set or Object mode, and writes `<name>-model/` next to it.
Object mode photos carry Apple's own capture metadata and go to the photogrammetry session as a folder, the path Apple documents
for Object Capture images. Output: a textured `.usdz` for preview and
the same CAD files the phone produces (OBJ, STL, optional DXF sections and mesh PLY, plus the per-scan readme).

| Option | Values | Default |
|---|---|---|
| `--detail` | `preview` `reduced` `medium` `full` `raw` | `full` |
| `--mask` | `auto`: Apple's built-in object masking; `vision`: per-photo mask from Vision, photos where the object can't be separated are skipped; `none` | `auto` |
| `--sensitive` | high feature sensitivity for low-texture objects (slower) | off |
| `--decimate` | `raw` `fine` `medium` `coarse` | `fine` |
| `--unit` | `mm` `cm` `m` | `mm` |
| `--formats` | `obj,stl,plymesh,dxf` | `obj,stl` |
| `--sections` | DXF section heights in metres, comma-separated | none |

Scale comes from the LiDAR depth embedded in each HEIC. Gravity is used only for single-pass sets: once the object has been flipped,
"down" no longer means the same thing for every photo.

**Verification.** `mac/Tests/make-turntable.swift` renders a synthetic turntable set (fixed camera and light, a textured
10 × 6 × 4 box turning in front of a plain background) so the whole Mac path can be tested without a phone. Recovered box
proportions at `reduced` detail, without depth:

| Capture | Mask | Proportions (expected 10 : 6 : 4) |
|---|---|---|
| Turntable, hard directional light, object small in frame | vision | 10 : 8.98 : 4.65 — fails |
| Camera orbits the object, soft light | vision | 10 : 6.34 : 4.14 |
| Turntable, soft light, object fills the frame | vision | 10 : 6.59 : 4.45 |
| Turntable, soft light, object fills the frame | auto | 10 : 5.60 : 4.30 |
| Turntable, soft light, busy static background | vision | 10 : 8.96 : 4.07 — fails (no mask in 19 of 60 photos) |
| Turntable, soft light, busy static background | auto | 10 : 6.30 : 4.08 |

Two conclusions shaped the defaults. Hard light breaks turntable capture regardless of masking, which is why the app's
first-shot hints are mostly about light and framing. And Apple's built-in masking beat per-photo Vision masks on every
turntable set, including the busy background that Vision masks were meant for, so `auto` is the default. The remaining
error is mostly the underside, which a single pass never sees; flipping the object for a second pass covers it.

## Export options

| Setting | Choices | For Fusion 360 |
|---|---|---|
| Unit | m, cm, mm | **mm** |
| Up axis | Y-up, Z-up | **Z-up** |
| Simplification | Raw, Fine 1.2 cm, Medium 3 cm, Coarse 6 cm | **Coarse** for Convert Mesh |
| Align walls to axes | on / off | **On** for rooms |
| Move floor to Z = 0 | on / off | **On** |
| Section heights | any number, one DXF each | 1.0–1.2 m for doors and windows |
| Format | OBJ, STL, PLY mesh, PLY point cloud, DXF | **DXF + OBJ** |

Processing order is fixed: surface-class filter → simplification (vertex clustering) → axis conversion → wall alignment →
floor recentering → unit scaling. The export screen shows the resulting triangle count so you stay under Fusion's Convert Mesh limit.

### Why DXF?

Turning a noisy scan mesh into a solid body rarely works. The professional workflow uses the scan as a **reference**:

1. In Fusion 360, `Insert → Insert DXF` and pick a plane.
2. The section arrives as a sketch.
3. Draw clean, dimensioned geometry on top of it.

### Other formats

- **OBJ / STL:** `Insert → Insert Mesh`; match the unit type. STL is unitless and always read as mm.
- **PLY mesh:** hole filling and Poisson reconstruction in MeshLab.
- **PLY point cloud:** CloudCompare, Rhino. Sharper than the mesh; best for measuring and custom sections.
  Voxel size is 5 mm in Region mode and 1 cm otherwise.

## Getting files to a computer

Use **Share / AirDrop** on the export screen, or the Files app → *On My iPhone* → *LidarCAD* → *Scans*; on a Mac, Finder → iPhone → Files.
Each scan folder includes `OKUBENI.txt` with dimensions, the applied rotation and import steps.

## Accuracy

iPhone LiDAR typically deviates **1–2 cm** at room scale, and drift accumulates along long corridors. Photogrammetry is better but
not guaranteed. A scan gives you **shape and context, not final dimensions.**

- For parts that must fit, measure critical dimensions with calipers and correct them in CAD; verify with a thin test print.
- Leave a known dimension in the scan (a door width, a metre stick); check with `Inspect → Measure` and apply `Scale` if needed.
- Glass, mirrors and glossy black surfaces do not scan; draw those areas by hand.
- LiDAR degrades in direct sunlight.

## Project structure

```
LidarCAD/
├── Core/              ARKit-independent; compiled and tested on macOS
│   ├── Geometry.swift          mesh types, unit and axis conversion
│   ├── Decimator.swift         O(n) vertex-clustering simplification
│   ├── WallAligner.swift       "Manhattan" alignment to the dominant wall direction
│   ├── SectionSlicer.swift     plane–mesh intersection, horizontal and vertical sections
│   ├── CropBox.swift           crop box for Region mode
│   ├── PointCloud.swift        voxel-hash point cloud accumulator
│   ├── ScanKind.swift          scan modes and their defaults
│   ├── CaptureManifest.swift   capture.json shared by the phone and the Mac tool
│   ├── ExportPipeline.swift    options and transform order
│   └── Writers/                OBJ, STL, PLY, DXF writers
├── Scanning/          ARKit and RealityKit layer
│   ├── ScanSession.swift             AR session, mesh anchors, depth frames
│   ├── ARMeshExtraction.swift        ARMeshAnchor → MeshData
│   ├── DepthUnprojector.swift        depth map → coloured points
│   ├── ObjectCaptureController.swift Object Capture wrapper
│   └── RealityMeshExtractor.swift    mesh from the Object Capture model
├── Capture/           Photo Set mode (AVFoundation)
│   ├── PhotoCaptureController.swift  LiDAR depth camera, HEIC with embedded depth, auto shutter
│   └── StillnessDetector.swift       detects the moment the scene settles after a turn
├── Export/            file writing and the per-scan readme
└── UI/                SwiftUI: mode picker, scanning, object flow, export
mac/
├── Reconstruct/       lidarcad-reconstruct: Vision masks, PhotogrammetrySession, USDZ → MeshData
└── Tests/             synthetic turntable generator
Tests/                 macOS verification runner
```

## Tests

`Core` and `Export` do not touch ARKit, so they run directly on macOS without Xcode:

```bash
./Tests/run.sh            # Core, Export, capture manifest, auto shutter
./mac/Tests/run.sh        # Mac tool: depth embedded in HEIC, USD mesh loading
```

113 checks: unit conversion, right-handedness of the axis swap, no degenerate triangles after simplification, wall alignment of a
skewed room, crop box, capture manifest round trip, the auto-shutter state machine, section perimeter, and byte-level format conformance of OBJ, STL, PLY and DXF.

The Mac tests write a HEIC with a known two-level depth map and check that the depth comes back in metres in the right place,
since scale for Photo Set models depends on it.

The app UI and code comments are in Turkish.

## License

Source-available under the **PolyForm Noncommercial License 1.0.0** (see [LICENSE](LICENSE)): free for personal, educational and
research use. **Commercial use requires written permission.** The app uses only Apple's ARKit, RealityKit and Object Capture
frameworks and has no third-party dependencies.
