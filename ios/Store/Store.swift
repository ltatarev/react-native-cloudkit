import Foundation
import SQLite3

/// Which database a row belongs to.
enum Scope: String, Sendable {
  case `private`, shared
}

/// One record's place in the store. `owner` is `""` in the private scope, so
/// a primary key never holds `NULL`.
struct RecordKey: Hashable, Sendable {
  var scope: Scope
  var owner: String
  var zone: String
  var name: String

  var zoneKey: ZoneKey { ZoneKey(scope: scope, owner: owner, zone: zone) }
}

struct ZoneKey: Hashable, Sendable {
  var scope: Scope
  var owner: String
  var zone: String
}

enum OutboxOp: String, Sendable {
  case save, delete
}

struct OutboxRow: Sendable {
  var key: RecordKey
  var recordType: String
  var fields: Fields
  var times: FieldTimes
  var op: OutboxOp
}

/// What the store last knew of a record on the server: its encoded system
/// fields (which keep the change tag) and its field values and times.
struct KnownRecord: Sendable {
  var recordType: String
  var systemFields: Data?
  var fields: Fields
  var times: FieldTimes
}

struct InboxRow: Sendable {
  var id: Int64
  var kind: String
  var payloadJson: String
}

/// The package's own SQLite file, one per container, over the system
/// `sqlite3`. All access is on this actor.
///
/// `CKSyncEngine` asks for record contents at send time, often when JS is not
/// running, so the outbox, the system fields and the record type config live
/// here and not in JS (contract D4). Inbound changes wait in the inbox until
/// JS acks them (D5).
actor Store {
  private var db: OpaquePointer?
  let url: URL

  static func url(for containerId: String) throws -> URL {
    let base = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let directory = base.appendingPathComponent("react-native-cloudkit", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let safe = containerId.replacingOccurrences(of: "/", with: "_")
    return directory.appendingPathComponent("\(safe).sqlite")
  }

  init(url: URL) throws {
    self.url = url
    var handle: OpaquePointer?
    let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else {
      sqlite3_close(handle)
      throw RNCKError(.unknown, "Could not open the CloudKit store.")
    }
    db = handle
    try Store.migrate(handle)
  }

  deinit {
    sqlite3_close(db)
  }

  /// Closes the file and deletes it with its WAL files. An account sign-out
  /// or switch does this, so no data of one Apple ID reaches another.
  func destroy() {
    sqlite3_close(db)
    db = nil
    for suffix in ["", "-wal", "-shm"] {
      try? FileManager.default.removeItem(atPath: url.path + suffix)
    }
  }

  // MARK: schema

  private static let schema = [
    """
    CREATE TABLE IF NOT EXISTS outbox (
      scope TEXT NOT NULL, zone_owner TEXT NOT NULL, zone TEXT NOT NULL,
      record_name TEXT NOT NULL, record_type TEXT NOT NULL,
      fields_json TEXT NOT NULL, ft_json TEXT NOT NULL, op TEXT NOT NULL,
      queued_at INTEGER NOT NULL,
      PRIMARY KEY (scope, zone_owner, zone, record_name))
    """,
    """
    CREATE TABLE IF NOT EXISTS inbox (
      id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL,
      payload_json TEXT NOT NULL, created_at INTEGER NOT NULL)
    """,
    """
    CREATE TABLE IF NOT EXISTS system_fields (
      scope TEXT NOT NULL, zone_owner TEXT NOT NULL, zone TEXT NOT NULL,
      record_name TEXT NOT NULL, record_type TEXT NOT NULL, data BLOB,
      fields_json TEXT NOT NULL, ft_json TEXT NOT NULL,
      PRIMARY KEY (scope, zone_owner, zone, record_name))
    """,
    "CREATE TABLE IF NOT EXISTS engine_state (scope TEXT PRIMARY KEY, data BLOB NOT NULL)",
    "CREATE TABLE IF NOT EXISTS record_types (name TEXT PRIMARY KEY, config_json TEXT NOT NULL)",
    """
    CREATE TABLE IF NOT EXISTS zones (
      scope TEXT NOT NULL, zone_owner TEXT NOT NULL, zone TEXT NOT NULL,
      do_not_sync INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (scope, zone_owner, zone))
    """,
    "CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
  ]

  private static func migrate(_ db: OpaquePointer?) throws {
    try execute(db, "PRAGMA journal_mode = WAL")
    var version: Int32 = 0
    var statement: OpaquePointer?
    if sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK,
      sqlite3_step(statement) == SQLITE_ROW
    {
      version = sqlite3_column_int(statement, 0)
    }
    sqlite3_finalize(statement)
    if version < 1 {
      for sql in schema { try execute(db, sql) }
      try execute(db, "PRAGMA user_version = 1")
    }
  }

  private static func execute(_ db: OpaquePointer?, _ sql: String) throws {
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
      throw RNCKError(.unknown, "Store error: \(String(cString: sqlite3_errmsg(db)))")
    }
  }

  // MARK: statements

  private enum Value {
    case text(String)
    case int(Int64)
    case blob(Data?)
  }

  private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  @discardableResult
  private func run(_ sql: String, _ values: [Value] = []) throws -> [[Any?]] {
    guard let db else { throw RNCKError(.notConfigured, "The CloudKit store is closed.") }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      throw RNCKError(.unknown, "Store error: \(String(cString: sqlite3_errmsg(db)))")
    }
    defer { sqlite3_finalize(statement) }
    for (index, value) in values.enumerated() {
      let position = Int32(index + 1)
      switch value {
      case .text(let text): sqlite3_bind_text(statement, position, text, -1, Store.transient)
      case .int(let int): sqlite3_bind_int64(statement, position, int)
      case .blob(let data):
        if let data {
          _ = data.withUnsafeBytes {
            sqlite3_bind_blob(statement, position, $0.baseAddress, Int32(data.count), Store.transient)
          }
        } else {
          sqlite3_bind_null(statement, position)
        }
      }
    }
    var rows: [[Any?]] = []
    while true {
      let step = sqlite3_step(statement)
      if step == SQLITE_DONE { break }
      guard step == SQLITE_ROW else {
        throw RNCKError(.unknown, "Store error: \(String(cString: sqlite3_errmsg(db)))")
      }
      var row: [Any?] = []
      for column in 0..<sqlite3_column_count(statement) {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_INTEGER: row.append(sqlite3_column_int64(statement, column))
        case SQLITE_TEXT: row.append(String(cString: sqlite3_column_text(statement, column)))
        case SQLITE_BLOB:
          let count = Int(sqlite3_column_bytes(statement, column))
          if let bytes = sqlite3_column_blob(statement, column) {
            row.append(Data(bytes: bytes, count: count))
          } else {
            row.append(Data())
          }
        default: row.append(nil)
        }
      }
      rows.append(row)
    }
    return rows
  }

  private func transaction(_ body: () throws -> Void) throws {
    try run("BEGIN IMMEDIATE")
    do {
      try body()
      try run("COMMIT")
    } catch {
      try? run("ROLLBACK")
      throw error
    }
  }

  private func keyValues(_ key: RecordKey) -> [Value] {
    [.text(key.scope.rawValue), .text(key.owner), .text(key.zone), .text(key.name)]
  }

  private static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

  // MARK: record types

  func setRecordTypes(_ types: RecordTypes) throws {
    try transaction {
      try run("DELETE FROM record_types")
      for (name, config) in types {
        try run("INSERT INTO record_types (name, config_json) VALUES (?, ?)", [.text(name), .text(JSONCoding.encode(config))])
      }
    }
  }

  func recordTypes() throws -> RecordTypes {
    var types = RecordTypes()
    for row in try run("SELECT name, config_json FROM record_types") {
      guard let name = row[0] as? String, let json = row[1] as? String,
        let config = try? JSONCoding.decode(RecordTypeConfig.self, from: json)
      else { continue }
      types[name] = config
    }
    return types
  }

  // MARK: engine state

  func engineState(_ scope: Scope) throws -> Data? {
    try run("SELECT data FROM engine_state WHERE scope = ?", [.text(scope.rawValue)]).first?[0] as? Data
  }

  func setEngineState(_ scope: Scope, _ data: Data) throws {
    try run(
      "INSERT INTO engine_state (scope, data) VALUES (?, ?) ON CONFLICT(scope) DO UPDATE SET data = excluded.data",
      [.text(scope.rawValue), .blob(data)])
  }

  // MARK: outbox

  /// A newer save of the same record replaces the older row.
  func enqueue(_ row: OutboxRow) throws {
    try run(
      """
      INSERT INTO outbox (scope, zone_owner, zone, record_name, record_type, fields_json, ft_json, op, queued_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(scope, zone_owner, zone, record_name) DO UPDATE SET
        record_type = excluded.record_type, fields_json = excluded.fields_json,
        ft_json = excluded.ft_json, op = excluded.op, queued_at = excluded.queued_at
      """,
      keyValues(row.key) + [
        .text(row.recordType), .text(JSONCoding.encode(row.fields)), .text(JSONCoding.encode(row.times)),
        .text(row.op.rawValue), .int(Store.now()),
      ])
  }

  private func toOutboxRow(_ row: [Any?]) -> OutboxRow? {
    guard let scope = (row[0] as? String).flatMap(Scope.init(rawValue:)),
      let owner = row[1] as? String, let zone = row[2] as? String, let name = row[3] as? String,
      let type = row[4] as? String, let fieldsJson = row[5] as? String, let ftJson = row[6] as? String,
      let op = (row[7] as? String).flatMap(OutboxOp.init(rawValue:))
    else { return nil }
    return OutboxRow(
      key: RecordKey(scope: scope, owner: owner, zone: zone, name: name), recordType: type,
      fields: (try? JSONCoding.decode(Fields.self, from: fieldsJson)) ?? [:],
      times: (try? JSONCoding.decode(FieldTimes.self, from: ftJson)) ?? [:], op: op)
  }

  private static let outboxColumns =
    "scope, zone_owner, zone, record_name, record_type, fields_json, ft_json, op"

  func outbox(_ key: RecordKey) throws -> OutboxRow? {
    try run(
      "SELECT \(Store.outboxColumns) FROM outbox WHERE scope = ? AND zone_owner = ? AND zone = ? AND record_name = ?",
      keyValues(key)
    ).first.flatMap(toOutboxRow)
  }

  func allOutbox() throws -> [OutboxRow] {
    try run("SELECT \(Store.outboxColumns) FROM outbox ORDER BY queued_at").compactMap(toOutboxRow)
  }

  func clearOutbox(_ key: RecordKey) throws {
    try run(
      "DELETE FROM outbox WHERE scope = ? AND zone_owner = ? AND zone = ? AND record_name = ?", keyValues(key))
  }

  // MARK: known records

  func known(_ key: RecordKey) throws -> KnownRecord? {
    guard
      let row = try run(
        """
        SELECT record_type, data, fields_json, ft_json FROM system_fields
        WHERE scope = ? AND zone_owner = ? AND zone = ? AND record_name = ?
        """, keyValues(key)
      ).first,
      let type = row[0] as? String
    else { return nil }
    return KnownRecord(
      recordType: type, systemFields: row[1] as? Data,
      fields: (row[2] as? String).flatMap { try? JSONCoding.decode(Fields.self, from: $0) } ?? [:],
      times: (row[3] as? String).flatMap { try? JSONCoding.decode(FieldTimes.self, from: $0) } ?? [:])
  }

  func setKnown(_ key: RecordKey, _ record: KnownRecord) throws {
    try run(
      """
      INSERT INTO system_fields (scope, zone_owner, zone, record_name, record_type, data, fields_json, ft_json)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(scope, zone_owner, zone, record_name) DO UPDATE SET
        record_type = excluded.record_type, data = excluded.data,
        fields_json = excluded.fields_json, ft_json = excluded.ft_json
      """,
      keyValues(key) + [
        .text(record.recordType), .blob(record.systemFields), .text(JSONCoding.encode(record.fields)),
        .text(JSONCoding.encode(record.times)),
      ])
  }

  func clearKnown(_ key: RecordKey) throws {
    try run(
      "DELETE FROM system_fields WHERE scope = ? AND zone_owner = ? AND zone = ? AND record_name = ?",
      keyValues(key))
  }

  // MARK: inbox

  func appendInbox(kind: String, payloadJson: String) throws {
    try run(
      "INSERT INTO inbox (kind, payload_json, created_at) VALUES (?, ?, ?)",
      [.text(kind), .text(payloadJson), .int(Store.now())])
  }

  func drainInbox(limit: Int) throws -> [InboxRow] {
    try run("SELECT id, kind, payload_json FROM inbox ORDER BY id LIMIT ?", [.int(Int64(limit))]).compactMap {
      guard let id = $0[0] as? Int64, let kind = $0[1] as? String, let payload = $0[2] as? String else { return nil }
      return InboxRow(id: id, kind: kind, payloadJson: payload)
    }
  }

  func ackInbox(_ ids: [Int64]) throws {
    try transaction {
      for id in ids { try run("DELETE FROM inbox WHERE id = ?", [.int(id)]) }
    }
  }

  // MARK: zones

  func upsertZone(_ zone: ZoneKey, doNotSync: Bool) throws {
    try run(
      """
      INSERT INTO zones (scope, zone_owner, zone, do_not_sync) VALUES (?, ?, ?, ?)
      ON CONFLICT(scope, zone_owner, zone) DO UPDATE SET do_not_sync = excluded.do_not_sync
      """,
      [.text(zone.scope.rawValue), .text(zone.owner), .text(zone.zone), .int(doNotSync ? 1 : 0)])
  }

  func zoneExists(_ zone: ZoneKey) throws -> Bool {
    try !run(
      "SELECT 1 FROM zones WHERE scope = ? AND zone_owner = ? AND zone = ?",
      [.text(zone.scope.rawValue), .text(zone.owner), .text(zone.zone)]
    ).isEmpty
  }

  func isDoNotSync(_ zone: ZoneKey) throws -> Bool {
    let rows = try run(
      "SELECT do_not_sync FROM zones WHERE scope = ? AND zone_owner = ? AND zone = ?",
      [.text(zone.scope.rawValue), .text(zone.owner), .text(zone.zone)])
    return (rows.first?[0] as? Int64) == 1
  }

  func zones(_ scope: Scope) throws -> [ZoneKey] {
    try run(
      "SELECT zone_owner, zone FROM zones WHERE scope = ? AND do_not_sync = 0 ORDER BY zone",
      [.text(scope.rawValue)]
    ).compactMap {
      guard let owner = $0[0] as? String, let zone = $0[1] as? String else { return nil }
      return ZoneKey(scope: scope, owner: owner, zone: zone)
    }
  }

  /// Deletes every row of one zone: outbox, system fields, and the zone row.
  func clearZone(_ zone: ZoneKey, keepZoneRow: Bool = false) throws {
    let values: [Value] = [.text(zone.scope.rawValue), .text(zone.owner), .text(zone.zone)]
    try transaction {
      try run("DELETE FROM outbox WHERE scope = ? AND zone_owner = ? AND zone = ?", values)
      try run("DELETE FROM system_fields WHERE scope = ? AND zone_owner = ? AND zone = ?", values)
      if !keepZoneRow {
        try run("DELETE FROM zones WHERE scope = ? AND zone_owner = ? AND zone = ?", values)
      }
    }
  }

  /// Every record of one zone the store has sent or fetched, for a
  /// re-upload after an encryption reset.
  func knownKeys(in zone: ZoneKey) throws -> [RecordKey] {
    try run(
      "SELECT record_name FROM system_fields WHERE scope = ? AND zone_owner = ? AND zone = ?",
      [.text(zone.scope.rawValue), .text(zone.owner), .text(zone.zone)]
    ).compactMap { ($0[0] as? String).map { RecordKey(scope: zone.scope, owner: zone.owner, zone: zone.zone, name: $0) } }
  }

  // MARK: meta

  func meta(_ key: String) throws -> String? {
    try run("SELECT value FROM meta WHERE key = ?", [.text(key)]).first?[0] as? String
  }

  func setMeta(_ key: String, _ value: String) throws {
    try run(
      "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
      [.text(key), .text(value)])
  }
}
