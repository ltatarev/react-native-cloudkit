import CloudKit
import Foundation

/// Record fields between JSON and `CKRecord`, typed by the record type config.
/// A date crosses as epoch milliseconds.
enum FieldCodec {
  static func accepts(_ value: JSONValue, as type: FieldType) -> Bool {
    switch (type, value) {
    case (_, .null): return true
    case (.string, .string): return true
    case (.int, .number(let number)): return number.rounded() == number
    case (.double, .number), (.date, .number): return true
    case (.bool, .bool): return true
    case (.stringList, .array(let items)):
      return items.allSatisfy { if case .string = $0 { return true } else { return false } }
    default: return false
    }
  }

  static func encode(_ value: JSONValue, as type: FieldType) -> CKRecordValue? {
    switch (type, value) {
    case (.string, .string(let string)): return string as NSString
    case (.int, .number(let number)): return NSNumber(value: Int64(number))
    case (.double, .number(let number)): return NSNumber(value: number)
    case (.bool, .bool(let bool)): return NSNumber(value: bool)
    case (.date, .number(let ms)): return Date(timeIntervalSince1970: ms / 1000) as NSDate
    case (.stringList, .array(let items)):
      return items.compactMap { if case .string(let s) = $0 { return s } else { return nil } } as NSArray
    default: return nil
    }
  }

  static func decode(_ value: Any?, as type: FieldType) -> JSONValue {
    guard let value else { return .null }
    switch type {
    case .string: return (value as? String).map(JSONValue.string) ?? .null
    case .int: return (value as? NSNumber).map { .number(Double($0.int64Value)) } ?? .null
    case .double: return (value as? NSNumber).map { .number($0.doubleValue) } ?? .null
    case .bool: return (value as? NSNumber).map { .bool($0.boolValue) } ?? .null
    case .date:
      return (value as? Date).map { .number(($0.timeIntervalSince1970 * 1000).rounded()) } ?? .null
    case .stringList: return (value as? [String]).map { .array($0.map(JSONValue.string)) } ?? .null
    }
  }

  /// Writes the fields and the reserved time map onto a record. A `null`
  /// removes the field.
  static func apply(_ fields: Fields, times: FieldTimes, to record: CKRecord, config: RecordTypeConfig) {
    for (name, value) in fields {
      guard let type = config.fields[name] else { continue }
      record[name] = encode(value, as: type)
    }
    record[Validation.fieldTimesKey] = JSONCoding.encode(times) as NSString
  }

  /// The declared fields of a fetched record, and its time map.
  static func read(_ record: CKRecord, config: RecordTypeConfig) -> (Fields, FieldTimes) {
    var fields = Fields()
    for (name, type) in config.fields {
      fields[name] = decode(record[name], as: type)
    }
    let times = (record[Validation.fieldTimesKey] as? String)
      .flatMap { try? JSONCoding.decode(FieldTimes.self, from: $0) } ?? [:]
    return (fields, times)
  }
}
