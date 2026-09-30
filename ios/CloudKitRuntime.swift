import CloudKit
import Foundation
import UIKit
import os

/// Everything that outlives one JS runtime: the container, the store, both
/// engines, the listeners and the held invites. One per process, because a
/// push or a share link can arrive before JS runs.
final class CloudKitRuntime: @unchecked Sendable {
  static let shared = CloudKitRuntime()

  let events = EventHub()
  let status: SyncStatusTracker
  let log = Logger(subsystem: "react-native-cloudkit", category: "runtime")

  private let lock = NSLock()
  private var _container: CKContainer?
  private var _store: Store?
  private var _private: SyncEngineHost?
  private var _shared: SyncEngineHost?
  private var userId: String?
  private var leaving: Set<ZoneKey> = []
  private var waiters: [CheckedContinuation<Void, Never>] = []

  private init() {
    status = SyncStatusTracker(events: events)
    status.onOnline = { [weak self] in
      Task { try? await self?.syncNow() }
    }
  }

  // MARK: state

  private func locked<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }

  var isConfigured: Bool { locked { _store != nil } }

  /// Only read after `configure`. The engine hosts use it.
  var store: Store { locked { _store! } }

  func container() throws -> CKContainer {
    guard let container = locked({ _container }) else {
      throw RNCKError(.notConfigured, "Call configure() first.")
    }
    return container
  }

  private func openStore() throws -> Store {
    guard let store = locked({ _store }) else {
      throw RNCKError(.notConfigured, "Call configure() first.")
    }
    return store
  }

  func host(_ scope: Scope) throws -> SyncEngineHost {
    guard let host = locked({ scope == .private ? _private : _shared }) else {
      throw RNCKError(.notConfigured, "Call configure() first.")
    }
    return host
  }

  func cachedUserId() async -> String? {
    if let id = locked({ userId }) { return id }
    guard let container = locked({ _container }), let id = try? await container.userRecordID().recordName else {
      return nil
    }
    locked { userId = id }
    return id
  }

  /// Waits until `configure` has run, or `seconds` pass. The account calls
  /// use it, because a screen can ask before `configure` finishes.
  private func awaitConfigured(seconds: Double = 10) async {
    if isConfigured { return }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      lock.lock()
      if _store != nil {
        lock.unlock()
        continuation.resume()
        return
      }
      waiters.append(continuation)
      lock.unlock()
      DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [weak self] in
        self?.releaseWaiters()
      }
    }
  }

  private func releaseWaiters() {
    let pending = locked { () -> [CheckedContinuation<Void, Never>] in
      let all = waiters
      waiters = []
      return all
    }
    pending.forEach { $0.resume() }
  }

  func markLeaving(_ zone: ZoneKey) { _ = locked { leaving.insert(zone) } }

  func consumeLeaving(_ zone: ZoneKey) -> Bool { locked { leaving.remove(zone) != nil } }

  // MARK: configure

  /// Opens the store, writes the record type config, restores the engine
  /// state and starts both engines. A second call with the same container
  /// only updates the config.
  func configure(containerId: String, recordTypesJson: String) async throws {
    let types = try JSONCoding.decode(RecordTypes.self, from: recordTypesJson)
    try Validation.checkRecordTypes(types)

    if let existing = locked({ _container }), existing.containerIdentifier == containerId, isConfigured {
      try await store.setRecordTypes(types)
      return
    }

    let container = CKContainer(identifier: containerId)
    let store = try Store(url: Store.url(for: containerId))
    try await store.setRecordTypes(types)
    if let last = try await store.meta("lastSyncedAt").flatMap(Double.init) {
      status.restore(lastSyncedAt: last)
    }
    locked {
      _container = container
      _store = store
    }
    try await startEngines()
    releaseWaiters()

    await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
    if await accountStatus() == "noAccount" {
      status.wait(Waiting(reason: .noAccount))
    }
    status.publish()
    log.info("Configured \(containerId, privacy: .public)")
    ShareAcceptance.shared.runtimeDidConfigure()
  }

  private func startEngines() async throws {
    let container = try container()
    let store = try openStore()
    let privateState = try await store.engineState(.private)
    let sharedState = try await store.engineState(.shared)
    let privateHost = SyncEngineHost(
      scope: .private, runtime: self, database: container.privateCloudDatabase, state: privateState)
    let sharedHost = SyncEngineHost(
      scope: .shared, runtime: self, database: container.sharedCloudDatabase, state: sharedState)
    locked {
      _private = privateHost
      _shared = sharedHost
    }
  }

  func persistLastSynced() async {
    guard let last = status.lastSynced, let store = locked({ _store }) else { return }
    try? await store.setMeta("lastSyncedAt", String(last))
  }

  // MARK: account

  func accountStatus() async -> String {
    await awaitConfigured()
    guard let container = locked({ _container }) else { return "couldNotDetermine" }
    do {
      switch try await container.accountStatus() {
      case .available: return "available"
      case .noAccount: return "noAccount"
      case .restricted: return "restricted"
      case .temporarilyUnavailable: return "temporarilyUnavailable"
      case .couldNotDetermine: return "couldNotDetermine"
      @unknown default: return "couldNotDetermine"
      }
    } catch {
      /* Airplane mode: the state still resolves. */
      return "temporarilyUnavailable"
    }
  }

  func currentUserId() async -> String? {
    await awaitConfigured()
    guard let container = locked({ _container }) else { return nil }
    guard let id = try? await container.userRecordID().recordName else { return nil }
    locked { userId = id }
    return id
  }

  /// Edits made while signed out stay in the outbox and go to the account.
  func accountSignedIn(userId: String) async {
    locked { self.userId = userId }
    if let store = locked({ _store }), let rows = try? await store.allOutbox() {
      for scope in [Scope.private, .shared] {
        let keys = rows.filter { $0.key.scope == scope }
        try? host(scope).queueSave(keys.filter { $0.op == .save }.map(\.key))
        try? host(scope).queueDelete(keys.filter { $0.op == .delete }.map(\.key))
      }
    }
    status.clearWaiting()
    events.emit("accountChanged", JSONCoding.encode(["kind": JSONValue.string("signIn"), "userId": .string(userId)]))
  }

  func accountSignedOut() async {
    await resetStore()
    status.wait(Waiting(reason: .noAccount))
    events.emit("accountChanged", JSONCoding.encode(["kind": JSONValue.string("signOut")]))
  }

  func accountSwitched(userId: String) async {
    await resetStore()
    locked { self.userId = userId }
    events.emit(
      "accountChanged", JSONCoding.encode(["kind": JSONValue.string("switchAccounts"), "userId": .string(userId)]))
  }

  /// Deletes the whole store, outbox included, and starts again empty. The
  /// data of one Apple ID never reaches another.
  private func resetStore() async {
    guard let old = locked({ _store }), let container = locked({ _container }) else { return }
    let types = (try? await old.recordTypes()) ?? [:]
    await old.destroy()
    locked { userId = nil }
    do {
      let fresh = try Store(url: Store.url(for: container.containerIdentifier ?? "default"))
      try await fresh.setRecordTypes(types)
      locked { _store = fresh }
      try await startEngines()
    } catch {
      log.error("Could not reopen the store after an account change")
    }
  }

  // MARK: zones

  func ensureZone(_ name: String) async throws {
    try Validation.checkName("zone", name)
    let zone = ZoneKey(scope: .private, owner: "", zone: name)
    try await openStore().upsertZone(zone, doNotSync: false)
    try host(.private).queueZoneSave(zone)
  }

  func deleteZone(_ zone: ZoneKey) async throws {
    let store = try openStore()
    if zone.scope == .shared { markLeaving(zone) }
    try await store.clearZone(zone)
    try host(zone.scope).queueZoneDelete(zone)
  }

  func listZones(_ scope: Scope) async throws -> [(ZoneKey, Bool)] {
    let store = try openStore()
    let zones = try await store.zones(scope)
    guard scope == .private else { return zones.map { ($0, true) } }
    let container = try container()
    var result: [(ZoneKey, Bool)] = []
    for zone in zones {
      let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: RecordCodec.zoneID(for: zone))
      let shared = (try? await container.privateCloudDatabase.record(for: shareID)) != nil
      result.append((zone, shared))
    }
    return result
  }

  // MARK: writing

  struct SaveInput {
    var zone: ZoneKey
    var recordName: String
    var recordType: String
    var fieldsJson: String
  }

  /// Validates, writes the outbox and returns. The engine sends later.
  func save(_ inputs: [SaveInput]) async throws {
    let store = try openStore()
    let types = try await store.recordTypes()
    let now = Int64(Date().timeIntervalSince1970 * 1000)
    var rows: [OutboxRow] = []

    for input in inputs {
      try Validation.checkName("zone", input.zone.zone)
      try Validation.checkName("record", input.recordName)
      guard let config = types[input.recordType] else {
        throw RNCKError(.unknownRecordType, "Record type \"\(input.recordType)\" is not in the config.")
      }
      guard input.fieldsJson.utf8.count <= Validation.maxRecordBytes else {
        throw RNCKError(.recordTooLarge, "Record \(input.recordName) is over 1 MB.")
      }
      let fields = try JSONCoding.decode(Fields.self, from: input.fieldsJson)
      try Validation.checkFields(fields, recordType: input.recordType, config: config)
      if try await store.isDoNotSync(input.zone) {
        throw RNCKError(.zoneNotSyncing, "Zone \(input.zone.zone) was purged. Call ensureZone() first.")
      }
      let key = RecordKey(scope: input.zone.scope, owner: input.zone.owner, zone: input.zone.zone, name: input.recordName)
      let known = try await store.known(key)
      let base = try await store.outbox(key)
      let knownFields = base?.fields ?? known?.fields ?? [:]
      let knownTimes = base?.times ?? known?.times ?? [:]
      let times =
        config.policy == .fieldMerge
        ? ConflictPolicy.stamp(fields: fields, known: knownFields, knownTimes: knownTimes, now: now)
        : Dictionary(uniqueKeysWithValues: fields.keys.map { ($0, now) })
      rows.append(OutboxRow(key: key, recordType: input.recordType, fields: knownFields.merging(fields) { _, new in new }, times: times, op: .save))
    }

    for row in rows {
      if row.key.scope == .private, try await !store.zoneExists(row.key.zoneKey) {
        try await store.upsertZone(row.key.zoneKey, doNotSync: false)
        try host(.private).queueZoneSave(row.key.zoneKey)
      }
      try await store.enqueue(row)
    }
    for scope in [Scope.private, .shared] {
      let keys = rows.filter { $0.key.scope == scope }.map(\.key)
      if !keys.isEmpty { try host(scope).queueSave(keys) }
    }
  }

  func delete(_ refs: [RecordKey]) async throws {
    let store = try openStore()
    for key in refs {
      try Validation.checkName("record", key.name)
      let knownType = try await store.known(key)?.recordType
      let queuedType = try await store.outbox(key)?.recordType
      let type = knownType ?? queuedType ?? ""
      try await store.enqueue(OutboxRow(key: key, recordType: type, fields: [:], times: [:], op: .delete))
    }
    for scope in [Scope.private, .shared] {
      let keys = refs.filter { $0.scope == scope }
      if !keys.isEmpty { try host(scope).queueDelete(keys) }
    }
  }

  func syncNow() async throws {
    for scope in [Scope.private, .shared] {
      let engine = try host(scope).engine!
      do {
        try await engine.sendChanges()
        try await engine.fetchChanges()
      } catch {
        if let waiting = ErrorMap.waiting(for: error) { status.wait(waiting) }
      }
    }
    await persistLastSynced()
  }

  // MARK: inbox

  func drain(limit: Int) async throws -> [InboxRow] {
    try await openStore().drainInbox(limit: limit)
  }

  func ack(_ ids: [String]) async throws {
    try await openStore().ackInbox(ids.compactMap(Int64.init))
  }
}
