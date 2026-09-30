import Foundation

enum FieldType: String, Codable, Sendable {
  case string, int, double, bool, date, stringList
}

enum ConflictPolicyKind: String, Codable, Sendable {
  case serverWins, clientWins, fieldMerge
}

/// One record type as `configure` declares it. The native store keeps a copy,
/// so a push-triggered send or merge never needs JS.
struct RecordTypeConfig: Codable, Equatable, Sendable {
  var fields: [String: FieldType]
  var conflict: ConflictPolicyKind?

  var policy: ConflictPolicyKind { conflict ?? .fieldMerge }
}

typealias RecordTypes = [String: RecordTypeConfig]
