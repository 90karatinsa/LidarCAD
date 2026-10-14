# LidarCAD — iPhone LiDAR 3D Scanner to CAD (Fusion 360, DXF, STL, OBJ, PLY)

**An iOS app that turns iPhone / iPad LiDAR scans into CAD-ready files.** Scan a room, a small region such as a mounting
recess, or a single object, and export clean, metric, axis-aligned geometry for **Autodesk Fusion 360**, Blender, MeshLab,
CloudCompare, Rhino or 3D printing. Everything is processed on the device.

**Keywords:** iPhone LiDAR scanner, 3D scanning app, LiDAR to CAD, scan to CAD, reverse engineering, photogrammetry,
Apple Object Capture, ARKit scene reconstruction, RealityKit, mesh export, point cloud, DXF section, floor plan from scan,
room scanning, STL for 3D printing, OBJ, PLY, Fusion 360 workflow, SwiftUI, Swift, iOS 17, iPhone Pro, iPad Pro.

Raw ARKit meshes are a poor fit for CAD: too dense, rotated arbitrarily and in the wrong units. LidarCAD simplifies the mesh,
snaps walls to the X/Y axes, moves the floor to Z = 0, converts to millimetres and slices **DXF cross-sections** at any
height. A DXF section opens directly as a sketch in Fusion 360.

## Three scan modes

| Mode | For | How it works | Default export |
|---|---|---|---|
| **Space** | Rooms, corridors, caves, façades | ARKit scene reconstruction of the whole volume | Medium simplification, wall alignment, 1.2 m floor-plan section, OBJ + STL + DXF |
| **Region** | Recesses, slots, mounting surfaces | Place a crop box; everything outside it is discarded | Fine simplification, no wall alignment, 5 mm point cloud, OBJ + STL + DXF + PLY |
| **Object** | A single free-standing part | Apple Object Capture photogrammetry; walk around the object, the model is reconstructed on device | Fine simplification, OBJ + STL |

All three modes share one export pipeline; only the defaults differ.

## Requirements

- iPhone or iPad with LiDAR (Pro models). Developed on iPhone 16 Pro. The simulator has no LiDAR.
- iOS 17 or later (Object Capture requires iOS 17).
- Xcode on a Mac to build (built with Xcode 27). A free Apple ID is enough.
- No third-party dependencies: only ARKit, RealityKit, Object Capture, SwiftUI and simd.

## Build and run

1. Open `LidarCAD.xcodeproj` in Xcode.
2. Select the **LidarCAD** target → **Signing & Capabilities**: choose your Apple ID as **Team** and change the
   **Bundle Identifier** to something unique, e.g. `com.<yourname>.LidarCAD`.
3. Connect the iPhone, select it as the run destination, press ⌘R.
4. On first launch, trust your developer certificate on the phone: **Settings → General → VPN & Device Management**.

> Apps signed with a free Apple ID stop opening after 7 days; press ⌘R again to renew. A paid Apple Developer account signs for one year.

`project.yml` is a fallback: if the `.xcodeproj` breaks, regenerate it with `brew install xcodegen && xcodegen`.

## Usage

**Space:** scanning starts immediately and the mesh is drawn live over the camera image. Keep 0.5–5 m from surfaces and move
slowly. Finish where you started to close accumulated drift. Tap **Bitir** (Finish) to open the export screen.

**Region:** frame the target and tap **Kutuyu yerleştir** (Place box); the box drops 45 cm in front of you. Resize it between 10 and 150 cm so it
slightly overlaps the target. Scan slowly; anything outside the box is thrown away. When you add a section, the app suggests the
model's mid-height.

**Object:** guided flow: detect the object, confirm the bounding box, walk around it, optionally flip it for a second pass of the
underside, finish. Reconstruction runs on device and takes a few minutes. The object needs texture and good lighting; shiny metal,
glass and plain white surfaces fail, and a matte spray or powder is the usual fix.

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
│   ├── ExportPipeline.swift    options and transform order
│   └── Writers/                OBJ, STL, PLY, DXF writers
├── Scanning/          ARKit and RealityKit layer
│   ├── ScanSession.swift             AR session, mesh anchors, depth frames
│   ├── ARMeshExtraction.swift        ARMeshAnchor → MeshData
│   ├── DepthUnprojector.swift        depth map → coloured points
│   ├── ObjectCaptureController.swift Object Capture wrapper
│   └── RealityMeshExtractor.swift    mesh from the Object Capture model
├── Export/            file writing and the per-scan readme
└── UI/                SwiftUI: mode picker, scanning, object flow, export
Tests/                 macOS verification runner
```

## Tests

`Core` and `Export` do not touch ARKit, so they run directly on macOS without Xcode:

```bash
./Tests/run.sh
```

98 checks: unit conversion, right-handedness of the axis swap, no degenerate triangles after simplification, wall alignment of a
skewed room, crop box, section perimeter, and byte-level format conformance of OBJ, STL, PLY and DXF.

The app UI and code comments are in Turkish.

## License

Source-available under the **PolyForm Noncommercial License 1.0.0** (see [LICENSE](LICENSE)): free for personal, educational and
research use. **Commercial use requires written permission.** The app uses only Apple's ARKit, RealityKit and Object Capture
frameworks and has no third-party dependencies.
