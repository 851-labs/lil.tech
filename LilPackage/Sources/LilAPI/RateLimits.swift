import LilAPIGenerated

extension Components.Schemas.TooManyRequests {
  /// How long a 429 asks clients to wait, in seconds: its body's `retryAfterSeconds`, or a
  /// minute if the body can't be read.
  public static func retryAfterSeconds(of body: () throws -> Self) -> Int {
    (try? body().retryAfterSeconds) ?? 60
  }
}

let  badlyFormatted = 1
