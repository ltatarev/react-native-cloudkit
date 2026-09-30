import Foundation
import Network

/// Turns engine activity and errors into the `syncStatus` event:
/// `syncing`, `idle` with a last-synced time, or `waiting` with a reason.
///
/// Sync state never rejects a write. The write waits in the outbox, and this
/// says why. A path monitor reports `offline` at once and clears it when the
/// network comes back.
final class SyncStatusTracker: @unchecked Sendable {
  private let lock = NSLock()
  private let events: EventHub
  private var active: [Scope: Int] = [:]
  private var waiting: Waiting?
  private var offline = false
  private var lastSyncedAt: Double?
  private var lastPayload: String?
  private let monitor = NWPathMonitor()
  var onOnline: (() -> Void)?

  init(events: EventHub) {
    self.events = events
    monitor.pathUpdateHandler = { [weak self] path in
      self?.setOffline(path.status != .satisfied)
    }
    monitor.start(queue: DispatchQueue(label: "react-native-cloudkit.path"))
  }

  deinit { monitor.cancel() }

  func restore(lastSyncedAt: Double?) {
    lock.lock()
    self.lastSyncedAt = lastSyncedAt
    lock.unlock()
  }

  var lastSynced: Double? {
    lock.lock()
    defer { lock.unlock() }
    return lastSyncedAt
  }

  func begin(_ scope: Scope) {
    lock.lock()
    active[scope, default: 0] += 1
    lock.unlock()
    publish()
  }

  /// The end of a fetch or a send. A `waiting` state that an error set in
  /// this pass stays; a pass that ends without one clears it.
  func end(_ scope: Scope, failed: Bool = false) {
    lock.lock()
    active[scope] = max(0, (active[scope] ?? 0) - 1)
    if active.values.allSatisfy({ $0 == 0 }) && !failed {
      if waiting == nil { lastSyncedAt = Date().timeIntervalSince1970 * 1000 }
    }
    lock.unlock()
    publish()
  }

  func wait(_ state: Waiting) {
    lock.lock()
    waiting = state
    lock.unlock()
    publish()
    if state.reason == .throttled, let seconds = state.retryAfter {
      /* The engine retries by itself. The state clears after the wait. */
      DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [weak self] in self?.clearWaiting() }
    }
  }

  func clearWaiting() {
    lock.lock()
    waiting = nil
    lock.unlock()
    publish()
  }

  private func setOffline(_ value: Bool) {
    lock.lock()
    let changed = offline != value
    offline = value
    if !value, waiting?.reason == .offline { waiting = nil }
    lock.unlock()
    guard changed else { return }
    publish()
    if !value { onOnline?() }
  }

  /// The current state as the event payload.
  func payload() -> String {
    lock.lock()
    defer { lock.unlock() }
    var object: [String: JSONValue]
    if offline {
      object = ["state": .string("waiting"), "reason": .string(WaitingReason.offline.rawValue)]
    } else if let waiting {
      object = ["state": .string("waiting"), "reason": .string(waiting.reason.rawValue)]
      if let retry = waiting.retryAfter { object["retryAfter"] = .number(retry) }
    } else if active.values.contains(where: { $0 > 0 }) {
      object = ["state": .string("syncing")]
    } else {
      object = ["state": .string("idle")]
      if let lastSyncedAt { object["lastSyncedAt"] = .number(lastSyncedAt.rounded()) }
    }
    return JSONCoding.encode(object)
  }

  /// Emits only when the state changed.
  func publish() {
    let next = payload()
    lock.lock()
    let changed = next != lastPayload
    lastPayload = next
    lock.unlock()
    if changed { events.emit("syncStatus", next) }
  }
}
