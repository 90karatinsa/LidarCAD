#!/bin/bash
# Core + Export kodunu macOS'ta derleyip sınar. Xcode gerekmez.
set -e
cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
swiftc -O -swift-version 5 -o "$OUT/verify" \
  LidarCAD/Core/Geometry.swift \
  LidarCAD/Core/Decimator.swift \
  LidarCAD/Core/SectionSlicer.swift \
  LidarCAD/Core/WallAligner.swift \
  LidarCAD/Core/CropBox.swift \
  LidarCAD/Core/ScanKind.swift \
  LidarCAD/Core/PointCloud.swift \
  LidarCAD/Core/ExportPipeline.swift \
  LidarCAD/Core/Writers/BinaryBuffer.swift \
  LidarCAD/Core/Writers/OBJWriter.swift \
  LidarCAD/Core/Writers/STLWriter.swift \
  LidarCAD/Core/Writers/PLYWriter.swift \
  LidarCAD/Core/Writers/DXFWriter.swift \
  LidarCAD/Export/ExportManager.swift \
  Tests/main.swift
"$OUT/verify"
