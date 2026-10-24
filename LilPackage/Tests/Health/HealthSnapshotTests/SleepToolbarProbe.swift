#if os(macOS)
  // TEMPORARY probe for 851-3230: renders Sleep's states many times, and logs each render's
  // toolbar pixels (a hash) with the toolbar's image layers, to find what differs.
  import AppKit
  import CryptoKit
  import SnapshotTesting
  import SwiftUI
  import Testing

  extension MacSnapshotTests {
    @Test func sleepToolbarProbe() {
      let environment = ProcessInfo.processInfo.environment
      let count = Int(environment["LIL_PROBE_COUNT"] ?? "") ?? 30
      let states = sleepCatalog.selectedStates
      var seen: [String: [String: Int]] = [:]
      for index in 0..<count {
        for state in states {
          for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let suffix = appearance == .darkAqua ? "dark" : "light"
            let key = "\(state.slug)-\(suffix)"
            let view = state.view().frame(width: state.width).frame(
              minHeight: state.minHeight, alignment: .top)
            let window = snapshotWindow(of: view, appearance: appearance, title: state.slug)
            let frameView = window.contentView!.superview!
            var image: NSImage!
            Snapshotting<NSView, NSImage>.layerImage.snapshot(frameView).run { image = $0 }
            let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
            let crop = cg.cropping(to: CGRect(x: 0, y: 0, width: cg.width, height: 104))!
            let data = NSBitmapImageRep(cgImage: crop).representation(
              using: .png, properties: [:])!
            let hash = String(
              SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(10))
            seen[key, default: [:]][hash, default: 0] += 1
            var layers: [String] = []
            collectToolbarLayers(frameView.layer!, root: frameView.layer!, into: &layers)
            print(
              "PROBE \(index) \(key) \(hash) screen \(window.screen?.backingScaleFactor ?? -1) \(layers.joined(separator: " | "))"
            )
            if seen[key]![hash] == 1, let dir = environment["LIL_PROBE_OUTPUT"] {
              try? FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true)
              try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(key)-\(hash).png"))
            }
            window.close()
          }
        }
      }
      for (key, hashes) in seen.sorted(by: { $0.key < $1.key }) {
        print("PROBE summary \(key) \(hashes.sorted { $0.key < $1.key })")
      }
      let flaky = seen.filter { $0.value.count > 1 }.keys.sorted()
      print("PROBE flaky \(flaky.count): \(flaky)")
    }
  }

  /// The title bar's image and drawing layers: where they are, and their contents' size and scale.
  @MainActor
  private func collectToolbarLayers(_ layer: CALayer, root: CALayer, into result: inout [String]) {
    let frame = layer.convert(layer.bounds, to: root)
    let name = "\(type(of: layer))"
    if frame.minY >= root.bounds.height - 52, name == "ImageLayer" || name == "CGDrawingLayer" {
      var contents = "nil"
      if let c = layer.contents {
        let type = CFCopyTypeIDDescription(CFGetTypeID(c as CFTypeRef)) as String? ?? "?"
        if type == "CGImage" {
          let image = c as! CGImage
          contents = "\(image.width)x\(image.height)"
        } else {
          contents = type
        }
      }
      result.append(
        "\(name) \(frame.origin.x),\(frame.origin.y) \(frame.width)x\(frame.height) \(contents) @\(layer.contentsScale) \(layer.contentsGravity.rawValue)"
      )
    }
    for sub in layer.sublayers ?? [] { collectToolbarLayers(sub, root: root, into: &result) }
  }

#endif
