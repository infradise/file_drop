import Cocoa
import FlutterMacOS
import UniformTypeIdentifiers

/// Thread-safe guard ensuring a `FlutterResult` callback is invoked at most once.
private final class SingleShotFlutterResult {
  private let lock = NSLock()
  private var completed = false
  private let callback: FlutterResult

  init(_ callback: @escaping FlutterResult) {
    self.callback = callback
  }

  func send(_ value: Any?) {
    lock.lock()
    if completed {
      lock.unlock()
      return
    }
    completed = true
    lock.unlock()
    callback(value)
  }
}

/// Unified macOS native plugin for `file_drop` providing `NSOpenPanel` /
/// `NSSavePanel` dialogs and `NSDraggingDestination` window drag-and-drop.
public class FileDropPlugin: NSObject, FlutterPlugin {
  private weak var registrar: FlutterPluginRegistrar?
  private let channel: FlutterMethodChannel
  private weak var dropOverlayView: FileDropOverlayView?
  private var frameObserver: NSObjectProtocol?

  init(registrar: FlutterPluginRegistrar, channel: FlutterMethodChannel) {
    self.registrar = registrar
    self.channel = channel
    super.init()
    attachDropOverlayIfNeeded()
    if dropOverlayView == nil {
      DispatchQueue.main.async { [weak self] in
        self?.attachDropOverlayIfNeeded()
      }
    }
  }

  deinit {
    if let observer = frameObserver {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "com.infradise.file_drop",
      binaryMessenger: registrar.messenger
    )
    let instance = FileDropPlugin(registrar: registrar, channel: channel)
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  private func attachDropOverlayIfNeeded() {
    guard let hostView = registrar?.view else {
      return
    }
    if let existing = dropOverlayView {
      if existing.superview === hostView && existing.frame != hostView.bounds {
        existing.frame = hostView.bounds
      }
      return
    }

    hostView.autoresizesSubviews = true
    hostView.postsFrameChangedNotifications = true

    let overlay = FileDropOverlayView(frame: hostView.bounds, channel: channel)
    overlay.translatesAutoresizingMaskIntoConstraints = true
    overlay.autoresizingMask = [.width, .height]
    hostView.addSubview(overlay)
    overlay.frame = hostView.bounds
    dropOverlayView = overlay

    if let previousObserver = frameObserver {
      NotificationCenter.default.removeObserver(previousObserver)
    }
    frameObserver = NotificationCenter.default.addObserver(
      forName: NSView.frameDidChangeNotification,
      object: hostView,
      queue: .main
    ) { [weak hostView, weak overlay] _ in
      guard let hostView = hostView, let overlay = overlay else { return }
      if overlay.frame != hostView.bounds {
        overlay.frame = hostView.bounds
      }
    }
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    attachDropOverlayIfNeeded()
    let safeResult = SingleShotFlutterResult(result)
    let args = call.arguments as? [String: Any] ?? [:]

    switch call.method {
    case "openFile":
      runOnMain {
        self.handleOpenFile(args: args, allowMultiple: false, result: safeResult)
      }
    case "openFiles":
      runOnMain {
        self.handleOpenFile(args: args, allowMultiple: true, result: safeResult)
      }
    case "getSaveLocation":
      runOnMain {
        self.handleSaveLocation(args: args, result: safeResult)
      }
    case "getDirectoryPath":
      runOnMain {
        self.handleOpenDirectory(args: args, allowMultiple: false, result: safeResult)
      }
    case "getDirectoryPaths":
      runOnMain {
        self.handleOpenDirectory(args: args, allowMultiple: true, result: safeResult)
      }
    case "startAccessingSecurityScopedResource":
      handleSecurityScopedAccess(args: args, start: true, result: safeResult)
    case "stopAccessingSecurityScopedResource":
      handleSecurityScopedAccess(args: args, start: false, result: safeResult)
    default:
      safeResult.send(FlutterMethodNotImplemented)
    }
  }

  private func runOnMain(_ block: @escaping () -> Void) {
    if Thread.isMainThread {
      block()
    } else {
      DispatchQueue.main.async(execute: block)
    }
  }

  // MARK: - Native Dialogs (NSOpenPanel & NSSavePanel)

  private func handleOpenFile(
    args: [String: Any],
    allowMultiple: Bool,
    result: SingleShotFlutterResult
  ) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = allowMultiple
    panel.canCreateDirectories = true

    configureBasePanel(panel, args: args)
    applyContentTypeFilters(to: panel, args: args)

    presentOpenPanel(panel) { urls in
      guard let urls = urls else {
        result.send(allowMultiple ? [String]() : nil)
        return
      }
      if allowMultiple {
        result.send(urls.map(\.path))
      } else {
        result.send(urls.first?.path)
      }
    }
  }

  private func handleOpenDirectory(
    args: [String: Any],
    allowMultiple: Bool,
    result: SingleShotFlutterResult
  ) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = allowMultiple
    panel.canCreateDirectories = (args["canCreateDirectories"] as? Bool) ?? true

    configureBasePanel(panel, args: args)

    presentOpenPanel(panel) { urls in
      guard let urls = urls else {
        result.send(allowMultiple ? [String]() : nil)
        return
      }
      if allowMultiple {
        result.send(urls.map(\.path))
      } else {
        result.send(urls.first?.path)
      }
    }
  }

  private func handleSaveLocation(
    args: [String: Any],
    result: SingleShotFlutterResult
  ) {
    let panel = NSSavePanel()
    panel.canCreateDirectories = (args["canCreateDirectories"] as? Bool) ?? true

    configureBasePanel(panel, args: args)
    if let suggestedName = args["suggestedName"] as? String, !suggestedName.isEmpty {
      panel.nameFieldStringValue = suggestedName
    }
    applyContentTypeFilters(to: panel, args: args)

    presentSavePanel(panel) { url in
      guard let url = url else {
        result.send(nil)
        return
      }
      result.send([
        "path": url.path,
        "activeFilterIndex": NSNull(),
      ])
    }
  }

  private func configureBasePanel(_ panel: NSSavePanel, args: [String: Any]) {
    if let initialDirectory = args["initialDirectory"] as? String, !initialDirectory.isEmpty {
      panel.directoryURL = URL(fileURLWithPath: initialDirectory, isDirectory: true)
    }
    if let confirmButtonText = args["confirmButtonText"] as? String, !confirmButtonText.isEmpty {
      panel.prompt = confirmButtonText
    }
  }

  private func applyContentTypeFilters(to panel: NSSavePanel, args: [String: Any]) {
    guard let groups = args["acceptedTypeGroups"] as? [[String: Any]], !groups.isEmpty else {
      panel.allowedContentTypes = []
      panel.allowsOtherFileTypes = true
      return
    }

    var contentTypes: [UTType] = []
    for group in groups {
      let exts = ((group["extensions"] as? [String]) ?? [])
        .map(Self.stripLeadingDots(from:))
        .filter { !$0.isEmpty }
      let utis = ((group["macUTIs"] as? [String])
        ?? (group["uniformTypeIdentifiers"] as? [String])
        ?? [])
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
      let mimes = ((group["mimeTypes"] as? [String]) ?? [])
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

      // If any filter group is an unrestricted wildcard (`allowsAll`), do not
      // restrict file extensions on the panel.
      if exts.isEmpty && utis.isEmpty && mimes.isEmpty {
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        return
      }

      for uti in utis {
        if let resolved = UTType(uti), !contentTypes.contains(resolved) {
          contentTypes.append(resolved)
        }
      }

      for cleaned in exts {
        if let resolved = UTType(filenameExtension: cleaned)
          ?? UTType(filenameExtension: cleaned, conformingTo: .data),
          !contentTypes.contains(resolved)
        {
          contentTypes.append(resolved)
        }
      }

      for mime in mimes {
        if let resolved = UTType(mimeType: mime), !contentTypes.contains(resolved) {
          contentTypes.append(resolved)
        }
      }
    }

    if contentTypes.isEmpty {
      panel.allowedContentTypes = []
      panel.allowsOtherFileTypes = true
    } else {
      panel.allowedContentTypes = contentTypes
      panel.allowsOtherFileTypes = false
    }
  }

  private static func stripLeadingDots(from ext: String) -> String {
    var result = ext.trimmingCharacters(in: .whitespacesAndNewlines)
    if result.hasPrefix("*.") {
      result.removeFirst(2)
    }
    while result.hasPrefix(".") {
      result.removeFirst()
    }
    return result
  }

  private func presentOpenPanel(
    _ panel: NSOpenPanel,
    completion: @escaping ([URL]?) -> Void
  ) {
    if let window = registrar?.view?.window {
      panel.beginSheetModal(for: window) { response in
        completion(response == .OK ? panel.urls : nil)
      }
    } else {
      let response = panel.runModal()
      completion(response == .OK ? panel.urls : nil)
    }
  }

  private func presentSavePanel(
    _ panel: NSSavePanel,
    completion: @escaping (URL?) -> Void
  ) {
    if let window = registrar?.view?.window {
      panel.beginSheetModal(for: window) { response in
        completion(response == .OK ? panel.url : nil)
      }
    } else {
      let response = panel.runModal()
      completion(response == .OK ? panel.url : nil)
    }
  }

  // MARK: - Security-Scoped Bookmarks

  private func handleSecurityScopedAccess(
    args: [String: Any],
    start: Bool,
    result: SingleShotFlutterResult
  ) {
    let typedData = (args["appleBookmark"] as? FlutterStandardTypedData)
      ?? (args["apple-bookmark"] as? FlutterStandardTypedData)
    guard let bookmarkData = typedData?.data, !bookmarkData.isEmpty else {
      result.send(!start)
      return
    }

    var isStale = false
    guard let url = try? URL(
      resolvingBookmarkData: bookmarkData,
      options: [.withSecurityScope],
      relativeTo: nil,
      bookmarkDataIsStale: &isStale
    ) else {
      result.send(false)
      return
    }

    if start {
      result.send(url.startAccessingSecurityScopedResource())
    } else {
      url.stopAccessingSecurityScopedResource()
      result.send(true)
    }
  }
}

/// Transparent, non-intercepting `NSView` overlay that receives macOS
/// `NSDraggingDestination` events without capturing pointer or keyboard input.
private final class FileDropOverlayView: NSView {
  private let channel: FlutterMethodChannel
  private let itemsLock = NSLock()

  private lazy var promiseQueue: OperationQueue = {
    let queue = OperationQueue()
    queue.qualityOfService = .userInitiated
    return queue
  }()

  init(frame frameRect: NSRect, channel: FlutterMethodChannel) {
    self.channel = channel
    super.init(frame: frameRect)

    var draggedTypes = NSFilePromiseReceiver.readableDraggedTypes.map {
      NSPasteboard.PasteboardType($0)
    }
    draggedTypes.append(.fileURL)
    draggedTypes.append(NSPasteboard.PasteboardType("NSFilenamesPboardType"))
    registerForDraggedTypes(draggedTypes)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /// Use top-left `(0, 0)` origin matching Flutter's global coordinate space.
  override var isFlipped: Bool {
    return true
  }

  /// Pass all normal mouse clicks, hovers, scrolls, and gestures directly
  /// through to the underlying `FlutterView`.
  override func hitTest(_ point: NSPoint) -> NSView? {
    return nil
  }

  private func flutterCoordinates(for sender: NSDraggingInfo) -> [String: Double] {
    let localPoint = convert(sender.draggingLocation, from: nil)
    return [
      "x": Double(localPoint.x),
      "y": Double(localPoint.y),
    ]
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    channel.invokeMethod("onDragEntered", arguments: flutterCoordinates(for: sender))
    return .copy
  }

  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    channel.invokeMethod("onDragUpdated", arguments: flutterCoordinates(for: sender))
    return .copy
  }

  override func draggingExited(_ sender: NSDraggingInfo?) {
    if let sender = sender {
      channel.invokeMethod("onDragExited", arguments: flutterCoordinates(for: sender))
    } else {
      channel.invokeMethod("onDragExited", arguments: nil)
    }
  }

  override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
    return true
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    let pasteboard = sender.draggingPasteboard
    let coords = flutterCoordinates(for: sender)
    var items: [[String: Any]] = []
    var seenPaths = Set<String>()
    let dispatchGroup = DispatchGroup()

    func appendItem(url: URL, fromPromise: Bool) {
      let path = url.path
      guard !path.isEmpty else { return }

      itemsLock.lock()
      defer { itemsLock.unlock() }
      guard seenPaths.insert(path).inserted else { return }

      var isDirObj: ObjCBool = false
      let resourceIsDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory
      let isDirectory: Bool
      if let resourceIsDir = resourceIsDir {
        isDirectory = resourceIsDir
      } else if FileManager.default.fileExists(atPath: path, isDirectory: &isDirObj) {
        isDirectory = isDirObj.boolValue
      } else {
        isDirectory = false
      }

      var entry: [String: Any] = [
        "path": path,
        "isDirectory": isDirectory,
        "fromPromise": fromPromise,
      ]

      if !fromPromise,
         let bookmark = try? url.bookmarkData(
           options: [.withSecurityScope],
           includingResourceValuesForKeys: nil,
           relativeTo: nil
         ) {
        entry["appleBookmark"] = FlutterStandardTypedData(bytes: bookmark)
      }

      items.append(entry)
    }

    let fileURLs = (pasteboard.readObjects(
      forClasses: [NSURL.self],
      options: [.urlReadingFileURLsOnly: true]
    ) as? [URL]) ?? []

    let legacyPaths = (pasteboard.propertyList(
      forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")
    ) as? [String]) ?? []

    if !fileURLs.isEmpty || !legacyPaths.isEmpty {
      for url in fileURLs {
        appendItem(url: url, fromPromise: false)
      }
      for legacyPath in legacyPaths {
        appendItem(url: URL(fileURLWithPath: legacyPath), fromPromise: false)
      }
    } else if let receivers = pasteboard.readObjects(
      forClasses: [NSFilePromiseReceiver.self],
      options: nil
    ) as? [NSFilePromiseReceiver], !receivers.isEmpty {
      let dropFolder = makeTemporaryDropDirectory()
      for receiver in receivers {
        dispatchGroup.enter()
        receiver.receivePromisedFiles(
          atDestination: dropFolder,
          options: [:],
          operationQueue: promiseQueue
        ) { url, error in
          defer { dispatchGroup.leave() }
          if error == nil {
            appendItem(url: url, fromPromise: true)
          }
        }
      }
    }

    dispatchGroup.notify(queue: .main) {
      let payload: [String: Any] = [
        "x": coords["x"] ?? 0.0,
        "y": coords["y"] ?? 0.0,
        "items": items,
      ]
      self.channel.invokeMethod("onDragDone", arguments: payload)
    }

    return true
  }

  private func makeTemporaryDropDirectory() -> URL {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("file_drop_promises", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(
      at: base,
      withIntermediateDirectories: true,
      attributes: nil
    )
    return base
  }
}

