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


#if os(macOS)
  import AppKit
  import SwiftUI
  import Testing

  extension MacSnapshotTests {
    /// When the previous-period chevron's image gets its final size, from a window made without
    /// settling (851-3230 probe).
    @Test func sleepChevronTiming() {
      let count = Int(ProcessInfo.processInfo.environment["LIL_PROBE_COUNT"] ?? "") ?? 10
      let state = sleepCatalog.states.first { $0.name == "Week" }!
      let saved = probeSettle
      probeSettle = 0
      defer { probeSettle = saved }
      for index in 0..<count {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
          let start = Date()
          let view = state.view().frame(width: state.width).frame(
            minHeight: state.minHeight, alignment: .top)
          let window = snapshotWindow(of: view, appearance: appearance, title: state.slug)
          let frameView = window.contentView!.superview!
          let made = Date().timeIntervalSince(start)
          let initial = chevronImage(frameView)
          frameView.layoutSubtreeIfNeeded()
          window.displayIfNeeded()
          CATransaction.flush()
          let flushed = chevronImage(frameView)
          var changes: [String] = []
          var last = flushed
          let polling = Date()
          while Date().timeIntervalSince(polling) < 0.3 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.001))
            let now = chevronImage(frameView)
            if now != last {
              changes.append(
                "\(now) at \(Int(Date().timeIntervalSince(polling) * 1000)) ms")
              last = now
            }
          }
          print(
            "PROBE timing \(index) \(appearance == .aqua ? "light" : "dark") made in \(Int(made * 1000)) ms: initial \(initial), after flush \(flushed), then \(changes)"
          )
          window.close()
        }
      }
    }
  }

  /// The previous-period chevron's image layer: its contents' size, or what's missing.
  @MainActor
  private func chevronImage(_ frameView: NSView) -> String {
    let root = frameView.layer!
    var found: [String] = []
    func walk(_ layer: CALayer) {
      let frame = layer.convert(layer.bounds, to: root)
      if "\(type(of: layer))" == "ImageLayer", frame.minY >= root.bounds.height - 52,
        abs(frame.minX - 627) < 3
      {
        if let c = layer.contents, CFGetTypeID(c as CFTypeRef) == CGImage.typeID {
          let image = c as! CGImage
          found.append("\(image.width)x\(image.height) in \(frame.width)x\(frame.height)")
        } else {
          found.append("no image in \(frame.width)x\(frame.height)")
        }
      }
      for sub in layer.sublayers ?? [] { walk(sub) }
    }
    walk(root)
    return found.isEmpty ? "none" : found.joined(separator: ", ")
  }
#endif

#if os(macOS)
  import ObjectiveC
  import QuartzCore

  /// Logs who sets a 13x23 image as a layer's contents (the stale chevron, 851-3230 probe), and
  /// what's set on those layers afterwards.
  @MainActor
  func installContentsProbe() {
    guard ProcessInfo.processInfo.environment["LIL_PROBE_DUMP"] != nil, !contentsProbeInstalled
    else { return }
    contentsProbeInstalled = true
    let selector = #selector(setter: CALayer.contents)
    let method = class_getInstanceMethod(CALayer.self, selector)!
    let original = method_getImplementation(method)
    typealias Setter = @convention(c) (CALayer, Selector, Any?) -> Void
    let block: @convention(block) (CALayer, Any?) -> Void = { layer, value in
      var size = "nil"
      if let value, CFGetTypeID(value as CFTypeRef) == CGImage.typeID {
        let image = value as! CGImage
        size = "\(image.width)x\(image.height)"
      }
      let id = ObjectIdentifier(layer)
      let watched = probeWatchedLayers.contains(id)
      if probeKey.hasPrefix("sleep."), size == "13x23" || watched {
        probeWatchedLayers.insert(id)
        if probeLogCount < 2000 {
          probeLogCount += 1
          let stack =
            probeKey.hasPrefix("sleep.week-light") || probeKey.hasPrefix("sleep.last-night-weeks-ago-dark")
            ? Thread.callStackSymbols.prefix(90).joined(separator: "\n    ") : ""
          probeLog(
            "SET \(probeKey) \(size) on \(type(of: layer)) \(Unmanaged.passUnretained(layer).toOpaque()) bounds \(layer.bounds) thread main=\(Thread.isMainThread)\n    \(stack)"
          )
        }
      }
      unsafeBitCast(original, to: Setter.self)(layer, selector, value)
    }
    method_setImplementation(method, imp_implementationWithBlock(block))
  }

  nonisolated(unsafe) private var contentsProbeInstalled = false
  nonisolated(unsafe) private var probeWatchedLayers: Set<ObjectIdentifier> = []
  nonisolated(unsafe) private var probeLogCount = 0

#endif
