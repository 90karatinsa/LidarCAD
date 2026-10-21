#!/bin/bash
# Mac aracının fotogrametri dışındaki parçaları: HEIC derinliği, USDZ okuma.
set -e
cd "$(dirname "$0")/../.."
OUT=$(mktemp -d); trap 'rm -rf "$OUT"' EXIT
swiftc -O -swift-version 5 -o "$OUT/verify-mac" \
  mac/Tests/verify/main.swift mac/Reconstruct/SampleFactory.swift mac/Reconstruct/MeshLoader.swift \
  LidarCAD/Core/*.swift LidarCAD/Core/Writers/*.swift LidarCAD/Export/ExportManager.swift
"$OUT/verify-mac"
