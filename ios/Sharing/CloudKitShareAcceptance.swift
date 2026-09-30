import CloudKit
import Foundation

/// Holds share invites until the app accepts them. The package never accepts
/// by itself: the app shows its own join screen first.
final class ShareAcceptance: @unchecked Sendable {
  static let shared = ShareAcceptance()

  private let lock = NSLock()
  private var invites: [String: CKShare.Metadata] = [:]
  /// Invites that arrived before `configure`. Emitted after it.
  private var early: [String] = []

  func receive(_ metadata: CKShare.Metadata) {
    let token = UUID().uuidString
    lock.lock()
    invites[token] = metadata
    let configured = CloudKitRuntime.shared.isConfigured
    if !configured { early.append(token) }
    lock.unlock()
    if configured { emit(token, metadata) }
  }

  func runtimeDidConfigure() {
    lock.lock()
    let tokens = early
    early = []
    let pending = tokens.compactMap { token in invites[token].map { (token, $0) } }
    lock.unlock()
    for (token, metadata) in pending { emit(token, metadata) }
  }

  private func emit(_ token: String, _ metadata: CKShare.Metadata) {
    let share = metadata.share
    let owner = metadata.ownerIdentity.nameComponents.map {
      PersonNameComponentsFormatter.localizedString(from: $0, style: .default)
    }
    var payload: [String: JSONValue] = [
      "token": .string(token),
      "participantCount": .number(Double(share.participants.count)),
    ]
    payload["title"] = (share[CKShare.SystemFieldKey.title] as? String).map(JSONValue.string) ?? .null
    payload["ownerName"] = owner.flatMap { $0.isEmpty ? nil : JSONValue.string($0) } ?? .null
    CloudKitRuntime.shared.events.emit("inviteReceived", JSONCoding.encode(payload))
  }

  /// Accepts, lets the shared engine fetch, and returns the joined zone.
  func accept(token: String) async throws -> ZoneKey {
    lock.lock()
    let metadata = invites[token]
    lock.unlock()
    guard let metadata else { throw RNCKError(.inviteNotFound, "No invite for this token.") }
    let runtime = CloudKitRuntime.shared
    let container = try runtime.container()
    _ = try await container.accept(metadata)
    lock.lock()
    invites.removeValue(forKey: token)
    lock.unlock()
    let zoneID = metadata.share.recordID.zoneID
    let zone = RecordCodec.zoneKey(for: zoneID, scope: .shared)
    try await runtime.store.upsertZone(zone, doNotSync: false)
    try? await runtime.host(.shared).engine.fetchChanges()
    let info: [String: JSONValue] = ["zone": RecordCodec.zoneJSON(zone), "isShared": .bool(true)]
    runtime.events.emit("shareAccepted", JSONCoding.encode(info))
    return zone
  }

  /// A share URL that reached the app through a plain link.
  func receive(url: URL) async throws {
    let container = try CloudKitRuntime.shared.container()
    receive(try await container.shareMetadata(for: url))
  }
}

/// The entry point for the host app's AppDelegate (contract D11):
///
/// ```swift
/// func application(_ application: UIApplication,
///                  userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
///   CloudKitShareAcceptance.handle(metadata)
/// }
/// ```
///
/// It never accepts. It emits `inviteReceived`, and the app calls
/// `acceptInvite(token)` after its own join screen.
@objc(RNCKShareAcceptance)
public final class CloudKitShareAcceptance: NSObject {
  @objc public static func handle(_ metadata: CKShare.Metadata) {
    ShareAcceptance.shared.receive(metadata)
  }
}
