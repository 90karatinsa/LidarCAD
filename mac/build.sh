#!/bin/bash
# Mac'teki model oluşturma aracını derler. Telefondaki Core + Export kodunu
# aynen kullanır, böylece iki taraf aynı CAD çıktısını üretir.
set -e
cd "$(dirname "$0")/.."
mkdir -p mac/build
swiftc -O -swift-version 5 -o mac/build/lidarcad-reconstruct \
  mac/Reconstruct/*.swift \
  LidarCAD/Core/*.swift \
  LidarCAD/Core/Writers/*.swift \
  LidarCAD/Export/ExportManager.swift
echo "derlendi: mac/build/lidarcad-reconstruct"
