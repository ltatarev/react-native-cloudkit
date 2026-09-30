import CloudKit
import Foundation

/// `CKRecord` ↔ store rows. System fields are archived with
/// `encodeSystemFields(with:)`, so a rebuilt record keeps its change tag.
enum RecordCodec {
  static func zoneID(for key: ZoneKey) -> CKRecordZone.ID {
    CKRecordZone.ID(
      zoneName: key.zone, ownerName: key.scope == .private ? CKCurrentUserDefaultName : key.owner)
  }

  static func recordID(for key: RecordKey) -> CKRecord.ID {
    CKRecord.ID(recordName: key.name, zoneID: zoneID(for: key.zoneKey))
  }

  static func zoneKey(for zoneID: CKRecordZone.ID, scope: Scope) -> ZoneKey {
    ZoneKey(scope: scope, owner: scope == .private ? "" : zoneID.ownerName, zone: zoneID.zoneName)
  }

  static func key(for recordID: CKRecord.ID, scope: Scope) -> RecordKey {
    let zone = zoneKey(for: recordID.zoneID, scope: scope)
    return RecordKey(scope: scope, owner: zone.owner, zone: zone.zone, name: recordID.recordName)
  }

  static func archive(_ record: CKRecord) -> Data {
    let coder = NSKeyedArchiver(requiringSecureCoding: true)
    record.encodeSystemFields(with: coder)
    coder.finishEncoding()
    return coder.encodedData
  }

  static func unarchive(_ data: Data) -> CKRecord? {
    guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
    coder.requiresSecureCoding = true
    defer { coder.finishDecoding() }
    return CKRecord(coder: coder)
  }

  /// The record to send: the stored system fields when there are any, a new
  /// record otherwise, with the outbox fields and times on it.
  static func build(_ row: OutboxRow, systemFields: Data?, config: RecordTypeConfig) -> CKRecord {
    let record =
      systemFields.flatMap(unarchive)
      ?? CKRecord(recordType: row.recordType, recordID: recordID(for: row.key))
    FieldCodec.apply(row.fields, times: row.times, to: record, config: config)
    return record
  }

  /// The zone as a JSON object for inbox and event payloads.
  static func zoneJSON(_ zone: ZoneKey) -> JSONValue {
    var object: [String: JSONValue] = ["scope": .string(zone.scope.rawValue), "name": .string(zone.zone)]
    if zone.scope == .shared { object["owner"] = .string(zone.owner) }
    return .object(object)
  }

  static func millis(_ date: Date?) -> JSONValue {
    .number(((date ?? Date()).timeIntervalSince1970 * 1000).rounded())
  }

  /// The `upsert` inbox payload. `userId` maps the owner placeholder
  /// (`__defaultOwner__`) to the real user id, so `createdBy` is the same on
  /// every device.
  static func upsertPayload(
    key: RecordKey, recordType: String, fields: Fields, record: CKRecord?, userId: String?
  ) -> String {
    func user(_ id: CKRecord.ID?) -> JSONValue {
      guard let name = id?.recordName else { return .null }
      if name == CKCurrentUserDefaultName { return userId.map(JSONValue.string) ?? .null }
      return .string(name)
    }
    let payload: [String: JSONValue] = [
      "zone": zoneJSON(key.zoneKey),
      "recordName": .string(key.name),
      "recordType": .string(recordType),
      "fields": .object(fields),
      "createdBy": user(record?.creatorUserRecordID),
      "modifiedBy": user(record?.lastModifiedUserRecordID),
      "createdAt": millis(record?.creationDate),
      "modifiedAt": millis(record?.modificationDate),
    ]
    return JSONCoding.encode(payload)
  }

  static func refPayload(_ key: RecordKey, extra: [String: JSONValue] = [:]) -> String {
    var payload: [String: JSONValue] = ["zone": zoneJSON(key.zoneKey), "recordName": .string(key.name)]
    payload.merge(extra) { _, new in new }
    return JSONCoding.encode(payload)
  }
}
