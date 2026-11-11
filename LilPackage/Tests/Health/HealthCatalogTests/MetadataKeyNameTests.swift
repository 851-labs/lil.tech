import Foundation
import HealthCatalog
import Testing

/// Every metadata key lil health writes down by hand is HealthKit's (851-4168): the keys the
/// code reads (`HealthMetadataKey.Name`), the keys in the conformance datasets the Mac's, the
/// iPhone's and the server's tools all read, and the constants the Health tools' descriptions
/// name. The noise notifications' keys were names HealthKit never writes until 851-4148, and the
/// tests and catalog repeated them, so every test passed.
struct MetadataKeyNameTests {
  /// Each name is a key lil health keeps, under its constant's name, so the allow-list's check
  /// against HealthKit (`HealthCatalogSDKTests`) covers it, and HealthKit's constant of that name
  /// has its value (below, on the Mac).
  @Test
  func namesAreKeptKeysUnderTheirConstantsNames() {
    for name in HealthMetadataKey.Name.allCases {
      guard let key = Self.allowListed(name) else {
        Issue.record("\(name): the allow-list has no HKMetadataKey\(name)")
        continue
      }
      #expect(key.key == name.rawValue, "\(key.constant) is \(key.key), not \(name.rawValue)")
      #expect(key.kept, "\(key.constant) is dropped")
    }
  }

  /// The metadata keys in the conformance datasets, the workouts' events' and activities'
  /// included, are HealthKit's (kept or dropped) or other apps' own, never a made-up `HK` one.
  @Test
  func datasetsUseHealthKitsKeys() throws {
    let tests = URL(filePath: #filePath).deletingLastPathComponent()
      .appending(path: "../../../../Services/api/test/health").standardized
    for dataset in ["tools/conformance/dataset.json", "cards/conformance/dataset.json"] {
      let json = try JSONSerialization.jsonObject(
        with: Data(contentsOf: tests.appending(path: dataset)))
      var keys = Set<String>()
      Self.collectMetadataKeys(json, into: &keys)
      #expect(keys.contains("HKTimeZone"), "\(dataset) has no metadata")
      for key in keys where key.hasPrefix("HK") {
        #expect(
          HealthCatalog.healthKitMetadataKeysByKey[key] != nil,
          "\(dataset): \(key) isn't one of HealthKit's metadata keys")
      }
    }
  }

  /// The constants the Health tools' descriptions name (`fromMetadata` in
  /// `Services/api/src/health/tools/HealthToolkit.ts`) are the SDK's.
  @Test
  func toolDescriptionsNameTheSDKsConstants() throws {
    let tools = try String(
      contentsOf: URL(filePath: #filePath).deletingLastPathComponent()
        .appending(path: "../../../../Services/api/mcp-tools.json").standardized,
      encoding: .utf8)
    let named = Set(tools.matches(of: /HKMetadataKey\w+/).map { String($0.output) })
    #expect(!named.isEmpty)
    let constants = Set(HealthCatalog.healthKitMetadataKeys.map(\.constant))
    #expect(named.subtracting(constants).isEmpty, "Not in the SDK: \(named.subtracting(constants))")
  }

  /// The allow-list's key whose constant is `HKMetadataKey` and `name`'s case name, in any case
  /// (`swolfScore` is `HKMetadataKeySWOLFScore`).
  static func allowListed(_ name: HealthMetadataKey.Name) -> HealthMetadataKey? {
    let constant = "HKMetadataKey\(name)".lowercased()
    return HealthCatalog.healthKitMetadataKeys.first { $0.constant.lowercased() == constant }
  }

  /// Every key of a `metadata` object in `json`, reading into strings that hold JSON (a row's
  /// metadata, events and activities).
  static func collectMetadataKeys(_ json: Any, into keys: inout Set<String>) {
    switch json {
    case let object as [String: Any]:
      for (key, value) in object {
        let value = parsed(value)
        if key == "metadata", let metadata = value as? [String: Any] {
          keys.formUnion(metadata.keys)
        }
        collectMetadataKeys(value, into: &keys)
      }
    case let array as [Any]:
      for element in array { collectMetadataKeys(parsed(element), into: &keys) }
    default:
      break
    }
  }

  /// A string's JSON, if it holds an object or an array, else the value itself.
  static func parsed(_ value: Any) -> Any {
    guard let string = value as? String, string.hasPrefix("{") || string.hasPrefix("["),
      let json = try? JSONSerialization.jsonObject(with: Data(string.utf8))
    else { return value }
    return json
  }
}

#if os(macOS)
  import HealthKit

  extension MetadataKeyNameTests {
    /// Each name's value is that of HealthKit's constant, read by its name.
    @Test
    func namesAreHealthKitsValues() {
      let everywhere = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
      for name in HealthMetadataKey.Name.allCases {
        guard let constant = Self.allowListed(name)?.constant,
          let symbol = dlsym(everywhere, constant)
        else {
          Issue.record("HealthKit has no constant for \(name)")
          continue
        }
        let value = symbol.load(as: Unmanaged<NSString>.self).takeUnretainedValue() as String
        #expect(value == name.rawValue, "\(constant) is \(value), not \(name.rawValue)")
      }
      // Two by the SDK's own symbols, which drop the prefix for one and keep it for the other.
      #expect(HealthMetadataKey.Name.indoorWorkout.rawValue == HKMetadataKeyIndoorWorkout)
      #expect(HealthMetadataKey.Name.audioExposureLevel.rawValue == HKMetadataKeyAudioExposureLevel)
    }
  }
#endif
