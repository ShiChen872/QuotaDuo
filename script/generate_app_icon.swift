#!/usr/bin/env swift
import AppKit
import Foundation

/// Hand-crafted QuotaDuo icon — interlocking twin rings (mint + amber).
/// Code-drawn geometry, not an AI image.

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

guard let ctx = NSGraphicsContext.current?.cgContext else {
    fputs("no graphics context\n", stderr)
    exit(1)
}
ctx.setShouldAntialias(true)
ctx.setAllowsAntialiasing(true)

let bounds = CGRect(x: 0, y: 0, width: size, height: size)
let corner = size * 0.2237
let bgPath = CGPath(roundedRect: bounds, cornerWidth: corner, cornerHeight: corner, transform: nil)
ctx.addPath(bgPath)
ctx.clip()

// Background
let bgColors = [
    NSColor(calibratedRed: 0.05, green: 0.055, blue: 0.07, alpha: 1).cgColor,
    NSColor(calibratedRed: 0.09, green: 0.11, blue: 0.14, alpha: 1).cgColor,
] as CFArray
if let gradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: bgColors,
    locations: [0, 1]
) {
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: size * 0.15, y: size * 0.9),
        end: CGPoint(x: size * 0.85, y: size * 0.1),
        options: []
    )
}

func strokeArc(
    center: CGPoint,
    radius: CGFloat,
    lineWidth: CGFloat,
    startDeg: CGFloat,
    sweepDeg: CGFloat,
    color: NSColor
) {
    // UIKit/AppKit: 0° = right, CCW positive. We use "clock" degrees from 12 o'clock.
    let start = (startDeg - 90) * .pi / 180
    let end = (startDeg + sweepDeg - 90) * .pi / 180
    let path = CGMutablePath()
    path.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
    ctx.setStrokeColor(color.cgColor)
    ctx.setLineWidth(lineWidth)
    ctx.setLineCap(.round)
    ctx.addPath(path)
    ctx.strokePath()
}

func fillDot(at center: CGPoint, radius: CGFloat, color: NSColor) {
    ctx.setFillColor(color.cgColor)
    ctx.fillEllipse(in: CGRect(
        x: center.x - radius,
        y: center.y - radius,
        width: radius * 2,
        height: radius * 2
    ))
}

func pointOnCircle(center: CGPoint, radius: CGFloat, clockDeg: CGFloat) -> CGPoint {
    let a = (clockDeg - 90) * .pi / 180
    return CGPoint(x: center.x + radius * cos(a), y: center.y + radius * sin(a))
}

let mid = CGPoint(x: size * 0.5, y: size * 0.5)
let left = CGPoint(x: mid.x - size * 0.095, y: mid.y + size * 0.01)
let right = CGPoint(x: mid.x + size * 0.095, y: mid.y - size * 0.01)
let radius = size * 0.255
let stroke = size * 0.086

let track = NSColor(calibratedWhite: 1.0, alpha: 0.10)
let mint = NSColor(calibratedRed: 0.18, green: 0.95, blue: 0.72, alpha: 1)
let amber = NSColor(calibratedRed: 1.0, green: 0.58, blue: 0.14, alpha: 1)

// Dim closed tracks
strokeArc(center: left, radius: radius, lineWidth: stroke * 0.88, startDeg: 0, sweepDeg: 360, color: track)
strokeArc(center: right, radius: radius, lineWidth: stroke * 0.88, startDeg: 0, sweepDeg: 360, color: track)

// Crisp accent arcs (interlocking openings face opposite ways)
strokeArc(center: left, radius: radius, lineWidth: stroke, startDeg: 40, sweepDeg: 250, color: mint)
strokeArc(center: right, radius: radius, lineWidth: stroke, startDeg: 220, sweepDeg: 250, color: amber)

// Endpoint dots
fillDot(at: pointOnCircle(center: left, radius: radius, clockDeg: 40), radius: stroke * 0.42, color: mint)
fillDot(at: pointOnCircle(center: left, radius: radius, clockDeg: 290), radius: stroke * 0.42, color: mint)
fillDot(at: pointOnCircle(center: right, radius: radius, clockDeg: 220), radius: stroke * 0.42, color: amber)
fillDot(at: pointOnCircle(center: right, radius: radius, clockDeg: 110), radius: stroke * 0.42, color: amber)

// Duo hub
fillDot(at: CGPoint(x: mid.x - size * 0.03, y: mid.y), radius: size * 0.022, color: mint)
fillDot(at: CGPoint(x: mid.x + size * 0.03, y: mid.y), radius: size * 0.022, color: amber)

// Subtle top sheen
ctx.saveGState()
let sheenRect = CGRect(x: size * 0.08, y: size * 0.62, width: size * 0.55, height: size * 0.32)
ctx.addEllipse(in: sheenRect)
ctx.clip()
ctx.setFillColor(NSColor.white.withAlphaComponent(0.05).cgColor)
ctx.fill(bounds)
ctx.restoreGState()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fputs("png encode failed\n", stderr)
    exit(1)
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon-1024.png"
try png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
