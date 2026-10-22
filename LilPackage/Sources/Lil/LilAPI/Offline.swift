import Foundation
import OpenAPIRuntime

/// Whether `error` means there's no connection, rather than the server failing: a URL error
/// such as no internet or a dropped connection, also as the API client wraps it (in a
/// `ClientError`, twice when the token's refresh failed). Not `.timedOut`: a slow server isn't
/// the device being offline.
public func isOfflineError(_ error: any Error) -> Bool {
  if let error = error as? URLError { return offlineCodes.contains(error.code) }
  if let error = error as? ClientError { return isOfflineError(error.underlyingError) }
  return false
}

private let offlineCodes: Set<URLError.Code> = [
  .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
  .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff,
]
