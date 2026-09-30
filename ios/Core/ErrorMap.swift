import CloudKit
import Foundation

/// The state the app shows while sync cannot go on.
enum WaitingReason: String, Sendable {
  case offline, quotaExceeded, noAccount, throttled, other
}

struct Waiting: Equatable, Sendable {
  var reason: WaitingReason
  var retryAfter: Double?
}

/// Pure: which `waiting` state a CloudKit error means, or `nil` for an error
/// that is about one record and does not stop sync (a conflict, a missing
/// zone, a permission failure).
enum ErrorMap {
  static func waiting(for error: Error) -> Waiting? {
    guard let ckError = error as? CKError else { return nil }
    switch ckError.code {
    case .networkUnavailable, .networkFailure:
      return Waiting(reason: .offline)
    case .quotaExceeded:
      return Waiting(reason: .quotaExceeded)
    case .notAuthenticated:
      return Waiting(reason: .noAccount)
    case .requestRateLimited, .zoneBusy, .serviceUnavailable:
      return Waiting(reason: .throttled, retryAfter: ckError.retryAfterSeconds)
    case .participantMayNeedVerification, .accountTemporarilyUnavailable, .managedAccountRestricted:
      return Waiting(reason: .other)
    case .partialFailure:
      let inner = ckError.partialErrorsByItemID?.values.compactMap { waiting(for: $0) } ?? []
      return inner.first
    default:
      return nil
    }
  }
}
