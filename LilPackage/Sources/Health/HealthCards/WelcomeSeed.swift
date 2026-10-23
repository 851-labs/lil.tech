/// One of the cards every account starts with.
public struct SeedCard: Hashable, Sendable {
  /// The card's fixed ID, the same in every account, so seeding is idempotent.
  public let id: String
  /// The seed it started as, the `health_card` row's `seed`.
  public let seed: String
  public let position: String
  public let spec: CardSpec
}

extension HealthCards {
  /// Summary's six metrics, as cards (docs/decisions/cards.md, The welcome seed): canonical, one
  /// series each with the type's default aggregation, bucket `auto`, range W, and the symbol,
  /// color and chart style its type's category and catalog give it. The server seeds each store
  /// with these once, from `Services/api/card-seed.json`, which `scripts/generate-health-cards`
  /// writes from this.
  public static let welcomeSeed: [SeedCard] = [
    ("steps", "Steps", "StepCount"),
    ("heart_rate", "Heart Rate", "HeartRate"),
    ("active_energy", "Active Energy", "ActiveEnergyBurned"),
    ("walking_running_distance", "Walking + Running Distance", "DistanceWalkingRunning"),
    ("resting_heart_rate", "Resting Heart Rate", "RestingHeartRate"),
    ("weight", "Weight", "BodyMass"),
  ]
  .enumerated()
  .map { index, card in
    let (seed, name, type) = card
    // Canonicalized from the least an agent would write, so the seed gets the same defaults.
    let spec = try! CardSpec(
      input: [
        "version": 1,
        "display": ["name": .string(name)],
        "series": [["type": .string("HKQuantityTypeIdentifier\(type)")]],
      ])
    return SeedCard(id: "card_seed_\(seed)", seed: seed, position: "a\(index)", spec: spec)
  }
}
