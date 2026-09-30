import Foundation

/// A refused call. The message starts with `[RNCK:<code>]`, which the TS
/// layer reads back into `CloudKitError.code`.
struct RNCKError: LocalizedError, Sendable {
  enum Code: String, Sendable {
    case notConfigured, invalidName, invalidField, unknownRecordType
    case recordTooLarge, zoneNotSyncing, notOwner, shareNotFound
    case inviteNotFound, cloudKit, unknown
  }

  let code: Code
  let detail: String

  init(_ code: Code, _ detail: String) {
    self.code = code
    self.detail = detail
  }

  var errorDescription: String? { "[RNCK:\(code.rawValue)] \(detail)" }

  static func wrap(_ error: Error) -> RNCKError {
    if let error = error as? RNCKError { return error }
    let nsError = error as NSError
    return RNCKError(.cloudKit, "\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)")
  }
}
