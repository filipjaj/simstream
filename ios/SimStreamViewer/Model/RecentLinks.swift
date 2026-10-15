import Foundation
import Observation

/// Links opened recently that haven't expired yet. Share links live minutes to hours, so the list
/// prunes itself instead of growing into a graveyard.
@MainActor @Observable
final class RecentLinks {
  struct Entry: Codable, Hashable, Identifiable, Sendable {
    let link: StreamLink
    var deviceName: String?
    var runtime: String?
    var expiresAt: Date?
    var openedAt: Date
    var id: URL { link.pageURL }

    func isLive(at now: Date) -> Bool { expiresAt.map { $0 > now } ?? true }
  }

  private(set) var entries: [Entry] = []
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let key = "recentLinks"

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    if let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode([Entry].self, from: data) {
      entries = saved
    }
    prune()
  }

  func opened(_ link: StreamLink, now: Date = .now) {
    var entry = entries.first { $0.link == link } ?? Entry(link: link, openedAt: now)
    entry.openedAt = now
    entries.removeAll { $0.link == link }
    entries.insert(entry, at: 0)
    save()
  }

  func update(_ link: StreamLink, with state: ViewerState) {
    guard let index = entries.firstIndex(where: { $0.link == link }) else { return }
    let current = entries[index]
    var entry = current
    entry.deviceName = state.device.name
    entry.runtime = state.device.runtime
    entry.expiresAt = state.expiryDate
    guard entry != current else { return }
    entries[index] = entry
    save()
  }

  func remove(_ entry: Entry) {
    entries.removeAll { $0 == entry }
    save()
  }

  func prune(now: Date = .now) {
    let live = entries.filter { $0.isLive(at: now) }.prefix(8)
    guard live.count != entries.count else { return }
    entries = Array(live)
    save()
  }

  private func save() {
    if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: key) }
  }
}
