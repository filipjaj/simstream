import Foundation
import Testing
@testable import SimStream

struct EdgeGuardTests {
  @Test func passesGesturesInTheMiddleOfTheScreen() {
    var edges = EdgeGuard()
    let events: [InputEvent] = [.touch(.down, x: 0.5, y: 0.5), .touch(.move, x: 0.5, y: 0.2), .touch(.up, x: 0.5, y: 0.2)]
    #expect(events.flatMap { edges.filter($0) } == events)
  }

  @Test func dropsSwipeUpFromTheHomeIndicator() {
    var edges = EdgeGuard()
    let events: [InputEvent] = [.touch(.down, x: 0.5, y: 0.98), .touch(.move, x: 0.5, y: 0.8), .touch(.move, x: 0.5, y: 0.6), .touch(.up, x: 0.5, y: 0.6)]
    #expect(events.flatMap { edges.filter($0) }.isEmpty)
    // The next gesture is unaffected.
    #expect(edges.filter(.touch(.down, x: 0.5, y: 0.5)) == [.touch(.down, x: 0.5, y: 0.5)])
  }

  @Test func dropsSwipeDownFromTheStatusBar() {
    var edges = EdgeGuard()
    let events: [InputEvent] = [.touch(.down, x: 0.9, y: 0.01), .touch(.down, x: 0.9, y: 0.3), .touch(.up, x: 0.9, y: 0.3)]
    #expect(events.flatMap { edges.filter($0) }.isEmpty)
  }

  @Test func deliversTapsOnAnEdgeWhenTheFingerLifts() {
    var edges = EdgeGuard()
    #expect(edges.filter(.touch(.down, x: 0.3, y: 0.97)).isEmpty)
    #expect(edges.filter(.touch(.move, x: 0.305, y: 0.97)).isEmpty)
    #expect(edges.filter(.touch(.up, x: 0.305, y: 0.97)) == [.touch(.down, x: 0.3, y: 0.97), .touch(.up, x: 0.3, y: 0.97)])
  }

  @Test func dropsHardwareButtonsButKeepsTyping() {
    var edges = EdgeGuard()
    #expect(edges.filter(.button(.home)).isEmpty)
    #expect(edges.filter(.button(.lock)).isEmpty)
    #expect(edges.filter(.button(.siri)).isEmpty)
    #expect(edges.filter(.text("hi")) == [.text("hi")])
    #expect(edges.filter(.key(40)) == [.key(40)])
  }

  @Test func dropsTwoFingerGesturesThatStartOnAnEdge() {
    var edges = EdgeGuard()
    let a = CGPoint(x: 0.4, y: 0.99), b = CGPoint(x: 0.6, y: 0.5)
    #expect(edges.filter(.twoFingers(.down, a, b)).isEmpty)
    #expect(edges.filter(.twoFingers(.move, a, b)).isEmpty)
    #expect(edges.filter(.twoFingers(.up, a, b)).isEmpty)
    let pinch = InputEvent.twoFingers(.down, CGPoint(x: 0.4, y: 0.5), b)
    #expect(edges.filter(pinch) == [pinch])
  }
}

struct InstalledAppsTests {
  @Test func keepsUserAppsSortedByName() {
    let plist = """
    {
      "com.apple.Preferences" = { ApplicationType = System; CFBundleDisplayName = Settings; };
      "com.example.zeta" = { ApplicationType = User; CFBundleName = Zeta; };
      "com.example.alpha" = { ApplicationType = User; CFBundleDisplayName = Alpha; CFBundleName = alpha; };
    }
    """
    #expect(InstalledApps.parse(Data(plist.utf8)) == [
      LockedApp(bundleID: "com.example.alpha", name: "Alpha"),
      LockedApp(bundleID: "com.example.zeta", name: "Zeta"),
    ])
  }
}

@MainActor
struct LockMemoryTests {
  @Test func remembersTheLastLockPerSimulatorAcrossLaunches() throws {
    let suite = "LockMemoryTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let kupp = LockedApp(bundleID: "com.example.kupp", name: "Kupp")

    LockMemory(defaults: defaults).remember(kupp, for: "A")
    let reopened = LockMemory(defaults: defaults)
    #expect(reopened.app(for: "A") == kupp)
    #expect(reopened.app(for: "B") == nil)

    reopened.remember(nil, for: "A")
    #expect(LockMemory(defaults: defaults).app(for: "A") == nil)
  }
}
