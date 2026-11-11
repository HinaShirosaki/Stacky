// mov2gif <in.mov> <out.gif|out.png> <fps> <width> [start] [end]   (.png output = contact sheet of the frames)
import AVFoundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
let a = CommandLine.arguments
let asset = AVURLAsset(url: URL(fileURLWithPath: a[1]))
let fps = Double(a[3])!, width = Int(a[4])!
let sem = DispatchSemaphore(value: 0)
var duration = 0.0
Task { duration = try await asset.load(.duration).seconds; sem.signal() }
sem.wait()
let start = a.count > 5 ? Double(a[5])! : 0, end = a.count > 6 ? Double(a[6])! : duration
let gen = AVAssetImageGenerator(asset: asset)
gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
gen.maximumSize = CGSize(width: width, height: width * 2)
var frames: [CGImage] = []
var t = start
while t < end {
    if let img = try? gen.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil) { frames.append(img) }
    t += 1 / fps
}
print("duration \(duration)s, \(frames.count) frames \(frames[0].width)x\(frames[0].height)")
let out = URL(fileURLWithPath: a[2])
if out.pathExtension == "png" {
    let cols = 4, rows = (frames.count + cols - 1) / cols, w = frames[0].width, h = frames[0].height
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w * cols, pixelsHigh: h * rows, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    for (i, f) in frames.enumerated() { NSGraphicsContext.current!.cgContext.draw(f, in: CGRect(x: (i % cols) * w, y: (rows - 1 - i / cols) * h, width: w, height: h)) }
    try! rep.representation(using: .png, properties: [:])!.write(to: out)
} else {
    let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, frames.count, nil)!
    CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    for (i, f) in frames.enumerated() {
        let hold = i == frames.count - 1 ? 2.0 : 1 / fps // linger on the last frame before looping
        CGImageDestinationAddImage(dest, f, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: hold]] as CFDictionary)
    }
    print(CGImageDestinationFinalize(dest) ? "wrote \(out.path)" : "failed")
}
