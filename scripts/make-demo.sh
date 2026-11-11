#!/bin/zsh
# Builds docs/walkthrough.gif from real renders of the app's UI, using made-up workspaces (never your own data).
# Usage: scripts/make-demo.sh   (needs build/Stacky.app; run scripts/bundle.sh first)
set -e
cd "${0:A:h}/.."
D=$(mktemp -d)
touch "$D/thesis-draft.rtf" "$D/references.pdf" "$D/budget.numbers" "$D/slides.key"

# One JSON store per frame, then a render of the app reading it.
python3 - "$D" <<'PY'
import json, sys, uuid
d = sys.argv[1]
def win(bundle, title, i=0): return {"id": str(uuid.uuid4()), "fingerprint": {"bundleID": bundle, "title": title, "index": i}}
def doc(name, app): return {"folder": {"_0": f"file://{d}/{name}", "app": app}}
def item(name, windows=(), payloads=(), folded=False):
    return {"id": str(uuid.uuid4()), "name": name, "windows": list(windows), "payloads": list(payloads),
            "state": {"folded": {"by": "minimize"}} if folded else {"released": {}}}
def thesis(folded=False):
    return item("Thesis", [win("com.apple.TextEdit", "thesis-draft.rtf"), win("com.apple.Preview", "references.pdf"), win("com.apple.Safari", "Library search")],
                [doc("thesis-draft.rtf", "com.apple.TextEdit"), doc("references.pdf", "com.apple.Preview")], folded)
website = item("Website", [win("com.apple.dt.Xcode", "Site"), win("com.apple.Terminal", "site — zsh"), win("com.apple.Safari", "localhost")])
trip = item("Trip planning", [win("com.apple.Maps", "Maps"), win("com.apple.Notes", "Packing list"), win("com.apple.iCal", "Calendar")],
            [doc("budget.numbers", "com.apple.iWork.Numbers")])
frames = [[], [item("Thesis")], [thesis()], [thesis(), website, trip], [thesis(True), website, trip], [thesis(), website, trip]]
for n, items in enumerate(frames): json.dump(items, open(f"{d}/store{n}.json", "w"))
PY
for n in 0 1 2 3 4 5; do
  open -n -W --env STACKY_STORE="$D/store$n.json" build/Stacky.app --args --snapshot "$D/frame$n.png"
done

cat > "$D/gif.swift" <<'SWIFT'
import AppKit
import ImageIO
import UniformTypeIdentifiers
let dir = CommandLine.arguments[1], out = CommandLine.arguments[2]
let captions = ["Create a workspace for a task", "Link windows by clicking them, or drop files on the card",
                "Linking a window also links the file it shows", "One workspace per task",
                "Fold: the workspace's windows are minimized together", "Release: they return in the same order, on the desktop you're on"]
let images = captions.indices.map { NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath: "\(dir)/frame\($0).png")))!.cgImage! }
let width = images.map(\.width).max()! + 80, band = 110, height = images.map(\.height).max()! + band + 40
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.gif.identifier as CFString, images.count, nil)!
CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
for (image, caption) in zip(images, captions) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor(white: 0.95, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    // UI centred above the caption band.
    NSGraphicsContext.current!.cgContext.draw(image, in: CGRect(x: (width - image.width) / 2, y: band + (height - band - image.height) / 2, width: image.width, height: image.height))
    let style = NSMutableParagraphStyle(); style.alignment = .center
    NSAttributedString(string: caption, attributes: [.font: NSFont.systemFont(ofSize: 30, weight: .medium), .foregroundColor: NSColor(white: 0.15, alpha: 1), .paragraphStyle: style])
        .draw(in: NSRect(x: 30, y: 16, width: width - 60, height: band - 20))
    CGImageDestinationAddImage(dest, rep.cgImage!, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 2.4]] as CFDictionary)
}
print(CGImageDestinationFinalize(dest) ? "Wrote \(out)" : "GIF failed")
SWIFT
mkdir -p docs
swift "$D/gif.swift" "$D" docs/walkthrough.gif
