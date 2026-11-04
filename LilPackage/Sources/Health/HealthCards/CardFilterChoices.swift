/// What a series' filter offers (`CardSpec.Filter`): the apps and device models a type's data came
/// from, the most readings first. The Mac reads them from its database, the iPhone from HealthKit
/// (851-3213).
public struct CardFilterChoices: Equatable, Sendable {
  /// An app, by the bundle ID a filter names it by.
  public struct App: Equatable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
      self.id = id
      self.name = name
    }
  }

  public var apps: [App]
  /// Device models, each once.
  public var deviceModels: [String]

  public init(apps: [App] = [], deviceModels: [String] = []) {
    self.apps = apps
    self.deviceModels = deviceModels
  }
}
