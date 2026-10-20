public import Foundation
public import SQLiteData

extension HealthDatabase {
  /// Vision prescriptions, newest issued first, at most `limit`.
  public static func visionPrescriptions(limit: Int, _ db: Database) throws
    -> [HealthVisionPrescription]
  {
    try HealthVisionPrescription
      .order { ($0.startDate.desc(), $0.id.desc()) }
      .limit(limit)
      .fetchAll(db)
  }

  /// The prescription with this ID, or `nil` once it's no longer shared.
  public static func visionPrescription(id: String, _ db: Database) throws
    -> HealthVisionPrescription?
  {
    try HealthVisionPrescription.find(id).fetchOne(db)
  }
}

/// What a vision prescription is for (`HKVisionPrescriptionType`).
public enum VisionPrescriptionKind: Int, Sendable {
  case glasses = 1
  case contacts = 2

  public var name: String { self == .glasses ? "Glasses" : "Contacts" }
}

/// One eye's lens, as the server documents it (`HealthVisionPrescription.rightEye`): diopters,
/// degrees and millimeters. Glasses have a prism, vertex distance and pupillary distances;
/// contacts a base curve and diameter. Any value may be missing.
public struct VisionLens: Equatable, Sendable, Decodable {
  public var sphere: Double?
  public var cylinder: Double?
  public var axis: Double?
  public var addPower: Double?
  public var vertexDistance: Double?
  public var farPupillaryDistance: Double?
  public var nearPupillaryDistance: Double?
  public var prism: VisionPrism?
  public var baseCurve: Double?
  public var diameter: Double?

  public init(
    sphere: Double? = nil, cylinder: Double? = nil, axis: Double? = nil, addPower: Double? = nil,
    vertexDistance: Double? = nil, farPupillaryDistance: Double? = nil,
    nearPupillaryDistance: Double? = nil, prism: VisionPrism? = nil, baseCurve: Double? = nil,
    diameter: Double? = nil
  ) {
    self.sphere = sphere
    self.cylinder = cylinder
    self.axis = axis
    self.addPower = addPower
    self.vertexDistance = vertexDistance
    self.farPupillaryDistance = farPupillaryDistance
    self.nearPupillaryDistance = nearPupillaryDistance
    self.prism = prism
    self.baseCurve = baseCurve
    self.diameter = diameter
  }

  private enum CodingKeys: String, CodingKey {
    case sphere, cylinder, axis, addPower, vertexDistance, farPupillaryDistance,
      nearPupillaryDistance, prism, baseCurve, diameter
  }

  /// Each value on its own: one that can't be read is missing, rather than the whole lens.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    func value<T: Decodable>(_ key: CodingKeys) -> T? {
      try? container.decodeIfPresent(T.self, forKey: key)
    }
    self.init(
      sphere: value(.sphere), cylinder: value(.cylinder), axis: value(.axis),
      addPower: value(.addPower), vertexDistance: value(.vertexDistance),
      farPupillaryDistance: value(.farPupillaryDistance),
      nearPupillaryDistance: value(.nearPupillaryDistance), prism: value(.prism),
      baseCurve: value(.baseCurve), diameter: value(.diameter))
  }
}

/// A glasses lens's prism (`HKVisionPrism`): an amount in prism diopters at an angle in degrees,
/// and the same as vertical and horizontal amounts, each toward a base.
public struct VisionPrism: Equatable, Sendable, Decodable {
  public var amount: Double?
  public var angle: Double?
  public var verticalAmount: Double?
  public var verticalBase: PrismBase?
  public var horizontalAmount: Double?
  public var horizontalBase: PrismBase?

  public init(
    amount: Double? = nil, angle: Double? = nil, verticalAmount: Double? = nil,
    verticalBase: PrismBase? = nil, horizontalAmount: Double? = nil,
    horizontalBase: PrismBase? = nil
  ) {
    self.amount = amount
    self.angle = angle
    self.verticalAmount = verticalAmount
    self.verticalBase = verticalBase
    self.horizontalAmount = horizontalAmount
    self.horizontalBase = horizontalBase
  }

  private enum CodingKeys: String, CodingKey {
    case amount, angle, verticalAmount, verticalBase, horizontalAmount, horizontalBase
  }

  /// Each value on its own, like a lens's. No base (0), or one from a newer iOS, is missing.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    func value<T: Decodable>(_ key: CodingKeys) -> T? {
      try? container.decodeIfPresent(T.self, forKey: key)
    }
    func base(_ key: CodingKeys) -> PrismBase? {
      (value(key) as Int?).flatMap(PrismBase.init(rawValue:))
    }
    self.init(
      amount: value(.amount), angle: value(.angle), verticalAmount: value(.verticalAmount),
      verticalBase: base(.verticalBase), horizontalAmount: value(.horizontalAmount),
      horizontalBase: base(.horizontalBase))
  }
}

/// Which way a prism's base points (`HKPrismBase`, by raw value): up or down vertically, in
/// toward the nose or out away from it horizontally. HealthKit's `none` (0) isn't a direction, so
/// it decodes as no base.
public enum PrismBase: Int, Sendable {
  case up = 1
  case down = 2
  case inward = 3
  case outward = 4

  public var name: String {
    switch self {
    case .up: "Up"
    case .down: "Down"
    case .inward: "In"
    case .outward: "Out"
    }
  }
}

extension HealthVisionPrescription {
  /// Glasses or contacts, or `nil` for a kind from a newer iOS.
  public var kind: VisionPrescriptionKind? { VisionPrescriptionKind(rawValue: prescriptionType) }

  /// "Glasses" or "Contacts", or "Vision Prescription" for a kind from a newer iOS.
  public var kindName: String { kind?.name ?? "Vision Prescription" }

  /// When it was issued.
  public var issued: Date { Date(unixMilliseconds: startDate) }

  /// When it expires, if it says.
  public var expires: Date? { expirationDate.map(Date.init(unixMilliseconds:)) }

  /// Whether it had expired by `now`: it's good through its expiration day in `calendar`.
  public func isExpired(at now: Date, calendar: Calendar) -> Bool {
    guard let expires else { return false }
    let end =
      calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: expires)) ?? expires
    return now >= end
  }

  /// The right eye's lens (OD), or `nil` if it has none or it can't be read.
  public var decodedRightEye: VisionLens? { Self.lens(rightEye) }

  /// The left eye's lens (OS), or `nil` if it has none or it can't be read.
  public var decodedLeftEye: VisionLens? { Self.lens(leftEye) }

  private static func lens(_ json: String?) -> VisionLens? {
    guard let json else { return nil }
    return try? JSONDecoder().decode(VisionLens.self, from: Data(json.utf8))
  }
}
