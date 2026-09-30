import Foundation

/// The listeners JS registered, by event name. Thread-safe. Engine delegate
/// methods never call into JS except through `emit`.
///
/// An `inviteReceived` with no listener yet is held and delivered to the
/// first listener, because a share link can open the app before JS runs.
final class EventHub: @unchecked Sendable {
  typealias Listener = (String) -> Void

  private let lock = NSLock()
  private var listeners: [Double: (event: String, run: Listener)] = [:]
  private var nextId: Double = 1
  private var held: [String: [String]] = [:]

  /// Events that wait for their first listener instead of being dropped.
  private let holdable: Set<String> = ["inviteReceived"]

  func add(_ event: String, _ listener: @escaping Listener) -> Double {
    lock.lock()
    let id = nextId
    nextId += 1
    listeners[id] = (event, listener)
    let pending = held.removeValue(forKey: event) ?? []
    lock.unlock()
    for payload in pending { listener(payload) }
    return id
  }

  func remove(_ id: Double) {
    lock.lock()
    listeners.removeValue(forKey: id)
    lock.unlock()
  }

  func emit(_ event: String, _ payload: String = "{}") {
    lock.lock()
    let targets = listeners.values.filter { $0.event == event }.map(\.run)
    if targets.isEmpty && holdable.contains(event) {
      held[event, default: []].append(payload)
    }
    lock.unlock()
    for target in targets { target(payload) }
  }
}
