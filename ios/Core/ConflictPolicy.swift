import Foundation

enum ConflictWinner: String, Sendable {
  case server, client, merged
}

struct ConflictResult: Equatable, Sendable {
  var fields: Fields
  var times: FieldTimes
  var winner: ConflictWinner
}

/// Pure: resolves one record that changed on the server and on this device.
///
/// `fieldMerge` keeps, per field, the value with the newer timestamp. A tie
/// goes to the server, so two devices that merge the same pair agree. A field
/// with no timestamp counts as time 0. Clock skew between devices can make
/// the older edit win; the README says so.
enum ConflictPolicy {
  static func resolve(
    server: Fields, serverTimes: FieldTimes,
    client: Fields, clientTimes: FieldTimes,
    policy: ConflictPolicyKind
  ) -> ConflictResult {
    switch policy {
    case .serverWins:
      return ConflictResult(fields: server, times: serverTimes, winner: .server)
    case .clientWins:
      return ConflictResult(
        fields: server.merging(client) { _, new in new },
        times: serverTimes.merging(clientTimes) { _, new in new },
        winner: .client)
    case .fieldMerge:
      var fields = Fields()
      var times = FieldTimes()
      var tookServer = false
      var tookClient = false
      for name in Set(server.keys).union(client.keys).union(serverTimes.keys).union(clientTimes.keys) {
        let serverTime = serverTimes[name] ?? 0
        let clientTime = clientTimes[name] ?? 0
        let clientHas = client[name] != nil || clientTimes[name] != nil
        if clientHas && clientTime > serverTime {
          if let value = client[name] { fields[name] = value }
          times[name] = clientTime
          if server[name] != client[name] { tookClient = true }
        } else {
          if let value = server[name] { fields[name] = value }
          if serverTimes[name] != nil || server[name] != nil { times[name] = serverTime }
          if clientHas && server[name] != client[name] { tookServer = true }
        }
      }
      let winner: ConflictWinner = tookClient ? (tookServer ? .merged : .client) : .server
      return ConflictResult(fields: fields, times: times, winner: winner)
    }
  }

  /// The times for a local save: a field whose value changed gets `now`, and
  /// an unchanged field keeps the time it had. This is what lets two devices
  /// edit different fields of one record and keep both edits.
  static func stamp(fields: Fields, known: Fields, knownTimes: FieldTimes, now: Int64) -> FieldTimes {
    var times = knownTimes
    for (name, value) in fields where known[name] != value || knownTimes[name] == nil {
      times[name] = now
    }
    return times
  }
}
