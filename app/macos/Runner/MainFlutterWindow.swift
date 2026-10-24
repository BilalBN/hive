import Cocoa
import FlutterMacOS
import SwiftUI

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    NotchController.register(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}

// MARK: - Song controls by the notch (M6)

/// What the panel shows.
final class NotchModel: ObservableObject {
  @Published var title = ""
  @Published var artist = ""
  @Published var playing = false
  @Published var art: NSImage?
  @Published var expanded = false
}

/// A small black panel that grows out of the notch when the pointer is on
/// it (and for a moment when the song changes): the cover, title and
/// artist, previous, play/pause and next. Macs without a notch never show it.
final class NotchController: NSObject {
  private static var shared: NotchController?
  private let channel: FlutterMethodChannel
  private let model = NotchModel()
  private var panel: NSPanel?
  private var hovering = false
  private var lastTrack: String?
  private var flash: DispatchWorkItem?

  private let expandedWidth: CGFloat = 380
  private let expandedExtra: CGFloat = 68

  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "hive/notch", binaryMessenger: messenger)
    let controller = NotchController(channel: channel)
    shared = controller
    channel.setMethodCallHandler { call, result in controller.handle(call, result) }
    NotificationCenter.default.addObserver(
      controller, selector: #selector(screensChanged),
      name: NSApplication.didChangeScreenParametersNotification, object: nil)
  }

  private init(channel: FlutterMethodChannel) {
    self.channel = channel
  }

  /// The notch: its screen, width and height (the menu bar's height).
  private func notch() -> (NSScreen, CGFloat, CGFloat)? {
    for screen in NSScreen.screens {
      let top = screen.safeAreaInsets.top
      guard top > 0, let left = screen.auxiliaryTopLeftArea,
        let right = screen.auxiliaryTopRightArea
      else { continue }
      let width = screen.frame.width - left.width - right.width
      if width > 0 { return (screen, width, top) }
    }
    return nil
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    switch call.method {
    case "update":
      guard let args = call.arguments as? [String: Any] else {
        result(nil)
        return
      }
      update(args)
      result(nil)
    case "hide":
      panel?.orderOut(nil)
      lastTrack = nil
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func update(_ args: [String: Any]) {
    guard let found = notch() else {
      panel?.orderOut(nil)
      return
    }
    let (screen, notchWidth, notchHeight) = found
    model.title = args["title"] as? String ?? ""
    model.artist = args["artist"] as? String ?? ""
    model.playing = args["playing"] as? Bool ?? false
    if let data = args["art"] as? FlutterStandardTypedData {
      model.art = NSImage(data: data.data)
    } else if args["art"] is NSNull {
      model.art = nil
    }
    let panel = self.panel ?? makePanel(notchWidth: notchWidth, notchHeight: notchHeight)
    self.panel = panel
    place(on: screen, notchWidth: notchWidth, notchHeight: notchHeight)
    panel.orderFrontRegardless()

    // A new song: show it for a moment.
    let track = args["trackId"] as? String
    if track != lastTrack {
      lastTrack = track
      flash?.cancel()
      setExpanded(true)
      let work = DispatchWorkItem { [weak self] in
        guard let self, !self.hovering else { return }
        self.setExpanded(false)
      }
      flash = work
      DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }
  }

  private func makePanel(notchWidth: CGFloat, notchHeight: CGFloat) -> NSPanel {
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: notchWidth, height: notchHeight),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false)
    panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.isMovable = false
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false

    let hosting = FirstClickHostingView(
      rootView: NotchView(model: model, notchHeight: notchHeight) { [weak self] action in
        self?.channel.invokeMethod("command", arguments: action)
      })
    let hover = HoverView(frame: panel.contentLayoutRect)
    hover.onHover = { [weak self] inside in
      guard let self else { return }
      self.hovering = inside
      if inside { self.flash?.cancel() }
      self.setExpanded(inside)
    }
    hosting.frame = hover.bounds
    hosting.autoresizingMask = [.width, .height]
    hover.addSubview(hosting)
    hover.autoresizingMask = [.width, .height]
    panel.contentView = hover
    return panel
  }

  private func setExpanded(_ expanded: Bool) {
    guard let found = notch() else { return }
    let (screen, notchWidth, notchHeight) = found
    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
      model.expanded = expanded
    }
    place(on: screen, notchWidth: notchWidth, notchHeight: notchHeight)
  }

  /// The panel's frame: the notch itself when small (nothing in the menu bar
  /// is ever under it), wider and taller when showing the song.
  private func place(on screen: NSScreen, notchWidth: CGFloat, notchHeight: CGFloat) {
    guard let panel else { return }
    let width = model.expanded ? expandedWidth : notchWidth
    let height = model.expanded ? notchHeight + expandedExtra : notchHeight
    let frame = NSRect(
      x: screen.frame.midX - width / 2, y: screen.frame.maxY - height,
      width: width, height: height)
    panel.setFrame(frame, display: true, animate: false)
  }

  @objc private func screensChanged() {
    guard let panel, panel.isVisible else { return }
    if let found = notch() {
      let (screen, notchWidth, notchHeight) = found
      place(on: screen, notchWidth: notchWidth, notchHeight: notchHeight)
    } else {
      panel.orderOut(nil)
    }
  }
}

/// Reports the pointer coming and going, even while Hive isn't the app in front.
final class HoverView: NSView {
  var onHover: ((Bool) -> Void)?

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(
      NSTrackingArea(
        rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
        owner: self, userInfo: nil))
  }

  override func mouseEntered(with event: NSEvent) { onHover?(true) }
  override func mouseExited(with event: NSEvent) { onHover?(false) }
}

/// Buttons answer the first click, without bringing Hive to the front.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct NotchShape: Shape {
  var radius: CGFloat

  var animatableData: CGFloat {
    get { radius }
    set { radius = newValue }
  }

  func path(in r: CGRect) -> Path {
    var p = Path()
    p.move(to: CGPoint(x: r.minX, y: r.minY))
    p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
    p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - radius))
    p.addQuadCurve(to: CGPoint(x: r.maxX - radius, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY))
    p.addLine(to: CGPoint(x: r.minX + radius, y: r.maxY))
    p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - radius), control: CGPoint(x: r.minX, y: r.maxY))
    p.closeSubpath()
    return p
  }
}

struct NotchView: View {
  @ObservedObject var model: NotchModel
  let notchHeight: CGFloat
  let send: (String) -> Void

  var body: some View {
    ZStack(alignment: .top) {
      NotchShape(radius: model.expanded ? 18 : 8)
        .fill(Color.black)
      if model.expanded {
        HStack(spacing: 12) {
          Group {
            if let art = model.art {
              Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
            } else {
              Color.white.opacity(0.15)
            }
          }
          .frame(width: 44, height: 44)
          .clipShape(RoundedRectangle(cornerRadius: 7))
          VStack(alignment: .leading, spacing: 2) {
            Text(model.title)
              .font(.system(size: 13, weight: .semibold))
              .foregroundColor(.white)
              .lineLimit(1)
            Text(model.artist)
              .font(.system(size: 11))
              .foregroundColor(.white.opacity(0.7))
              .lineLimit(1)
          }
          Spacer(minLength: 4)
          control("backward.fill", "previous", label: "Previous")
          control(model.playing ? "pause.fill" : "play.fill", "toggle", label: model.playing ? "Pause" : "Play", size: 18)
          control("forward.fill", "next", label: "Next")
        }
        .padding(.horizontal, 16)
        .padding(.top, notchHeight + 4)
        .padding(.bottom, 10)
        .transition(.opacity)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }

  private func control(_ symbol: String, _ action: String, label: String, size: CGFloat = 14) -> some View {
    Button(action: { send(action) }) {
      Image(systemName: symbol)
        .font(.system(size: size, weight: .semibold))
        .foregroundColor(.white)
        .frame(width: 30, height: 30)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(label)
    .accessibilityLabel(label)
  }
}
