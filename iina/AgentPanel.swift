//
//  AgentPanel.swift
//  iina
//
//  Created by Qiulin Fan on 2026-10-24.
//  Copyright © 2026 lhc. All rights reserved.
//

import Cocoa
import ImageIO
import UniformTypeIdentifiers

/// Palette and font of the owner's Zed setup: Ayu Dark with JetBrainsMono Nerd Font Mono.
fileprivate enum Style {
  static let panel = rgb(0x1f2127)
  static let editor = rgb(0x0d1016)
  static let border = rgb(0x3f4043)
  static let borderVariant = rgb(0x2d2f34)
  static let borderFocused = rgb(0x1b4a6e)
  static let text = rgb(0xbfbdb6)
  static let muted = rgb(0x8a8986)
  static let placeholder = rgb(0x696a6a)
  static let accent = rgb(0x5ac1fe)
  static let error = rgb(0xef7177)
  static let success = rgb(0xaad84c)

  static func font(_ size: CGFloat = 13, bold: Bool = false, italic: Bool = false) -> NSFont {
    var font = NSFont(name: "JetBrainsMono Nerd Font Mono", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    if bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
    if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
    return font
  }

  private static func rgb(_ hex: Int) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: 1)
  }
}

fileprivate func timeString(_ seconds: Double) -> String {
  VideoTime(seconds).stringRepresentation
}

/// What the player was showing when the user stopped to ask.
struct AgentMoment {
  let position: Double
  let duration: Double?
  let title: String
  let path: String?
  let chapter: String?
  let subtitles: [(time: Double, text: String)]
  let subtitleFiles: [String]
  /// JPEG of the displayed frame, subtitles included.
  var frame: Data?
}

// MARK: - Controller

/// The agent panel docked on the trailing side of the player window. Video and panel sit side by side;
/// questions are sent to omp together with the playback position, recent subtitles and the current frame.
class AgentPanelController: NSObject, NSTextViewDelegate {
  unowned let mainWindow: MainWindowController
  var player: PlayerCore { mainWindow.player }

  let view = AgentPanelView()
  private let client = AgentClient()

  private(set) var isVisible = Preference.bool(for: .agentPanelVisible)
  private(set) var width = CGFloat(Preference.integer(for: .agentPanelWidth)).clamped(to: AgentPanelController.widthRange)
  static let widthRange: ClosedRange<CGFloat> = 260...720

  /// Width the panel takes away from the video area.
  var visibleWidth: CGFloat { isVisible ? width : 0 }

  private var trailingConstraint: NSLayoutConstraint!
  private var widthConstraint: NSLayoutConstraint!

  private enum ClientState { case idle, starting, ready }
  private var clientState = ClientState.idle
  private var whenReady: [(Error?) -> Void] = []
  private var isBusy = false { didSet { view.composer.setBusy(isBusy) } }

  /// Position whose frame the agent has already seen, so follow-ups don't resend it.
  private var lastSentFramePosition: Double?

  private var currentReply: AssistantMessageView?
  private var currentReplyId: String?
  private var toolViews: [String: ToolCallView] = [:]
  private var thinkingView: NSView?
  private var modelOptionId: String?
  private var thinkingOptionId: String?

  init(mainWindow: MainWindowController) {
    self.mainWindow = mainWindow
    super.init()

    view.controller = self
    view.composer.textView.delegate = self
    view.composer.textView.onSubmit = { [unowned self] in submit() }
    view.composer.textView.onEscape = { [unowned self] in mainWindow.window?.makeFirstResponder(nil) }
    view.composer.sendButton.target = self
    view.composer.sendButton.action = #selector(sendOrStop)
    for popup in [view.composer.modelPopup, view.composer.thinkingPopup] {
      popup.target = self
      popup.action = #selector(configOptionSelected(_:))
    }
    view.header.newThreadButton.target = self
    view.header.newThreadButton.action = #selector(newThread)
    view.header.hideButton.target = self
    view.header.hideButton.action = #selector(hidePanel)

    client.onUpdate = { [unowned self] in handleUpdate($0) }
    client.onConfigOptions = { [unowned self] in updateConfigOptions($0) }
    client.onPermissionRequest = { [unowned self] in askPermission($0, reply: $1) }
    // Start omp as soon as there is something to ask about, so the model and thinking menus are
    // filled before the first question. Opening a session doesn't call the model.
    player.observe(.iinaFileLoaded) { [unowned self] _ in warmUp() }
    _ = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                           queue: .main) { [weak self] _ in
      self?.client.stop()
      AgentClient.waitForCleanups()
    }

    client.onExit = { [unowned self] message in
      clientState = .idle
      if isBusy { isBusy = false }
      removeThinking()
      view.transcript.append(NoticeView(message, color: Style.error))
    }
  }

  // MARK: Layout

  /// Pin the panel to the trailing edge of the window's content view. The video container and the
  /// trailing sidebar anchor to `view.leadingAnchor`.
  func install(in contentView: NSView) {
    contentView.addSubview(view)
    view.translatesAutoresizingMaskIntoConstraints = false
    widthConstraint = view.widthAnchor.constraint(equalToConstant: width)
    trailingConstraint = contentView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: isVisible ? 0 : -width)
    NSLayoutConstraint.activate([
      widthConstraint, trailingConstraint,
      view.topAnchor.constraint(equalTo: contentView.topAnchor),
      view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
    ])
    view.isHidden = !isVisible
  }

  func setVisible(_ visible: Bool) {
    guard visible != isVisible else { return }
    isVisible = visible
    Preference.set(visible, for: .agentPanelVisible)
    trailingConstraint.constant = visible ? 0 : -width
    view.isHidden = !visible
    if !visible, view.window?.firstResponder === view.composer.textView {
      view.window?.makeFirstResponder(nil)
    }
    mainWindow.agentPanelDidChangeVisibility()
    if visible { warmUp() }
  }

  private func warmUp() {
    guard isVisible, player.info.state.active else { return }
    ensureStarted { _ in }
  }

  func resize(to newWidth: CGFloat) {
    width = newWidth.clamped(to: AgentPanelController.widthRange)
    widthConstraint.constant = width
    mainWindow.agentPanelDidResize()
  }

  func finishResizing() {
    Preference.set(Int(width), for: .agentPanelWidth)
  }

  @objc func hidePanel() {
    setVisible(false)
  }

  @objc func toggle() {
    setVisible(!isVisible)
  }

  // MARK: Asking

  /// Put the cursor in the composer; the video keeps playing.
  @objc func askAboutCurrentMoment() {
    setVisible(true)
    ensureStarted { _ in }
    view.window?.makeFirstResponder(view.composer.textView)
  }

  func textDidChange(_ notification: Notification) {
    view.composer.textDidChange()
    // Start omp while the question is being typed so it's ready on send.
    if !view.composer.textView.string.isEmpty {
      ensureStarted { _ in }
    }
  }

  @objc private func sendOrStop() {
    if isBusy {
      client.cancel()
    } else {
      submit()
    }
  }

  private func submit() {
    let question = view.composer.textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !question.isEmpty, !isBusy else { return }
    // The question is pinned to what is on screen when it is sent, even while the video plays.
    var moment = captureMoment(withFrame: view.composer.attachesFrame)
    if let position = moment?.position, let last = lastSentFramePosition, abs(position - last) < 0.05 {
      moment?.frame = nil
    }

    view.composer.textView.string = ""
    view.composer.textDidChange()
    view.transcript.append(UserMessageView(question, moment: moment, target: self, action: #selector(seekToMessageMoment(_:))))
    view.window?.makeFirstResponder(nil)

    var blocks: [AgentClient.JSON] = []
    var text = question
    if let moment {
      text = contextText(for: moment) + "\n\nQuestion: " + question
    }
    blocks.append(["type": "text", "text": text])
    if let frame = moment?.frame {
      blocks.append(["type": "image", "mimeType": "image/jpeg", "data": frame.base64EncodedString()])
      lastSentFramePosition = moment?.position
    }

    isBusy = true
    currentReply = nil
    showThinking()
    ensureStarted { [weak self] error in
      guard let self else { return }
      if let error {
        self.finishTurn(error: error)
        return
      }
      self.client.prompt(blocks) { result in
        switch result {
        case .success(let stopReason):
          self.finishTurn(error: nil, cancelled: stopReason == "cancelled")
        case .failure(let error):
          self.finishTurn(error: error)
        }
      }
    }
  }

  private func finishTurn(error: Error?, cancelled: Bool = false) {
    isBusy = false
    removeThinking()
    currentReply = nil
    if let error {
      view.transcript.append(NoticeView(error.localizedDescription, color: Style.error))
    } else if cancelled {
      view.transcript.append(NoticeView("Stopped", color: Style.muted))
    }
  }

  @objc private func newThread() {
    reset()
    warmUp()
  }

  /// End the omp process and clear the thread; also called when the window closes.
  func reset() {
    client.stop()
    clientState = .idle
    whenReady.removeAll()
    isBusy = false
    lastSentFramePosition = nil
    currentReply = nil
    toolViews.removeAll()
    thinkingView = nil
    view.header.setThreadTitle(nil)
    view.composer.setCost(nil)
    view.transcript.clear()
    // The next session reports its own options.
    view.composer.modelPopup.isHidden = true
    view.composer.thinkingPopup.isHidden = true
  }

  @objc private func seekToMessageMoment(_ sender: NSButton) {
    guard let position = (sender as? MomentButton)?.position else { return }
    player.seek(absoluteSecond: position)
  }

  @objc private func configOptionSelected(_ sender: NSPopUpButton) {
    let id = sender === view.composer.modelPopup ? modelOptionId : thinkingOptionId
    guard let id, let value = sender.selectedItem?.representedObject as? String else { return }
    client.setConfigOption(id, value: value)
  }

  // MARK: omp session

  private func ensureStarted(_ completion: @escaping (Error?) -> Void) {
    switch clientState {
    case .ready:
      completion(nil)
    case .starting:
      whenReady.append(completion)
    case .idle:
      clientState = .starting
      whenReady.append(completion)
      client.start(cwd: workingDirectory()) { [weak self] error in
        guard let self else { return }
        self.clientState = error == nil ? .ready : .idle
        if error != nil { self.client.stop() }
        let callbacks = self.whenReady
        self.whenReady.removeAll()
        callbacks.forEach { $0(error) }
      }
    }
  }

  /// The folder of a local video, so the agent can read subtitle files next to it.
  private func workingDirectory() -> String {
    if !player.info.isNetworkResource, let url = player.info.currentURL, url.isFileURL {
      return url.deletingLastPathComponent().path
    }
    return NSHomeDirectory()
  }

  private func handleUpdate(_ update: AgentClient.JSON) {
    switch update["sessionUpdate"] as? String {
    case "agent_message_chunk":
      guard let content = update["content"] as? AgentClient.JSON, let text = content["text"] as? String else { return }
      removeThinking()
      let messageId = update["messageId"] as? String
      if currentReply == nil || (messageId != nil && messageId != currentReplyId) {
        let reply = AssistantMessageView()
        view.transcript.append(reply)
        currentReply = reply
        currentReplyId = messageId
      }
      currentReply?.append(text)
      view.transcript.contentDidGrow()
    case "tool_call":
      guard let id = update["toolCallId"] as? String else { return }
      removeThinking()
      let toolView = ToolCallView(title: update["title"] as? String ?? "Tool", status: update["status"] as? String)
      toolViews[id] = toolView
      currentReply = nil
      view.transcript.append(toolView)
    case "tool_call_update":
      guard let id = update["toolCallId"] as? String, let toolView = toolViews[id] else { return }
      toolView.update(title: update["title"] as? String, status: update["status"] as? String)
    case "session_info_update":
      if let title = update["title"] as? String, !title.isEmpty {
        view.header.setThreadTitle(title)
      }
    case "usage_update":
      if let cost = update["cost"] as? AgentClient.JSON, let amount = cost["amount"] as? Double {
        view.composer.setCost(amount)
      }
    default:
      break
    }
  }

  /// omp reports these again when the model changes, since each model has its own thinking levels.
  private func updateConfigOptions(_ options: [AgentClient.JSON]) {
    modelOptionId = fill(view.composer.modelPopup, from: options, category: "model") ?? modelOptionId
    thinkingOptionId = fill(view.composer.thinkingPopup, from: options, category: "thought_level",
                            symbol: "brain") ?? thinkingOptionId
  }

  /// Fill a footer popup from the session's select option of `category` and return the option's id.
  private func fill(_ popup: NSPopUpButton, from options: [AgentClient.JSON], category: String, symbol: String? = nil) -> String? {
    guard let option = options.first(where: { $0["category"] as? String == category }),
          let id = option["id"] as? String,
          let choices = option["options"] as? [AgentClient.JSON] else { return nil }
    let current = option["currentValue"] as? String
    popup.removeAllItems()
    for choice in choices {
      guard let value = choice["value"] as? String else { continue }
      let item = NSMenuItem(title: choice["name"] as? String ?? value, action: nil, keyEquivalent: "")
      item.representedObject = value
      item.toolTip = choice["description"] as? String
      item.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: option["name"] as? String) }
      popup.menu?.addItem(item)
      if value == current { popup.select(item) }
    }
    popup.toolTip = option["name"] as? String
    popup.isHidden = false
    return id
  }

  private func askPermission(_ params: AgentClient.JSON, reply: @escaping (String?) -> Void) {
    removeThinking()
    let toolCall = params["toolCall"] as? AgentClient.JSON
    let options = (params["options"] as? [AgentClient.JSON] ?? []).compactMap { option -> (id: String, name: String)? in
      guard let id = option["optionId"] as? String else { return nil }
      return (id, option["name"] as? String ?? id)
    }
    view.transcript.append(PermissionView(title: toolCall?["title"] as? String ?? "Allow tool call?",
                                          options: options, reply: reply))
  }

  private func showThinking() {
    let label = NoticeView("Thinking…", color: Style.muted)
    thinkingView = label
    view.transcript.append(label)
  }

  private func removeThinking() {
    thinkingView?.removeFromSuperview()
    thinkingView = nil
  }

  // MARK: Context

  private func captureMoment(withFrame: Bool) -> AgentMoment? {
    guard player.info.state.active, let mpv = player.mpv else { return nil }
    let position = mpv.getDouble(MPVProperty.timePos)
    let url = player.info.currentURL
    let subtitles = player.info.recentSubtitles
      .filter { $0.time <= position + 0.5 && $0.time > position - 120 }
      .suffix(12)
    let chapter = player.info.chapters.last { $0.time.second <= position }?.title
    return AgentMoment(
      position: position,
      duration: player.info.videoDuration?.second,
      title: player.getMediaTitle(),
      path: url?.isFileURL == true ? url?.path : url?.absoluteString,
      chapter: chapter,
      subtitles: Array(subtitles),
      subtitleFiles: player.info.subTracks.compactMap { $0.isExternal ? $0.externalFilename : nil },
      frame: withFrame ? captureFrame() : nil
    )
  }

  /// Save the displayed frame with mpv and shrink it to a JPEG small enough to send.
  private func captureFrame() -> Data? {
    guard let vid = player.info.vid, vid > 0 else { return nil }
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("iina-agent-\(UUID().uuidString).jpg")
    defer { try? FileManager.default.removeItem(at: file) }
    player.mpv.command(.screenshotToFile, args: [file.path, "subtitles"])
    guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
    let thumbnailOptions: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: 1280,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else { return nil }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
  }

  private func contextText(for moment: AgentMoment) -> String {
    var lines = ["[IINA] The user is watching a video and asks about the moment below; playback may have continued since. Answer concisely, in the language of the question."]
    lines.append("Video: \(moment.title)" + (moment.path.map { " — \($0)" } ?? ""))
    lines.append("Position: \(timeString(moment.position))" + (moment.duration.map { " / \(timeString($0))" } ?? ""))
    if let chapter = moment.chapter {
      lines.append("Chapter: \(chapter)")
    }
    if !moment.subtitles.isEmpty {
      lines.append("Subtitles leading up to this moment:")
      lines += moment.subtitles.map { "[\(timeString($0.time))] \($0.text.replacingOccurrences(of: "\n", with: " / "))" }
    }
    if !moment.subtitleFiles.isEmpty {
      lines.append("Subtitle files (read them for more of the dialogue): " + moment.subtitleFiles.joined(separator: ", "))
    }
    if moment.frame != nil {
      lines.append("Attached: the frame on screen at \(timeString(moment.position)), subtitles as displayed.")
    }
    return lines.joined(separator: "\n")
  }
}

// MARK: - Views

class AgentPanelView: NSView {
  weak var controller: AgentPanelController?

  let header = AgentHeaderView()
  let transcript = TranscriptView()
  let composer = ComposerView()
  private let resizeHandle = ResizeHandleView()

  override init(frame: NSRect) {
    super.init(frame: frame)
    appearance = NSAppearance(named: .darkAqua)
    wantsLayer = true
    layer?.backgroundColor = Style.panel.cgColor

    let border = NSView()
    border.wantsLayer = true
    border.layer?.backgroundColor = Style.borderVariant.cgColor

    for subview in [header, transcript, composer, border, resizeHandle] {
      subview.translatesAutoresizingMaskIntoConstraints = false
      addSubview(subview)
    }
    resizeHandle.panel = self
    NSLayoutConstraint.activate([
      border.leadingAnchor.constraint(equalTo: leadingAnchor),
      border.topAnchor.constraint(equalTo: topAnchor),
      border.bottomAnchor.constraint(equalTo: bottomAnchor),
      border.widthAnchor.constraint(equalToConstant: 1),

      resizeHandle.leadingAnchor.constraint(equalTo: leadingAnchor),
      resizeHandle.topAnchor.constraint(equalTo: topAnchor),
      resizeHandle.bottomAnchor.constraint(equalTo: bottomAnchor),
      resizeHandle.widthAnchor.constraint(equalToConstant: 5),

      header.topAnchor.constraint(equalTo: topAnchor),
      header.leadingAnchor.constraint(equalTo: border.trailingAnchor),
      header.trailingAnchor.constraint(equalTo: trailingAnchor),
      header.heightAnchor.constraint(equalToConstant: 38),

      transcript.topAnchor.constraint(equalTo: header.bottomAnchor),
      transcript.leadingAnchor.constraint(equalTo: border.trailingAnchor),
      transcript.trailingAnchor.constraint(equalTo: trailingAnchor),

      composer.topAnchor.constraint(equalTo: transcript.bottomAnchor, constant: 8),
      composer.leadingAnchor.constraint(equalTo: border.trailingAnchor, constant: 10),
      composer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      composer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // The panel is not part of the video surface: keep clicks and scrolls away from the player's
  // mouse actions (pause on click, seek and volume on scroll, window dragging).
  override func mouseDown(with event: NSEvent) {}
  override func mouseDragged(with event: NSEvent) {}
  override func mouseUp(with event: NSEvent) {}
  override func rightMouseDown(with event: NSEvent) {}
  override func rightMouseUp(with event: NSEvent) {}
  override func otherMouseDown(with event: NSEvent) {}
  override func otherMouseUp(with event: NSEvent) {}
  override func scrollWheel(with event: NSEvent) {}
  override func pressureChange(with event: NSEvent) {}
}

/// Drag the panel's inner edge to resize it.
fileprivate class ResizeHandleView: NSView {
  weak var panel: AgentPanelView?

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .resizeLeftRight)
  }

  override func mouseDown(with event: NSEvent) {}

  override func mouseDragged(with event: NSEvent) {
    guard let window, let controller = panel?.controller else { return }
    controller.resize(to: window.frame.width - event.locationInWindow.x)
  }

  override func mouseUp(with event: NSEvent) {
    panel?.controller?.finishResizing()
  }
}

class AgentHeaderView: NSView {
  private let titleLabel = NSTextField(labelWithString: "OMP")
  private let threadLabel = NSTextField(labelWithString: "")
  let newThreadButton = AgentHeaderView.iconButton("plus", tooltip: "New Thread")
  let hideButton = AgentHeaderView.iconButton("sidebar.right", tooltip: "Hide Agent Panel")

  override init(frame: NSRect) {
    super.init(frame: frame)
    titleLabel.font = Style.font(13, bold: true)
    titleLabel.textColor = Style.text
    threadLabel.font = Style.font(12)
    threadLabel.textColor = Style.muted
    threadLabel.lineBreakMode = .byTruncatingTail
    threadLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let stack = NSStackView(views: [titleLabel, threadLabel, NSView(), newThreadButton, hideButton])
    stack.orientation = .horizontal
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)

    let separator = NSView()
    separator.wantsLayer = true
    separator.layer?.backgroundColor = Style.borderVariant.cgColor
    separator.translatesAutoresizingMaskIntoConstraints = false
    addSubview(separator)

    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      stack.centerYAnchor.constraint(equalTo: centerYAnchor),
      separator.leadingAnchor.constraint(equalTo: leadingAnchor),
      separator.trailingAnchor.constraint(equalTo: trailingAnchor),
      separator.bottomAnchor.constraint(equalTo: bottomAnchor),
      separator.heightAnchor.constraint(equalToConstant: 1),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func setThreadTitle(_ title: String?) {
    threadLabel.stringValue = title ?? ""
  }

  static func iconButton(_ symbol: String, tooltip: String) -> NSButton {
    let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) ?? NSImage()
    let button = NSButton(image: image, target: nil, action: nil)
    button.isBordered = false
    button.bezelStyle = .smallSquare
    button.contentTintColor = Style.muted
    button.toolTip = tooltip
    button.symbolConfiguration = .init(pointSize: 13, weight: .regular)
    button.widthAnchor.constraint(equalToConstant: 22).isActive = true
    return button
  }

  // The header sits where the title bar would be, so it moves the window like one.
  override func mouseDown(with event: NSEvent) {
    if event.clickCount == 2 {
      window?.performZoom(nil)
    } else {
      window?.performDrag(with: event)
    }
  }
}

class TranscriptView: NSScrollView {
  private let stack = NSStackView()
  private let emptyLabel = NSTextField(wrappingLabelWithString:
    "Ask about what you're watching.\n\n⌘⇧A focuses the box below and the video keeps playing. "
    + "A question is pinned to the moment you press Return: its position, the subtitles leading up to it "
    + "and the frame on screen.")

  override init(frame: NSRect) {
    super.init(frame: frame)
    drawsBackground = false
    hasVerticalScroller = true
    autohidesScrollers = true
    scrollerStyle = .overlay

    let document = FlippedView()
    document.translatesAutoresizingMaskIntoConstraints = false
    documentView = document
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 12
    stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    stack.translatesAutoresizingMaskIntoConstraints = false
    document.addSubview(stack)
    NSLayoutConstraint.activate([
      document.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      document.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      document.topAnchor.constraint(equalTo: contentView.topAnchor),
      stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
      stack.topAnchor.constraint(equalTo: document.topAnchor),
      stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
    ])

    emptyLabel.font = Style.font(12)
    emptyLabel.textColor = Style.muted
    add(emptyLabel)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func add(_ view: NSView) {
    stack.addArrangedSubview(view)
    view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
  }

  func append(_ view: NSView) {
    emptyLabel.removeFromSuperview()
    add(view)
    contentDidGrow(force: true)
  }

  func clear() {
    stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    add(emptyLabel)
  }

  /// Follow the conversation unless the user scrolled up to read.
  func contentDidGrow(force: Bool = false) {
    guard let document = documentView else { return }
    let clip = contentView.bounds
    let atBottom = clip.maxY >= document.frame.height - 40
    document.layoutSubtreeIfNeeded()
    guard force || atBottom else { return }
    contentView.scroll(to: NSPoint(x: 0, y: max(0, document.frame.height - clip.height)))
    reflectScrolledClipView(contentView)
  }
}

class ComposerView: NSView {
  let textView = ComposerTextView()
  private let textScroll = NSScrollView()
  private var textHeight: NSLayoutConstraint!

  private let frameToggle = AgentHeaderView.iconButton("photo", tooltip: "")
  /// Whether questions carry the frame on screen.
  private(set) var attachesFrame = true

  let modelPopup = NSPopUpButton()
  let thinkingPopup = NSPopUpButton()
  private let costLabel = NSTextField(labelWithString: "")
  let sendButton = NSButton()

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.backgroundColor = Style.editor.cgColor
    layer?.cornerRadius = 6
    layer?.borderWidth = 1
    layer?.borderColor = Style.border.cgColor

    textView.font = Style.font(13)
    textView.textColor = Style.text
    textView.insertionPointColor = Style.accent
    textView.drawsBackground = false
    textView.isRichText = false
    textView.allowsUndo = true
    textView.textContainerInset = .zero
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
    textView.textContainer?.widthTracksTextView = true
    textView.placeholder = "Ask about this moment…"
    textView.onFocusChange = { [unowned self] focused in
      layer?.borderColor = (focused ? Style.borderFocused : Style.border).cgColor
    }
    textScroll.documentView = textView
    textScroll.drawsBackground = false
    textScroll.hasVerticalScroller = true
    textScroll.autohidesScrollers = true
    textScroll.scrollerStyle = .overlay

    frameToggle.target = self
    frameToggle.action = #selector(toggleFrame)
    updateFrameToggle()

    for popup in [modelPopup, thinkingPopup] {
      popup.isBordered = false
      popup.font = Style.font(11)
      popup.controlSize = .small
      popup.isHidden = true
      (popup.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtBottom
    }
    modelPopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    costLabel.font = Style.font(11)
    costLabel.textColor = Style.placeholder

    sendButton.isBordered = false
    sendButton.bezelStyle = .smallSquare
    sendButton.symbolConfiguration = .init(pointSize: 15, weight: .regular)
    sendButton.widthAnchor.constraint(equalToConstant: 22).isActive = true
    setBusy(false)

    let footer = NSStackView(views: [modelPopup, thinkingPopup, NSView(), costLabel, frameToggle, sendButton])
    footer.orientation = .horizontal
    footer.spacing = 6

    let stack = NSStackView(views: [textScroll, footer])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 6
    stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 6, right: 8)
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    textHeight = textScroll.heightAnchor.constraint(equalToConstant: 20)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
      textScroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16),
      footer.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16),
      textHeight,
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /// Grow with the text up to about eight lines.
  func textDidChange() {
    guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
    layoutManager.ensureLayout(for: container)
    let lineHeight = layoutManager.defaultLineHeight(for: Style.font(13))
    let used = layoutManager.usedRect(for: container).height
    textHeight.constant = max(lineHeight, used).clamped(to: lineHeight...(lineHeight * 8))
    textView.needsDisplay = true
  }

  @objc private func toggleFrame() {
    attachesFrame.toggle()
    updateFrameToggle()
  }

  private func updateFrameToggle() {
    frameToggle.contentTintColor = attachesFrame ? Style.accent : Style.placeholder
    frameToggle.toolTip = attachesFrame ? "Questions carry the frame on screen (click to stop)" : "Frames are not sent (click to send them)"
  }

  func setBusy(_ busy: Bool) {
    let symbol = busy ? "stop.circle.fill" : "arrow.up.circle.fill"
    sendButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: busy ? "Stop" : "Send")
    sendButton.contentTintColor = busy ? Style.error : Style.accent
    sendButton.toolTip = busy ? "Stop" : "Send (↩)"
  }

  func setCost(_ amount: Double?) {
    costLabel.stringValue = amount.map { String(format: "$%.2f", $0) } ?? ""
  }
}

class ComposerTextView: NSTextView {
  var onSubmit: (() -> Void)?
  var onEscape: (() -> Void)?
  var onFocusChange: ((Bool) -> Void)?
  var placeholder = ""

  override func keyDown(with event: NSEvent) {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if !hasMarkedText() {
      // Return sends; Shift- or Option-Return inserts a newline.
      if event.keyCode == 36 || event.keyCode == 76, flags.isDisjoint(with: [.shift, .option]) {
        onSubmit?()
        return
      }
      if event.keyCode == 53 {
        onEscape?()
        return
      }
    }
    super.keyDown(with: event)
  }

  override func becomeFirstResponder() -> Bool {
    let became = super.becomeFirstResponder()
    if became { onFocusChange?(true) }
    return became
  }

  override func resignFirstResponder() -> Bool {
    let resigned = super.resignFirstResponder()
    if resigned { onFocusChange?(false) }
    return resigned
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard string.isEmpty else { return }
    let padding = textContainer?.lineFragmentPadding ?? 0
    (placeholder as NSString).draw(
      at: NSPoint(x: textContainerOrigin.x + padding, y: textContainerOrigin.y),
      withAttributes: [.font: Style.font(13), .foregroundColor: Style.placeholder])
  }
}

/// A playback position that seeks there when clicked.
class MomentButton: NSButton {
  var position: Double = 0

  init() {
    super.init(frame: .zero)
    isBordered = false
    bezelStyle = .smallSquare
    toolTip = "Jump to this moment"
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func setLabel(_ text: String) {
    attributedTitle = NSAttributedString(string: text, attributes: [.font: Style.font(12), .foregroundColor: Style.accent])
  }
}

// MARK: - Transcript items

fileprivate func wrappingLabel(_ text: String = "", color: NSColor = Style.text, size: CGFloat = 13) -> NSTextField {
  let label = NSTextField(wrappingLabelWithString: text)
  label.font = Style.font(size)
  label.textColor = color
  label.isSelectable = true
  label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
  return label
}

class UserMessageView: NSView {
  init(_ text: String, moment: AgentMoment?, target: AnyObject, action: Selector) {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = Style.editor.cgColor
    layer?.cornerRadius = 6
    layer?.borderWidth = 1
    layer?.borderColor = Style.borderVariant.cgColor

    var views: [NSView] = [wrappingLabel(text)]
    if let moment {
      let button = MomentButton()
      button.position = moment.position
      button.setLabel("⏱ \(timeString(moment.position))")
      button.target = target
      button.action = action
      var meta: [NSView] = [button]
      if let frame = moment.frame.flatMap(NSImage.init(data:)) {
        let imageView = NSImageView(image: frame)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 3
        imageView.layer?.masksToBounds = true
        imageView.heightAnchor.constraint(equalToConstant: 44).isActive = true
        imageView.widthAnchor.constraint(lessThanOrEqualToConstant: 100).isActive = true
        meta.append(imageView)
      }
      let row = NSStackView(views: meta)
      row.orientation = .horizontal
      row.alignment = .bottom
      row.spacing = 8
      views.append(row)
    }
    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 6
    stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
      views[0].widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}

/// Streams the agent's markdown reply.
class AssistantMessageView: NSView {
  private let label = wrappingLabel()
  private var markdown = ""

  init() {
    super.init(frame: .zero)
    label.allowsEditingTextAttributes = true  // makes links clickable
    label.translatesAutoresizingMaskIntoConstraints = false
    addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: leadingAnchor),
      label.trailingAnchor.constraint(equalTo: trailingAnchor),
      label.topAnchor.constraint(equalTo: topAnchor),
      label.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func append(_ text: String) {
    markdown += text
    label.attributedStringValue = AssistantMessageView.render(markdown)
  }

  /// Inline markdown (bold, italic, code, links) with headings shown bold; block structure such as
  /// lists stays as written.
  static func render(_ markdown: String) -> NSAttributedString {
    let source = markdown.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
      guard let match = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) else { return String(line) }
      let heading = line[match.upperBound...].trimmingCharacters(in: .whitespaces)
      return heading.isEmpty ? String(line) : "**\(heading)**"
    }.joined(separator: "\n")

    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                          failurePolicy: .returnPartiallyParsedIfPossible)
    let parsed = (try? NSAttributedString(markdown: source, options: options)) ?? NSAttributedString(string: markdown)
    let result = NSMutableAttributedString(attributedString: parsed)
    let all = NSRange(location: 0, length: result.length)
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = 3
    result.addAttributes([.font: Style.font(13), .foregroundColor: Style.text, .paragraphStyle: paragraph], range: all)
    result.enumerateAttribute(.inlinePresentationIntent, in: all) { value, range, _ in
      guard let raw = (value as? NSNumber)?.uintValue else { return }
      let intent = InlinePresentationIntent(rawValue: raw)
      if intent.contains(.code) {
        result.addAttributes([.foregroundColor: Style.accent, .backgroundColor: Style.editor], range: range)
      } else {
        let bold = intent.contains(.stronglyEmphasized), italic = intent.contains(.emphasized)
        if bold || italic {
          result.addAttribute(.font, value: Style.font(13, bold: bold, italic: italic), range: range)
        }
      }
    }
    result.enumerateAttribute(.link, in: all) { value, range, _ in
      guard value != nil else { return }
      result.addAttribute(.foregroundColor, value: Style.accent, range: range)
    }
    return result
  }
}

class ToolCallView: NSView {
  private let label = NSTextField(labelWithString: "")
  private var title: String

  init(title: String, status: String?) {
    self.title = title
    super.init(frame: .zero)
    label.font = Style.font(12)
    label.lineBreakMode = .byTruncatingMiddle
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    label.translatesAutoresizingMaskIntoConstraints = false
    addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: leadingAnchor),
      label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
      label.topAnchor.constraint(equalTo: topAnchor),
      label.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
    update(title: nil, status: status)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func update(title: String?, status: String?) {
    if let title, !title.isEmpty { self.title = title }
    let (mark, color): (String, NSColor) = switch status {
    case "completed": ("✓", Style.success)
    case "failed": ("✗", Style.error)
    default: ("○", Style.muted)
    }
    let text = NSMutableAttributedString(string: mark + " ", attributes: [.font: Style.font(12), .foregroundColor: color])
    text.append(NSAttributedString(string: self.title, attributes: [.font: Style.font(12), .foregroundColor: Style.muted]))
    label.attributedStringValue = text
    label.toolTip = self.title
  }
}

class PermissionView: NSView {
  private let reply: (String?) -> Void
  private let buttons: NSStackView

  init(title: String, options: [(id: String, name: String)], reply: @escaping (String?) -> Void) {
    self.reply = reply
    buttons = NSStackView()
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 6
    layer?.borderWidth = 1
    layer?.borderColor = Style.border.cgColor

    let optionButtons = options.enumerated().map { index, option in
      let button = NSButton(title: option.name, target: self, action: #selector(choose(_:)))
      button.controlSize = .small
      button.font = Style.font(11)
      button.tag = index
      button.identifier = NSUserInterfaceItemIdentifier(option.id)
      return button
    }
    // Two per row, so four options fit the panel's width.
    for start in stride(from: 0, to: optionButtons.count, by: 2) {
      let row = NSStackView(views: Array(optionButtons[start..<min(start + 2, optionButtons.count)]))
      row.orientation = .horizontal
      row.spacing = 6
      buttons.addArrangedSubview(row)
    }
    buttons.orientation = .vertical
    buttons.alignment = .leading
    buttons.spacing = 4

    let label = wrappingLabel(title, color: Style.text, size: 12)
    let stack = NSStackView(views: [label, buttons])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 6
    stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
      label.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  @objc private func choose(_ sender: NSButton) {
    reply(sender.identifier?.rawValue)
    let chosen = NSTextField(labelWithString: "→ \(sender.title)")
    chosen.font = Style.font(11)
    chosen.textColor = Style.muted
    buttons.setViews([chosen], in: .leading)
  }
}

class NoticeView: NSView {
  init(_ text: String, color: NSColor) {
    super.init(frame: .zero)
    let label = wrappingLabel(text, color: color, size: 12)
    label.translatesAutoresizingMaskIntoConstraints = false
    addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: leadingAnchor),
      label.trailingAnchor.constraint(equalTo: trailingAnchor),
      label.topAnchor.constraint(equalTo: topAnchor),
      label.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}
