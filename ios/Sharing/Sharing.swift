import CloudKit
import Foundation
import UIKit

/// Zone-wide sharing (contract D3, D7): the system collaboration share sheet
/// for the first invite, `UICloudSharingController` for management, and the
/// owner actions for a custom People screen.
enum Sharing {
  static func shareID(for zone: ZoneKey) -> CKRecord.ID {
    CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: RecordCodec.zoneID(for: zone))
  }

  static func database(for scope: Scope, in container: CKContainer) -> CKDatabase {
    scope == .private ? container.privateCloudDatabase : container.sharedCloudDatabase
  }

  static func fetchShare(_ zone: ZoneKey, in container: CKContainer) async throws -> CKShare? {
    do {
      return try await database(for: zone.scope, in: container).record(for: shareID(for: zone)) as? CKShare
    } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
      return nil
    }
  }

  private static func ownedShare(_ name: String, in container: CKContainer) async throws -> CKShare {
    let zone = ZoneKey(scope: .private, owner: "", zone: name)
    guard let share = try await fetchShare(zone, in: container) else {
      throw RNCKError(.shareNotFound, "Zone \(name) is not shared.")
    }
    return share
  }

  private static func save(_ share: CKShare, in container: CKContainer) async throws {
    _ = try await container.privateCloudDatabase.modifyRecords(saving: [share], deleting: [])
  }

  /// The zone's share, made on first use. The zone is saved to the server
  /// first, because a share needs a zone that exists there.
  static func prepareShare(
    zone name: String, title: String, thumbnail: Data?, in container: CKContainer
  ) async throws -> CKShare {
    let zone = ZoneKey(scope: .private, owner: "", zone: name)
    if let existing = try await fetchShare(zone, in: container) {
      return existing
    }
    let zoneID = RecordCodec.zoneID(for: zone)
    _ = try await container.privateCloudDatabase.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
    let share = CKShare(recordZoneID: zoneID)
    share[CKShare.SystemFieldKey.title] = title as NSString
    if let thumbnail { share[CKShare.SystemFieldKey.thumbnailImageData] = thumbnail as NSData }
    share.publicPermission = .none
    let (saved, _) = try await container.privateCloudDatabase.modifyRecords(saving: [share], deleting: [])
    if case .success(let record) = saved[share.recordID], let savedShare = record as? CKShare {
      return savedShare
    }
    return share
  }

  @MainActor
  static func topViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let window = scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.first?.windows.first
    var top = window?.rootViewController
    while let presented = top?.presentedViewController { top = presented }
    return top
  }

  /// The system collaboration share sheet. Resolves `shared` when the owner
  /// sent the invite, `cancelled` otherwise.
  @MainActor
  static func presentShareSheet(
    zone name: String, title: String, thumbnailUri: String?, permission: String, allowOthersToInvite: Bool,
    container: CKContainer
  ) async throws -> Bool {
    guard let presenter = topViewController() else {
      throw RNCKError(.unknown, "No view controller to present the share sheet from.")
    }
    let thumbnail = thumbnailUri.flatMap(URL.init(string:)).flatMap { try? Data(contentsOf: $0) }
    let options = CKAllowedSharingOptions(
      allowedParticipantPermissionOptions: permission == "readOnly" ? .readOnly : .readWrite,
      allowedParticipantAccessOptions: .specifiedRecipientsOnly)
    /* Before iOS 26 the system sheet decides, and members cannot invite. */
    if #available(iOS 26.0, *) {
      options.allowsParticipantsToInviteOthers = allowOthersToInvite
    }
    let provider = NSItemProvider()
    provider.registerCKShare(container: container, allowedSharingOptions: options) {
      try await prepareShare(zone: name, title: title, thumbnail: thumbnail, in: container)
    }
    let configuration = UIActivityItemsConfiguration(itemProviders: [provider])
    configuration.metadataProvider = { key in
      key == .title ? title : nil
    }
    let controller = UIActivityViewController(activityItemsConfiguration: configuration)
    controller.popoverPresentationController?.sourceView = presenter.view
    return await withCheckedContinuation { continuation in
      controller.completionWithItemsHandler = { _, completed, _, _ in
        continuation.resume(returning: completed)
      }
      presenter.present(controller, animated: true)
    }
  }

  @MainActor
  static func presentManageSheet(share: CKShare, container: CKContainer) throws {
    guard let presenter = topViewController() else {
      throw RNCKError(.unknown, "No view controller to present the manage sheet from.")
    }
    let controller = UICloudSharingController(share: share, container: container)
    controller.availablePermissions = [.allowPrivate, .allowReadWrite, .allowReadOnly]
    controller.popoverPresentationController?.sourceView = presenter.view
    presenter.present(controller, animated: true)
  }

  // MARK: owner actions

  static func setPermission(
    zone name: String, participantId: String, readOnly: Bool, in container: CKContainer
  ) async throws {
    let share = try await ownedShare(name, in: container)
    guard share.currentUserParticipant?.role == .owner else {
      throw RNCKError(.notOwner, "Only the owner changes permissions.")
    }
    guard let participant = share.participants.first(where: { $0.participantID == participantId }) else {
      throw RNCKError(.shareNotFound, "No participant \(participantId).")
    }
    participant.permission = readOnly ? .readOnly : .readWrite
    try await save(share, in: container)
  }

  static func removeParticipant(zone name: String, participantId: String, in container: CKContainer) async throws {
    let share = try await ownedShare(name, in: container)
    guard share.currentUserParticipant?.role == .owner else {
      throw RNCKError(.notOwner, "Only the owner removes a participant.")
    }
    guard let participant = share.participants.first(where: { $0.participantID == participantId }) else {
      throw RNCKError(.shareNotFound, "No participant \(participantId).")
    }
    share.removeParticipant(participant)
    try await save(share, in: container)
  }

  /// Deletes the `CKShare`. The zone and its records stay with the owner.
  static func stopSharing(zone name: String, in container: CKContainer) async throws {
    let share = try await ownedShare(name, in: container)
    guard share.currentUserParticipant?.role == .owner else {
      throw RNCKError(.notOwner, "Only the owner stops sharing.")
    }
    _ = try await container.privateCloudDatabase.modifyRecords(saving: [], deleting: [share.recordID])
  }

  // MARK: reading

  static func info(_ share: CKShare, zone: ZoneKey) -> BridgeShareInfo {
    let current = share.currentUserParticipant
    let participants = share.participants.map { participant -> BridgeParticipant in
      let name = participant.userIdentity.nameComponents.map {
        PersonNameComponentsFormatter.localizedString(from: $0, style: .default)
      }
      return BridgeParticipant(
        id: participant.participantID,
        userId: participant.userIdentity.userRecordID?.recordName,
        name: name?.isEmpty == false ? name : nil,
        role: role(participant.role),
        permission: permission(participant.permission),
        status: status(participant.acceptanceStatus),
        isCurrentUser: participant == current)
    }
    return BridgeShareInfo(
      zone: BridgeZoneRef(
        scope: zone.scope == .private ? .private : .shared, name: zone.zone,
        owner: zone.scope == .shared ? zone.owner : nil),
      isOwner: current?.role == .owner,
      url: share.url?.absoluteString,
      publicPermission: permission(share.publicPermission),
      participants: participants)
  }

  private static func role(_ role: CKShare.ParticipantRole) -> String {
    switch role {
    case .owner: return "owner"
    case .publicUser: return "publicUser"
    default: return "privateUser"
    }
  }

  private static func permission(_ permission: CKShare.ParticipantPermission) -> String {
    switch permission {
    case .readWrite: return "readWrite"
    case .readOnly: return "readOnly"
    default: return "none"
    }
  }

  private static func status(_ status: CKShare.ParticipantAcceptanceStatus) -> String {
    switch status {
    case .pending: return "pending"
    case .accepted: return "accepted"
    case .removed: return "removed"
    default: return "unknown"
    }
  }
}
