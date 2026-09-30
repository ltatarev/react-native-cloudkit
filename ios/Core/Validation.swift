import Foundation

enum Validation {
  /// Every field the package writes starts with this.
  static let reservedPrefix = "RNCK_"
  static let fieldTimesKey = "RNCK_fieldTimes"

  /// CloudKit's limit for one record. Checked before a save is queued.
  static let maxRecordBytes = 1_000_000

  /// ASCII, 1–255 characters, no leading `_`.
  static func checkName(_ kind: String, _ name: String) throws {
    let ascii = name.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value <= 0x7e }
    guard !name.isEmpty, name.count <= 255, ascii, !name.hasPrefix("_") else {
      throw RNCKError(.invalidName, "Invalid \(kind) name \"\(name)\": use 1–255 ASCII characters, not starting with \"_\".")
    }
  }

  static func isFieldName(_ name: String) -> Bool {
    guard let first = name.unicodeScalars.first, CharacterSet.letters.contains(first), first.isASCII else {
      return false
    }
    return name.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_") }
  }

  static func checkRecordTypes(_ types: RecordTypes) throws {
    for (recordType, config) in types {
      guard isFieldName(recordType) else {
        throw RNCKError(.invalidField, "Invalid record type \"\(recordType)\".")
      }
      for field in config.fields.keys where !isFieldName(field) || field.hasPrefix(reservedPrefix) {
        throw RNCKError(.invalidField, "Invalid field \"\(recordType).\(field)\": start with a letter, and do not use the \"\(reservedPrefix)\" prefix.")
      }
    }
  }

  /// Checks each value against the declared type. An undeclared field is
  /// refused, so a typo never becomes a permanent production field.
  static func checkFields(_ fields: Fields, recordType: String, config: RecordTypeConfig) throws {
    for (name, value) in fields {
      guard let type = config.fields[name] else {
        throw RNCKError(.invalidField, "Field \"\(recordType).\(name)\" is not in the record type config.")
      }
      guard FieldCodec.accepts(value, as: type) else {
        throw RNCKError(.invalidField, "Field \"\(recordType).\(name)\" is not a \(type.rawValue).")
      }
    }
  }
}
