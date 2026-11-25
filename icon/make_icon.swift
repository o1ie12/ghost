// Draws icon-1024.png: a black rounded square with a thin, partly drained line.
// Run once from the repo root: swift icon/make_icon.swift
import AppKit

let size = 1024.0
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()

// macOS icon grid: 824 pt artwork centered in 1024, corner radius ~185
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
NSColor(white: 0.07, alpha: 1).setFill()
NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185).fill()

// Track and the remaining part of the line
let track = NSRect(x: 252, y: 500, width: 520, height: 24)
NSColor(white: 1, alpha: 0.16).setFill()
NSBezierPath(roundedRect: track, xRadius: 12, yRadius: 12).fill()
NSColor(white: 1, alpha: 0.95).setFill()
NSBezierPath(roundedRect: NSRect(x: 252, y: 500, width: 312, height: 24), xRadius: 12, yRadius: 12).fill()

img.unlockFocus()

let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: "icon/icon-1024.png"))
print("Wrote icon/icon-1024.png")
