import SwiftUI

/// Says who's driving when it isn't you, or that your turn is ending, with the one action that fits.
/// Hidden when you're alone with the simulator: then there's nothing to explain.
struct ControlStatusPill: View {
  let session: StreamSession

  var body: some View {
    if let content {
      HStack(spacing: 12) {
        Image(systemName: content.symbol)
          .foregroundStyle(.secondary)
        content.message
          .font(.subheadline)
          .monospacedDigit()
          .lineLimit(1)
        if let action = content.action {
          Button(action.title) { session.send(action.message) }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.glass)
            .controlSize(.small)
        }
      }
      .padding(.leading, 16)
      .padding(.trailing, content.action == nil ? 16 : 6)
      .padding(.vertical, 6)
      .frame(minHeight: 44)
      .glassEffect()
      .transition(.move(edge: .top).combined(with: .opacity))
    }
  }

  private struct Content {
    struct Action: Equatable {
      let title: LocalizedStringKey
      let message: ClientMessage

      static func == (lhs: Action, rhs: Action) -> Bool { lhs.message == rhs.message }
    }

    let symbol: String
    let message: Text
    let action: Action?
  }

  private var content: Content? {
    guard session.phase == .live, session.state?.controlEnabled == true else { return nil }
    switch session.role {
    case .open:
      return nil
    case .driving:
      guard let ends = session.control?.turnEndDate, let next = session.control?.waiting.first else { return nil }
      return Content(symbol: "hourglass", message: Text("\(next.name) is waiting · \(ends, style: .timer)"),
                     action: .init(title: "Hand Over", message: .releaseControl))
    case .waiting(let position):
      return Content(symbol: "person.2", message: position == 1 ? Text("You're next") : Text("Number \(position) in line"),
                     action: .init(title: "Leave", message: .releaseControl))
    case .watching(let holder):
      return Content(symbol: "eye", message: Text("\(holder) is in control"),
                     action: .init(title: "Ask for Control", message: .requestControl))
    }
  }
}

#Preview("Watching") {
  ZStack(alignment: .top) {
    Color.indigo.ignoresSafeArea()
    ControlStatusPill(session: StreamSession(
      preview: .live, state: .preview,
      control: ControlState(holder: .init(id: "a", name: "Brave Otter"), waiting: [], turnEndsAt: nil)))
  }
  .preferredColorScheme(.dark)
}

#Preview("Waiting") {
  ZStack(alignment: .top) {
    Color.indigo.ignoresSafeArea()
    ControlStatusPill(session: StreamSession(
      preview: .live, state: .preview,
      control: ControlState(holder: .init(id: "a", name: "Brave Otter"), waiting: [.init(id: "me", name: "iPhone")],
                            turnEndsAt: (Date.now.timeIntervalSince1970 + 45) * 1000)))
  }
  .preferredColorScheme(.dark)
}

#Preview("Driving, someone waiting") {
  ZStack(alignment: .top) {
    Color.indigo.ignoresSafeArea()
    ControlStatusPill(session: StreamSession(
      preview: .live, state: .preview,
      control: ControlState(holder: .init(id: "me", name: "iPhone"), waiting: [.init(id: "b", name: "Calm Heron")],
                            turnEndsAt: (Date.now.timeIntervalSince1970 + 45) * 1000)))
  }
  .preferredColorScheme(.dark)
}
