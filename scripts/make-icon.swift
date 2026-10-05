#!/usr/bin/env swift
// Turns full-bleed square artwork into a macOS app icon (.icns):
// masks it to Apple's continuous-corner squircle on the standard 1024 grid
// (824 pt tile, 100 pt margin), adds the system-style drop shadow, then
// renders every size iconutil expects.
//
//   swift scripts/make-icon.swift Resources/AppIcon-source.png Resources/AppIcon.icns

import AppKit
import SwiftUI

let arguments = CommandLine.arguments
guard arguments.count == 3, let artwork = NSImage(contentsOfFile: arguments[1]) else {
  print("usage: make-icon.swift <artwork.png> <output.icns>")
  exit(1)
}
let output = URL(fileURLWithPath: arguments[2])

func renderIcon(pixels: Int) -> Data {
  let scale = CGFloat(pixels) / 1024
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  let context = NSGraphicsContext.current!.cgContext
  context.scaleBy(x: scale, y: scale)

  let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
  let squircle = RoundedRectangle(cornerRadius: 185.4, style: .continuous).path(in: tile).cgPath

  // Shadow beneath the tile, like Apple's own icons.
  context.saveGState()
  context.setShadow(offset: CGSize(width: 0, height: -10), blur: 28,
                    color: NSColor.black.withAlphaComponent(0.35).cgColor)
  context.addPath(squircle)
  context.setFillColor(NSColor.black.cgColor)
  context.fillPath()
  context.restoreGState()

  // Artwork clipped to the squircle.
  context.saveGState()
  context.addPath(squircle)
  context.clip()
  artwork.draw(in: tile, from: .zero, operation: .copy, fraction: 1)
  context.restoreGState()

  // Hairline inner highlight so the edge reads on dark wallpapers.
  context.addPath(squircle)
  context.setStrokeColor(NSColor.white.withAlphaComponent(0.12).cgColor)
  context.setLineWidth(2)
  context.strokePath()

  NSGraphicsContext.restoreGraphicsState()
  return rep.representation(using: .png, properties: [:])!
}

let iconset = FileManager.default.temporaryDirectory.appending(path: "AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for points in [16, 32, 128, 256, 512] {
  try renderIcon(pixels: points).write(to: iconset.appending(path: "icon_\(points)x\(points).png"))
  try renderIcon(pixels: points * 2).write(to: iconset.appending(path: "icon_\(points)x\(points)@2x.png"))
}
// Also keep a 1024 PNG for the README.
try renderIcon(pixels: 1024).write(to: output.deletingPathExtension().appendingPathExtension("png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote \(output.path)" : "iconutil failed")
