#!/usr/bin/env swift
// Generates installer-background.png for the FITS Blaster DMG.
// Run with: swift make-dmg-background.swift
// No dependencies — uses AppKit directly via Swift.

import AppKit
import CoreGraphics

let W: CGFloat = 800
let H: CGFloat = 400
let out = "installer-background.png"

// ── Canvas ────────────────────────────────────────────────────────────────────
let image = NSImage(size: NSSize(width: W, height: H))
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError() }

// ── Gradient background (#08091a → #12103a) ───────────────────────────────────
let colorSpace = CGColorSpaceCreateDeviceRGB()
let gradColors: [CGFloat] = [
    0.031, 0.035, 0.102, 1.0,   // #08091a  top
    0.071, 0.063, 0.227, 1.0,   // #12103a  bottom
]
let gradient = CGGradient(colorSpace: colorSpace, colorComponents: gradColors, locations: [0, 1], count: 2)!
ctx.drawLinearGradient(gradient,
    start: CGPoint(x: 0, y: H), end: CGPoint(x: W, y: 0), options: [])

// ── Star field ────────────────────────────────────────────────────────────────
srand48(42)
for _ in 0..<160 {
    let x = CGFloat(drand48()) * W
    let y = CGFloat(drand48()) * H
    let r = CGFloat(drand48()) * 1.3 + 0.5
    let a = CGFloat(drand48()) * 0.4 + 0.15
    if (110..<300).contains(x) && (100..<280).contains(y) { continue }
    if (510..<700).contains(x) && (100..<280).contains(y) { continue }
    NSColor(white: 1, alpha: a).setFill()
    NSBezierPath(ovalIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)).fill()
}

// ── Soft glow behind app icon ─────────────────────────────────────────────────
NSColor(red: 0.2, green: 0.25, blue: 0.7, alpha: 0.12).setFill()
NSBezierPath(ovalIn: CGRect(x: 110, y: 95, width: 180, height: 180)).fill()

// ── Arrow ─────────────────────────────────────────────────────────────────────
let arrowY: CGFloat = H - 195
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 325, y: arrowY))
arrow.line(to: NSPoint(x: 470, y: arrowY))
arrow.move(to: NSPoint(x: 452, y: arrowY - 10))
arrow.line(to: NSPoint(x: 470, y: arrowY))
arrow.line(to: NSPoint(x: 452, y: arrowY + 10))
arrow.lineWidth = 2.5
arrow.lineCapStyle = .round
NSColor(white: 1, alpha: 0.25).setStroke()
arrow.stroke()

// ── Text helper ───────────────────────────────────────────────────────────────
let centre = NSMutableParagraphStyle()
centre.alignment = .center

func drawText(_ text: String, y: CGFloat, font: NSFont, color: NSColor) {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: centre,
    ]
    text.draw(in: CGRect(x: 0, y: y, width: W, height: 40), withAttributes: attrs)
}

// ── App name ──────────────────────────────────────────────────────────────────
drawText("FITS Blaster",
         y: H - 68,
         font: .boldSystemFont(ofSize: 28),
         color: NSColor(white: 0.95, alpha: 1))

// ── Tagline ───────────────────────────────────────────────────────────────────
drawText("Fast, focused FITS image culling for astrophotographers",
         y: H - 96,
         font: .systemFont(ofSize: 13),
         color: NSColor(white: 0.55, alpha: 1))

// ── Bottom hint ───────────────────────────────────────────────────────────────
drawText("Drag FITS Blaster to the Applications folder to install",
         y: 18,
         font: .systemFont(ofSize: 11),
         color: NSColor(white: 0.3, alpha: 1))

// ── Save ──────────────────────────────────────────────────────────────────────
image.unlockFocus()
guard
    let tiff = image.tiffRepresentation,
    let rep  = NSBitmapImageRep(data: tiff),
    let png  = rep.representation(using: .png, properties: [:])
else { fatalError("PNG conversion failed") }

let url = URL(fileURLWithPath: out)
try! png.write(to: url)
print("Written: \(out)  (\(Int(W))×\(Int(H)))")
