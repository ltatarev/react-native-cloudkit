import CloudKit
import Foundation
import os

/// The `CKSyncEngine` delegate for one database. There are two: the private
/// database and the shared database (contract D1). Store rows are keyed by
/// scope, so both run the same code.
///
/// The delegate never calls into JS. It writes to the store and emits events.
final class SyncEngineHost: CKSyncEngineDelegate, @unchecked Sendable {
  let scope: Scope
  private unowned let runtime: CloudKitRuntime
  private(set) var engine: CKSyncEngine!
  private let log = Logger(subsystem: "react-native-cloudkit", category: "sync")

  init(scope: Scope, runtime: CloudKitRuntime, database: CKDatabase, state: Data?) {
    self.scope = scope
    self.runtime = runtime
    let serialization = state.flatMap {
      try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0)
    }
    var configuration = CKSyncEngine.Configuration(
      database: database, stateSerialization: serialization, delegate: self)
    configuration.automaticallySync = true
    engine = CKSyncEngine(configuration)
  }

  private var store: Store { runtime.store }

  // MARK: queueing

  func queueSave(_ keys: [RecordKey]) {
    engine.state.add(pendingRecordZoneChanges: keys.map { .saveRecord(RecordCodec.recordID(for: $0)) })
  }

  func queueDelete(_ keys: [RecordKey]) {
    engine.state.add(pendingRecordZoneChanges: keys.map { .deleteRecord(RecordCodec.recordID(for: $0)) })
  }

  func queueZoneSave(_ zone: ZoneKey) {
    engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: RecordCodec.zoneID(for: zone)))])
  }

  func queueZoneDelete(_ zone: ZoneKey) {
    engine.state.add(pendingDatabaseChanges: [.deleteZone(RecordCodec.zoneID(for: zone))])
  }

  // MARK: delegate

  func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
    do {
      switch event {
      case .stateUpdate(let update):
        let data = try JSONEncoder().encode(update.stateSerialization)
        try await store.setEngineState(scope, data)
      case .accountChange(let change):
        await handleAccountChange(change)
      case .fetchedDatabaseChanges(let changes):
        try await handleFetchedDatabaseChanges(changes)
      case .fetchedRecordZoneChanges(let changes):
        try await handleFetchedRecordZoneChanges(changes)
      case .sentRecordZoneChanges(let sent):
        try await handleSentRecordZoneChanges(sent)
      case .sentDatabaseChanges(let sent):
        for failure in sent.failedZoneSaves {
          report(failure.error)
        }
      case .willFetchChanges, .willSendChanges:
        runtime.status.begin(scope)
      case .didFetchChanges, .didSendChanges:
        runtime.status.end(scope)
        await runtime.persistLastSynced()
      case .willFetchRecordZoneChanges, .didFetchRecordZoneChanges:
        break
      @unknown default:
        break
      }
    } catch {
      log.error("Sync event failed in \(self.scope.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
    }
  }

  func nextRecordZoneChangeBatch(
    _ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine
  ) async -> CKSyncEngine.RecordZoneChangeBatch? {
    let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
    guard !pending.isEmpty else { return nil }
    let store = self.store
    let scope = self.scope
    let types = (try? await store.recordTypes()) ?? [:]
    var missing: [CKSyncEngine.PendingRecordZoneChange] = []
    var records: [CKRecord.ID: CKRecord] = [:]
    for change in pending {
      guard case .saveRecord(let recordID) = change else { continue }
      let key = RecordCodec.key(for: recordID, scope: scope)
      guard let row = try? await store.outbox(key), row.op == .save, let config = types[row.recordType] else {
        missing.append(change)
        continue
      }
      let systemFields = try? await store.known(key)?.systemFields
      records[recordID] = RecordCodec.build(row, systemFields: systemFields, config: config)
    }
    /* A save with no outbox row has nothing to send. */
    if !missing.isEmpty {
      syncEngine.state.remove(pendingRecordZoneChanges: missing)
    }
    let remaining = pending.filter { !missing.contains($0) }
    guard !remaining.isEmpty else { return nil }
    return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: remaining) { records[$0] }
  }

  // MARK: account

  private func handleAccountChange(_ event: CKSyncEngine.Event.AccountChange) async {
    /* Both engines see the change. The private engine speaks for both. */
    guard scope == .private else { return }
    switch event.changeType {
    case .signIn(let current):
      await runtime.accountSignedIn(userId: current.recordName)
    case .signOut:
      await runtime.accountSignedOut()
    case .switchAccounts(_, let current):
      await runtime.accountSwitched(userId: current.recordName)
    @unknown default:
      break
    }
  }

  // MARK: fetched

  private func handleFetchedDatabaseChanges(_ changes: CKSyncEngine.Event.FetchedDatabaseChanges) async throws {
    for modification in changes.modifications {
      let zone = RecordCodec.zoneKey(for: modification.zoneID, scope: scope)
      if try await !store.zoneExists(zone) {
        try await store.upsertZone(zone, doNotSync: false)
      }
    }
    for deletion in changes.deletions {
      let zone = RecordCodec.zoneKey(for: deletion.zoneID, scope: scope)
      if scope == .shared {
        /* A zone gone from the shared database: the owner stopped sharing,
           or removed this participant. A zone this user left on purpose is
           not news. */
        let leaving = runtime.consumeLeaving(zone)
        try await store.clearZone(zone)
        if !leaving { try await appendZoneDeleted(zone, reason: "shareEnded") }
        continue
      }
      switch deletion.reason {
      case .deleted:
        try await store.clearZone(zone)
        try await appendZoneDeleted(zone, reason: "deleted")
      case .purged:
        /* Local data stays, and nothing is uploaded again until `ensureZone`. */
        try await store.clearZone(zone, keepZoneRow: true)
        try await store.upsertZone(zone, doNotSync: true)
        try await appendZoneDeleted(zone, reason: "purged")
      case .encryptedDataReset:
        /* The one "send everything" signal: the zone comes back empty. */
        let keys = try await store.knownKeys(in: zone)
        try await store.clearZone(zone, keepZoneRow: true)
        queueZoneSave(zone)
        log.info("Zone \(zone.zone, privacy: .public) reset (\(keys.count) records to send again)")
        try await appendZoneDeleted(zone, reason: "encryptedDataReset")
      @unknown default:
        try await store.clearZone(zone)
        try await appendZoneDeleted(zone, reason: "deleted")
      }
    }
    if !changes.deletions.isEmpty { runtime.events.emit("inboxChanged") }
  }

  private func appendZoneDeleted(_ zone: ZoneKey, reason: String) async throws {
    try await store.appendInbox(
      kind: "zoneDeleted",
      payloadJson: JSONCoding.encode(["zone": RecordCodec.zoneJSON(zone), "reason": .string(reason)]))
  }

  private func handleFetchedRecordZoneChanges(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges) async throws {
    let types = try await store.recordTypes()
    let userId = await runtime.cachedUserId()
    var wrote = false
    for modification in changes.modifications {
      let record = modification.record
      /* The zone's CKShare, and any type the app did not declare, stay out. */
      guard let config = types[record.recordType] else { continue }
      let key = RecordCodec.key(for: record.recordID, scope: scope)
      var (fields, times) = FieldCodec.read(record, config: config)
      /* A local edit waits for this record: merge it now, by the policy, so
         the app and the next send agree. */
      if let pending = try await store.outbox(key), pending.op == .save {
        let result = ConflictPolicy.resolve(
          server: fields, serverTimes: times, client: pending.fields, clientTimes: pending.times,
          policy: config.policy)
        fields = result.fields
        times = result.times
        if result.winner == .server {
          try await store.clearOutbox(key)
        } else {
          try await store.enqueue(OutboxRow(key: key, recordType: record.recordType, fields: fields, times: times, op: .save))
        }
      }
      try await store.setKnown(
        key,
        KnownRecord(recordType: record.recordType, systemFields: RecordCodec.archive(record), fields: fields, times: times))
      try await store.appendInbox(
        kind: "upsert",
        payloadJson: RecordCodec.upsertPayload(
          key: key, recordType: record.recordType, fields: fields, record: record, userId: userId))
      wrote = true
    }
    for deletion in changes.deletions {
      guard types[deletion.recordType] != nil else { continue }
      let key = RecordCodec.key(for: deletion.recordID, scope: scope)
      try await store.clearKnown(key)
      try await store.clearOutbox(key)
      try await store.appendInbox(
        kind: "delete",
        payloadJson: RecordCodec.refPayload(key, extra: ["recordType": .string(deletion.recordType)]))
      wrote = true
    }
    if wrote { runtime.events.emit("inboxChanged") }
  }

  // MARK: sent

  private func handleSentRecordZoneChanges(_ sent: CKSyncEngine.Event.SentRecordZoneChanges) async throws {
    let types = try await store.recordTypes()
    let userId = await runtime.cachedUserId()
    var wroteInbox = false

    for record in sent.savedRecords {
      let key = RecordCodec.key(for: record.recordID, scope: scope)
      let row = try await store.outbox(key)
      let config = types[record.recordType]
      let (fields, times) = config.map { FieldCodec.read(record, config: $0) } ?? (row?.fields ?? [:], row?.times ?? [:])
      try await store.setKnown(
        key, KnownRecord(recordType: record.recordType, systemFields: RecordCodec.archive(record), fields: fields, times: times))
      /* Clear the row only if no newer save replaced it while this one flew. */
      if let row, row.fields == fields {
        try await store.clearOutbox(key)
      }
    }

    for recordID in sent.deletedRecordIDs {
      let key = RecordCodec.key(for: recordID, scope: scope)
      try await store.clearKnown(key)
      if let row = try await store.outbox(key), row.op == .delete {
        try await store.clearOutbox(key)
      }
    }

    var requeue: [RecordKey] = []
    for failure in sent.failedRecordSaves {
      let record = failure.record
      let key = RecordCodec.key(for: record.recordID, scope: scope)
      switch failure.error.code {
      case .serverRecordChanged:
        guard let server = failure.error.serverRecord, let config = types[record.recordType],
          let row = try await store.outbox(key)
        else { break }
        let (serverFields, serverTimes) = FieldCodec.read(server, config: config)
        let result = ConflictPolicy.resolve(
          server: serverFields, serverTimes: serverTimes, client: row.fields, clientTimes: row.times,
          policy: config.policy)
        try await store.setKnown(
          key,
          KnownRecord(recordType: record.recordType, systemFields: RecordCodec.archive(server), fields: serverFields, times: serverTimes))
        if result.winner == .server {
          try await store.clearOutbox(key)
        } else {
          try await store.enqueue(
            OutboxRow(key: key, recordType: record.recordType, fields: result.fields, times: result.times, op: .save))
          requeue.append(key)
        }
        /* The app holds the client values. Tell it what the record is now. */
        if result.winner != .client {
          try await store.appendInbox(
            kind: "upsert",
            payloadJson: RecordCodec.upsertPayload(
              key: key, recordType: record.recordType, fields: result.fields, record: server, userId: userId))
        }
        try await store.appendInbox(
          kind: "conflictResolved",
          payloadJson: RecordCodec.refPayload(key, extra: ["winner": .string(result.winner.rawValue)]))
        wroteInbox = true
      case .zoneNotFound:
        if scope == .private {
          queueZoneSave(key.zoneKey)
          requeue.append(key)
        } else {
          /* A shared zone that is gone: the share ended. The fetch reports it. */
          try await store.clearOutbox(key)
        }
      case .unknownItem:
        /* The server lost the record. Send it as new. */
        if var known = try await store.known(key) {
          known.systemFields = nil
          try await store.setKnown(key, known)
        }
        requeue.append(key)
      case .permissionFailure:
        /* A read-only participant. The write stays in the outbox, and the
           app hears about this one record. Nothing else stops. */
        try await store.appendInbox(
          kind: "writeFailed", payloadJson: RecordCodec.refPayload(key, extra: ["reason": .string("permission")]))
        wroteInbox = true
      case .batchRequestFailed:
        requeue.append(key)
      default:
        report(failure.error)
        if ErrorMap.waiting(for: failure.error) != nil { requeue.append(key) }
      }
    }

    for (recordID, error) in sent.failedRecordDeletes {
      let key = RecordCodec.key(for: recordID, scope: scope)
      if error.code == .unknownItem || error.code == .zoneNotFound {
        try await store.clearOutbox(key)
        try await store.clearKnown(key)
      } else {
        report(error)
      }
    }

    if !requeue.isEmpty { queueSave(requeue) }
    if wroteInbox { runtime.events.emit("inboxChanged") }
  }

  private func report(_ error: Error) {
    if let waiting = ErrorMap.waiting(for: error) {
      runtime.status.wait(waiting)
    }
    let code = (error as? CKError)?.code.rawValue ?? -1
    log.error("CloudKit error \(code, privacy: .public) in \(self.scope.rawValue, privacy: .public)")
  }
}
