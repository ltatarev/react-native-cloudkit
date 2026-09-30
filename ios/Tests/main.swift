import CloudKit
import Foundation

// Pure Swift tests for `ios/Core`. Run with `yarn test:swift`. The files are
// compiled for macOS with the system toolchain, so no simulator is needed.

var failures = 0
var passes = 0

func check(_ condition: @autoclosure () -> Bool, _ name: String, line: Int = #line) {
  if condition() {
    passes += 1
  } else {
    failures += 1
    print("✗ \(name) (line \(line))")
  }
}

// MARK: ConflictPolicy

do {
  let server: Fields = ["title": .string("Old"), "body": .string("B from server")]
  let serverTimes: FieldTimes = ["title": 100, "body": 300]
  let client: Fields = ["title": .string("A from client"), "body": .string("Old body")]
  let clientTimes: FieldTimes = ["title": 200, "body": 100]

  let merged = ConflictPolicy.resolve(
    server: server, serverTimes: serverTimes, client: client, clientTimes: clientTimes, policy: .fieldMerge)
  check(merged.fields["title"] == .string("A from client"), "fieldMerge keeps the newer title")
  check(merged.fields["body"] == .string("B from server"), "fieldMerge keeps the newer body")
  check(merged.times == ["title": 200, "body": 300], "fieldMerge keeps the newer times")
  check(merged.winner == .merged, "fieldMerge with both sides is merged")

  let tie = ConflictPolicy.resolve(
    server: ["t": .string("s")], serverTimes: ["t": 5], client: ["t": .string("c")], clientTimes: ["t": 5],
    policy: .fieldMerge)
  check(tie.fields["t"] == .string("s") && tie.winner == .server, "a tie goes to the server")

  let clientOnly = ConflictPolicy.resolve(
    server: ["t": .string("s")], serverTimes: ["t": 1], client: ["t": .string("c")], clientTimes: ["t": 9],
    policy: .fieldMerge)
  check(clientOnly.winner == .client, "all client fields newer is client")

  let serverWins = ConflictPolicy.resolve(
    server: server, serverTimes: serverTimes, client: client, clientTimes: clientTimes, policy: .serverWins)
  check(serverWins.fields == server && serverWins.winner == .server, "serverWins takes the server")

  let clientWins = ConflictPolicy.resolve(
    server: server, serverTimes: serverTimes, client: client, clientTimes: clientTimes, policy: .clientWins)
  check(clientWins.fields == client && clientWins.winner == .client, "clientWins takes the client")
}

// MARK: stamp

do {
  let known: Fields = ["title": .string("a"), "body": .string("b")]
  let times = ConflictPolicy.stamp(
    fields: ["title": .string("a"), "body": .string("changed")], known: known,
    knownTimes: ["title": 10, "body": 10], now: 99)
  check(times == ["title": 10, "body": 99], "stamp only moves the changed field")

  let fresh = ConflictPolicy.stamp(fields: ["title": .string("a")], known: [:], knownTimes: [:], now: 5)
  check(fresh == ["title": 5], "stamp times a field it never saw")
}

// MARK: ErrorMap

do {
  check(ErrorMap.waiting(for: CKError(.networkUnavailable))?.reason == .offline, "network → offline")
  check(ErrorMap.waiting(for: CKError(.quotaExceeded))?.reason == .quotaExceeded, "quota → quotaExceeded")
  check(ErrorMap.waiting(for: CKError(.notAuthenticated))?.reason == .noAccount, "auth → noAccount")
  let limited = CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 30.0])
  check(ErrorMap.waiting(for: limited) == Waiting(reason: .throttled, retryAfter: 30), "rate limit → throttled 30")
  check(ErrorMap.waiting(for: CKError(.zoneBusy))?.reason == .throttled, "zone busy → throttled")
  check(ErrorMap.waiting(for: CKError(.participantMayNeedVerification))?.reason == .other, "verification → other")
  check(ErrorMap.waiting(for: CKError(.serverRecordChanged)) == nil, "a conflict does not stop sync")
  check(ErrorMap.waiting(for: CKError(.permissionFailure)) == nil, "a permission failure does not stop sync")
}

// MARK: Validation

do {
  func throwsCode(_ code: RNCKError.Code, _ run: () throws -> Void) -> Bool {
    do { try run(); return false } catch let error as RNCKError { return error.code == code } catch { return false }
  }
  check(throwsCode(.invalidName) { try Validation.checkName("zone", "_x") }, "leading underscore")
  check(throwsCode(.invalidName) { try Validation.checkName("zone", "") }, "empty name")
  check(throwsCode(.invalidName) { try Validation.checkName("zone", String(repeating: "a", count: 256)) }, "long name")
  check(throwsCode(.invalidName) { try Validation.checkName("zone", "naïve") }, "non-ASCII name")
  check(!throwsCode(.invalidName) { try Validation.checkName("record", "take-_abc-movie-1") }, "user id after a prefix")

  let note = RecordTypeConfig(fields: ["title": .string, "rank": .int], conflict: nil)
  check(throwsCode(.invalidField) { try Validation.checkRecordTypes(["Note": RecordTypeConfig(fields: ["RNCK_x": .string])]) }, "reserved prefix")
  check(throwsCode(.invalidField) { try Validation.checkRecordTypes(["Note": RecordTypeConfig(fields: ["1x": .string])]) }, "digit first")
  check(!throwsCode(.invalidField) { try Validation.checkRecordTypes(["Note": note]) }, "a good config")
  check(throwsCode(.invalidField) { try Validation.checkFields(["rank": .number(1.5)], recordType: "Note", config: note) }, "int refuses a fraction")
  check(throwsCode(.invalidField) { try Validation.checkFields(["other": .string("x")], recordType: "Note", config: note) }, "undeclared field")
  check(note.policy == .fieldMerge, "fieldMerge is the default")
}

// MARK: FieldCodec

do {
  let config = RecordTypeConfig(
    fields: ["title": .string, "rank": .int, "score": .double, "done": .bool, "due": .date, "tags": .stringList])
  let record = CKRecord(recordType: "Note")
  let fields: Fields = [
    "title": .string("t"), "rank": .number(3), "score": .number(1.5), "done": .bool(true),
    "due": .number(1_700_000_000_000), "tags": .array([.string("a"), .string("b")]),
  ]
  FieldCodec.apply(fields, times: ["title": 1], to: record, config: config)
  check((record["rank"] as? NSNumber)?.int64Value == 3, "int is stored as Int64")
  check(record["due"] is Date, "date is stored as Date")
  let (read, times) = FieldCodec.read(record, config: config)
  check(read == fields, "fields read back unchanged")
  check(times == ["title": 1], "times read back unchanged")

  FieldCodec.apply(["title": .null], times: [:], to: record, config: config)
  check(record["title"] == nil, "null removes a field")
}

print("\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
