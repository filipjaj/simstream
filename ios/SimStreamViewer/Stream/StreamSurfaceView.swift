import AVFoundation
import SwiftUI
import UIKit

/// Shows the simulator screen and turns this device's touches and keys into simulator input.
/// UIKit rather than SwiftUI gestures: raw touches arrive without recogniser delay, which is what
/// makes scrolling and dragging in the simulator feel attached to your finger.
final class StreamSurfaceView: UIView, UIKeyInput {
  var session: StreamSession? {
    didSet {
      guard session !== oldValue else { return }
      oldValue?.displayLayer.removeFromSuperlayer()
      if let layer = session?.displayLayer { screen.layer.addSublayer(layer) }
      setNeedsLayout()
    }
  }

  /// Show the software keyboard. Hardware keyboards work regardless.
  var wantsSoftwareKeyboard = false {
    didSet {
      guard wantsSoftwareKeyboard != oldValue else { return }
      reloadInputViews()
      if wantsSoftwareKeyboard { becomeFirstResponder() }
    }
  }

  /// Shaking reveals the controls; every touch belongs to the simulator, so gestures can't.
  var onShake: (() -> Void)?

  var videoSize: CGSize? { didSet { if videoSize != oldValue { setNeedsLayout() } } }
  var cornerRatio: CGFloat = 0 { didSet { if cornerRatio != oldValue { setNeedsLayout() } } }

  private let screen = UIView()
  private var tracker = TouchTracker<ObjectIdentifier>()

  /// Pinch and two-finger gestures, when the Mac supports them.
  var multitouch = false {
    didSet {
      tracker.multitouch = multitouch
    }
  }
  /// An empty input view hides the software keyboard while keeping hardware keys flowing to us.
  private let noKeyboard = UIView(frame: .zero)

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .black
    // Always on, so extra fingers are seen and ignored instead of reported as the first finger.
    isMultipleTouchEnabled = true
    screen.clipsToBounds = true
    screen.layer.cornerCurve = .continuous
    screen.isUserInteractionEnabled = false
    addSubview(screen)
    isAccessibilityElement = true
    accessibilityLabel = String(localized: "Simulator screen")
    accessibilityTraits = .allowsDirectInteraction
    accessibilityCustomActions = [UIAccessibilityCustomAction(name: String(localized: "Show controls")) { [weak self] _ in
      self?.onShake?()
      return true
    }]
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override func layoutSubviews() {
    super.layoutSubviews()
    let fitted = videoSize.map { AVMakeRect(aspectRatio: $0, insideRect: bounds) } ?? bounds
    screen.frame = fitted.integral
    screen.layer.cornerRadius = screen.frame.width * cornerRatio
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    session?.displayLayer.frame = screen.bounds
    CATransaction.commit()
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil { becomeFirstResponder() }
  }

  override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
    if motion == .motionShake { onShake?() } else { super.motionEnded(motion, with: event) }
  }

  // MARK: - Touch

  /// Normalised position on the simulator screen. Points outside clamp to the edge, so a drag that
  /// leaves the letterbox keeps going instead of lifting the finger.
  private func normalised(_ touch: UITouch) -> CGPoint {
    let p = touch.location(in: screen)
    let size = screen.bounds.size
    guard size.width > 0, size.height > 0 else { return .zero }
    return CGPoint(x: min(max(p.x / size.width, 0), 1), y: min(max(p.y / size.height, 0), 1))
  }

  private func points(_ touches: Set<UITouch>) -> [(ObjectIdentifier, CGPoint)] {
    touches.map { (ObjectIdentifier($0), normalised($0)) }
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    session?.send(touches: tracker.began(points(touches)))
  }

  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
    session?.send(touches: tracker.moved(points(touches)))
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
    session?.send(touches: tracker.ended(points(touches)))
  }

  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
    session?.send(touches: tracker.ended(points(touches)))
  }

  // MARK: - Keyboard

  override var canBecomeFirstResponder: Bool { true }
  override var inputView: UIView? { wantsSoftwareKeyboard ? nil : noKeyboard }
  override var inputAssistantItem: UITextInputAssistantItem {
    let item = super.inputAssistantItem
    item.leadingBarButtonGroups = []
    item.trailingBarButtonGroups = []
    return item
  }

  var hasText: Bool { true }
  var autocorrectionType: UITextAutocorrectionType { get { .no } set {} }
  var autocapitalizationType: UITextAutocapitalizationType { get { .none } set {} }
  var spellCheckingType: UITextSpellCheckingType { get { .no } set {} }
  var smartQuotesType: UITextSmartQuotesType { get { .no } set {} }
  var smartDashesType: UITextSmartDashesType { get { .no } set {} }
  var smartInsertDeleteType: UITextSmartInsertDeleteType { get { .no } set {} }

  func insertText(_ text: String) {
    guard let session, session.canControl else { return }
    for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
      if index > 0 { session.send(.key(HIDKey.returnKey)) }
      if !line.isEmpty { session.send(.text(String(line))) }
    }
  }

  func deleteBackward() {
    guard let session, session.canControl else { return }
    session.send(.key(HIDKey.backspace))
  }

  /// Keys UIKeyInput never sees (arrows, escape, forward delete, tab) and ⌘⇧H for Home.
  /// `UIKeyboardHIDUsage` raw values are USB HID usage codes, which is what the Mac injects.
  override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    var handled = false
    for press in presses {
      guard let key = press.key, let session, session.canControl else { continue }
      if key.modifierFlags.contains([.command, .shift]), key.charactersIgnoringModifiers.lowercased() == "h" {
        session.press(.home)
        handled = true
      } else if HIDKey.passthrough.contains(key.keyCode) {
        session.send(.key(UInt32(key.keyCode.rawValue)))
        handled = true
      }
    }
    if !handled { super.pressesBegan(presses, with: event) }
  }
}

enum HIDKey {
  static let returnKey: UInt32 = 40
  static let backspace: UInt32 = 42
  static let passthrough: Set<UIKeyboardHIDUsage> = [
    .keyboardEscape, .keyboardTab, .keyboardDeleteForward,
    .keyboardRightArrow, .keyboardLeftArrow, .keyboardDownArrow, .keyboardUpArrow,
  ]
}

struct StreamSurface: UIViewRepresentable {
  let session: StreamSession
  var showsKeyboard: Bool
  var onShake: () -> Void

  func makeUIView(context: Context) -> StreamSurfaceView {
    StreamSurfaceView()
  }

  func updateUIView(_ view: StreamSurfaceView, context: Context) {
    view.session = session
    view.videoSize = session.videoSize
    view.cornerRatio = session.state?.device.cornerRatio ?? 0
    view.wantsSoftwareKeyboard = showsKeyboard
    view.onShake = onShake
    view.multitouch = session.multitouch
  }
}
