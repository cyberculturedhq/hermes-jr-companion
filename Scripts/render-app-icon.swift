#!/usr/bin/env swift
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Rebuild with: swift -module-cache-path /tmp/hermes-icon-cache Scripts/render-app-icon.swift
// The operating system supplies the app icon's rounded mask.
let size = 1024
let sourcePath = CommandLine.arguments.dropFirst().first
    ?? "Hermes/Assets.xcassets/HermesJrArtwork.imageset/HermesJrArtwork.png"
let destinationPath = CommandLine.arguments.dropFirst(2).first
    ?? "Hermes/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
let sourceURL = URL(fileURLWithPath: sourcePath) as CFURL
let destinationURL = URL(fileURLWithPath: destinationPath) as CFURL

guard let imageSource = CGImageSourceCreateWithURL(sourceURL, nil) else {
    fputs("Could not read artwork at \(sourcePath)\n", stderr)
    exit(1)
}

let thumbnailOptions: [CFString: Any] = [
    kCGImageSourceCreateThumbnailFromImageAlways: true,
    kCGImageSourceCreateThumbnailWithTransform: true,
    kCGImageSourceThumbnailMaxPixelSize: size
]
guard let icon = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, thumbnailOptions as CFDictionary),
      icon.width == size, icon.height == size,
      let destination = CGImageDestinationCreateWithURL(
        destinationURL, UTType.png.identifier as CFString, 1, nil
      ) else {
    fputs("Could not resize the square artwork to \(size)×\(size)\n", stderr)
    exit(1)
}

CGImageDestinationAddImage(destination, icon, nil)
guard CGImageDestinationFinalize(destination) else {
    fputs("Could not write app icon to \(destinationPath)\n", stderr)
    exit(1)
}

print("Wrote \(destinationPath)")
