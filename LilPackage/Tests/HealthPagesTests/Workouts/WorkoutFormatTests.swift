import AppKit
import CoreLocation
import Foundation
import HealthDatabase
import SwiftUI
import Testing

@testable import HealthPages

struct WorkoutFormatTests {
  @Test
  func timesAndPacesReadLikeHealth() {
    #expect(WorkoutFormat.duration(42 * 60 + 18) == "42:18")
    #expect(WorkoutFormat.duration(3600 + 2 * 60 + 5) == "1:02:05")
    #expect(WorkoutFormat.pace(5 * 60 + 12) == "5'12\"/km")
    #expect(WorkoutActivity.name(37) == "Running")
    #expect(WorkoutActivity.name(9_999) == "Workout")
  }

  // Main actor: resolving a SwiftUI color to an NSColor needs it.
  @Test @MainActor
  func theRouteIsGreenWhereFastAndRedWhereSlow() {
    // Synthetic: fast for the first half, slow for the second.
    let start = Date(timeIntervalSince1970: 1_760_400_000)
    let locations = (0..<200).map { index in
      RouteLocation(
        time: start.addingTimeInterval(Double(index)), latitude: 0, longitude: Double(index) * 1e-4,
        altitude: 0, speed: index < 100 ? 5 : 2)
    }
    let pieces = RouteMap.pieces(locations)
    #expect(pieces.count > 10)
    // Every location is in a piece, and pieces join end to start.
    #expect(pieces.first?.coordinates.first?.longitude == 0)
    #expect(pieces.last?.coordinates.last?.longitude == locations.last?.longitude)
    let hue = { (color: Color) in NSColor(color).usingColorSpace(.deviceRGB)?.hueComponent ?? -1 }
    #expect(hue(pieces.first!.color) > 0.3)
    // Unknown speeds aren't slow.
    let unknown = (0..<50).map { index in
      RouteLocation(
        time: start.addingTimeInterval(Double(index)), latitude: 0, longitude: Double(index) * 1e-4,
        altitude: 0, speed: index.isMultiple(of: 2) ? -1 : 5)
    }
    let known = (0..<50).map { index in
      RouteLocation(
        time: start.addingTimeInterval(Double(index)), latitude: 0, longitude: Double(index) * 1e-4,
        altitude: 0, speed: index < 25 ? 2 : 5)
    }
    let mixed = RouteMap.pieces(known + unknown)
    #expect(hue(mixed.last!.color) > 0.3)
    // Red's hue is 0, or 1 as it wraps around.
    let slow = hue(pieces.last!.color)
    #expect(min(slow, 1 - slow) < 0.05)
  }
}

struct WorkoutHeartRateTests {
  // Main actor: it's the view's.
  @Test @MainActor
  func theChartUsesTheMainSource() {
    let sample = { (source: String, value: Double) in
      HealthSample(
        id: UUID().uuidString, type: "HKQuantityTypeIdentifierHeartRate", startDate: 0,
        endDate: 0, value: value, unit: "count/min", sourceName: source, sourceBundleID: source)
    }
    let samples = [
      sample("watch", 150), sample("strap", 90), sample("watch", 152), sample("watch", 149),
    ]
    #expect(WorkoutDetailView.mainSource(samples).map(\.value) == [150, 152, 149])
  }
}
