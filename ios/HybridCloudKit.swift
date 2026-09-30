import CloudKit
import Foundation
import NitroModules

/// The Nitro hybrid object. A thin shell over `CloudKitRuntime`: it converts
/// bridge types and turns every thrown error into an `RNCKError` message.
class HybridCloudKit: HybridCloudKitSpec {
  private var runtime: CloudKitRuntime { .shared }

  private func promise<T>(_ body: @escaping () async throws -> T) -> Promise<T> {
    Promise.async {
      do {
        return try await body()
      } catch {
        throw RNCKError.wrap(error)
      }
    }
  }

  private func zoneKey(_ zone: BridgeZoneRef) -> ZoneKey {
    zone.scope == .shared
      ? ZoneKey(scope: .shared, owner: zone.owner ?? "", zone: zone.name)
      : ZoneKey(scope: .private, owner: "", zone: zone.name)
  }

  private func bridgeZone(_ zone: ZoneKey) -> BridgeZoneRef {
    BridgeZoneRef(
      scope: zone.scope == .shared ? .shared : .private, name: zone.zone,
      owner: zone.scope == .shared ? zone.owner : nil)
  }

  // MARK: setup

  func isAvailable() throws -> Bool { true }

  func configure(containerId: String, recordTypesJson: String) throws -> Promise<Void> {
    promise { try await self.runtime.configure(containerId: containerId, recordTypesJson: recordTypesJson) }
  }

  func getAccountStatus() throws -> Promise<BridgeAccountStatus> {
    promise { BridgeAccountStatus(fromString: await self.runtime.accountStatus()) ?? .couldnotdetermine }
  }

  func getCurrentUserId() throws -> Promise<String?> {
    promise { await self.runtime.currentUserId() }
  }

  // MARK: zones

  func ensureZone(name: String) throws -> Promise<Void> {
    promise { try await self.runtime.ensureZone(name) }
  }

  func deleteZone(zone: BridgeZoneRef) throws -> Promise<Void> {
    promise { try await self.runtime.deleteZone(self.zoneKey(zone)) }
  }

  func listZones(scope: BridgeZoneScope) throws -> Promise<[BridgeZoneInfo]> {
    promise {
      try await self.runtime.listZones(scope == .shared ? .shared : .private).map {
        BridgeZoneInfo(zone: self.bridgeZone($0.0), isShared: $0.1)
      }
    }
  }

  // MARK: writing

  func saveRecords(records: [BridgeRecordInput]) throws -> Promise<Void> {
    let inputs = records.map {
      CloudKitRuntime.SaveInput(
        zone: zoneKey($0.zone), recordName: $0.recordName, recordType: $0.recordType, fieldsJson: $0.fieldsJson)
    }
    return promise { try await self.runtime.save(inputs) }
  }

  func deleteRecords(refs: [BridgeRecordRef]) throws -> Promise<Void> {
    let keys = refs.map { ref -> RecordKey in
      let zone = zoneKey(ref.zone)
      return RecordKey(scope: zone.scope, owner: zone.owner, zone: zone.zone, name: ref.recordName)
    }
    return promise { try await self.runtime.delete(keys) }
  }

  func syncNow() throws -> Promise<Void> {
    promise { try await self.runtime.syncNow() }
  }

  // MARK: reading

  func drainInbox(limit: Double) throws -> Promise<[BridgeInboxEvent]> {
    promise {
      try await self.runtime.drain(limit: max(1, Int(limit))).map {
        BridgeInboxEvent(id: String($0.id), kind: $0.kind, payloadJson: $0.payloadJson)
      }
    }
  }

  func ackInbox(ids: [String]) throws -> Promise<Void> {
    promise { try await self.runtime.ack(ids) }
  }

  // MARK: sharing

  func presentShareSheet(
    zoneName: String, title: String, thumbnailUri: String?, permission: BridgeSharePermission,
    allowOthersToInvite: Bool
  ) throws -> Promise<BridgeShareSheetResult> {
    promise {
      try Validation.checkName("zone", zoneName)
      let container = try self.runtime.container()
      try await self.runtime.ensureZone(zoneName)
      let shared = try await Sharing.presentShareSheet(
        zone: zoneName, title: title, thumbnailUri: thumbnailUri, permission: permission.stringValue,
        allowOthersToInvite: allowOthersToInvite, container: container)
      return shared ? .shared : .cancelled
    }
  }

  func presentManageSheet(zone: BridgeZoneRef) throws -> Promise<Void> {
    promise {
      let container = try self.runtime.container()
      guard let share = try await Sharing.fetchShare(self.zoneKey(zone), in: container) else {
        throw RNCKError(.shareNotFound, "Zone \(zone.name) is not shared.")
      }
      try await Sharing.presentManageSheet(share: share, container: container)
    }
  }

  func getShare(zone: BridgeZoneRef) throws -> Promise<BridgeShareInfo?> {
    promise {
      let key = self.zoneKey(zone)
      let container = try self.runtime.container()
      return try await Sharing.fetchShare(key, in: container).map { Sharing.info($0, zone: key) }
    }
  }

  func setParticipantPermission(
    zoneName: String, participantId: String, permission: BridgeSharePermission
  ) throws -> Promise<Void> {
    promise {
      try await Sharing.setPermission(
        zone: zoneName, participantId: participantId, readOnly: permission == .readonly,
        in: self.runtime.container())
    }
  }

  func removeParticipant(zoneName: String, participantId: String) throws -> Promise<Void> {
    promise {
      try await Sharing.removeParticipant(zone: zoneName, participantId: participantId, in: self.runtime.container())
    }
  }

  func stopSharing(zoneName: String) throws -> Promise<Void> {
    promise { try await Sharing.stopSharing(zone: zoneName, in: self.runtime.container()) }
  }

  func leaveShare(zone: BridgeZoneRef) throws -> Promise<Void> {
    promise { try await self.runtime.deleteZone(self.zoneKey(zone)) }
  }

  func acceptShareUrl(url: String) throws -> Promise<Void> {
    promise {
      guard let parsed = URL(string: url) else { throw RNCKError(.inviteNotFound, "Not a share URL.") }
      try await ShareAcceptance.shared.receive(url: parsed)
    }
  }

  func acceptInvite(token: String) throws -> Promise<BridgeZoneInfo> {
    promise {
      let zone = try await ShareAcceptance.shared.accept(token: token)
      return BridgeZoneInfo(zone: self.bridgeZone(zone), isShared: true)
    }
  }

  // MARK: events

  func addListener(event: BridgeEventName, listener: @escaping (String) -> Void) throws -> Double {
    let id = runtime.events.add(event.stringValue, listener)
    /* A new status listener hears the current state at once. */
    if event == .syncstatus { listener(runtime.status.payload()) }
    return id
  }

  func removeListener(id: Double) throws {
    runtime.events.remove(id)
  }
}
