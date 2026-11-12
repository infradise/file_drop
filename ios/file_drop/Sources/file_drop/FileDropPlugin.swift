import Flutter
import UIKit
import UniformTypeIdentifiers

/// Thread-safe guard ensuring a `FlutterResult` callback is invoked at most once
/// on the main thread.
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
    if Thread.isMainThread {
      callback(value)
    } else {
      DispatchQueue.main.async { [callback] in
        callback(value)
      }
    }
  }
}

/// Weak wrapper used to track `UIView` instances that already host a drop interaction.
private final class WeakViewBox {
  weak var view: UIView?

  init(_ view: UIView) {
    self.view = view
  }
}

/// Thread-safe registry tracking active security-scoped `URL` resources on iOS.
private final class SecurityScopedRegistry {
  private struct Entry {
    let url: URL
    var count: Int
  }

  private let lock = NSLock()
  private var entries: [String: Entry] = [:]

  @discardableResult
  func startAccess(for url: URL) -> Bool {
    let key = url.standardizedFileURL.path
    lock.lock()
    defer { lock.unlock() }
    if var existing = entries[key] {
      existing.count += 1
      entries[key] = existing
      return true
    }
    let granted = url.startAccessingSecurityScopedResource()
    if granted {
      entries[key] = Entry(url: url, count: 1)
    }
    return granted
  }

  func stopAccess(for url: URL) {
    let key = url.standardizedFileURL.path
    lock.lock()
    defer { lock.unlock() }
    guard var existing = entries[key] else {
      url.stopAccessingSecurityScopedResource()
      return
    }
    existing.count -= 1
    if existing.count <= 0 {
      entries.removeValue(forKey: key)
      existing.url.stopAccessingSecurityScopedResource()
    } else {
      entries[key] = existing
    }
  }

  func releaseAll() {
    lock.lock()
    let current = entries.values
    entries.removeAll()
    lock.unlock()
    for entry in current {
      entry.url.stopAccessingSecurityScopedResource()
    }
  }
}

/// Coordinates a single `UIDocumentPickerViewController` presentation, handling
/// both explicit cancellation (`documentPickerWasCancelled`) and interactive
/// sheet swipe-to-dismiss (`presentationControllerDidDismiss`).
private final class DocumentPickerSession: NSObject,
  UIDocumentPickerDelegate,
  UIAdaptivePresentationControllerDelegate
{
  enum Mode {
    case openSingle
    case openMultiple
    case directorySingle
    case directoryMultiple
    case saveExport(stagingDirectory: URL)
  }

  private let mode: Mode
  private let result: SingleShotFlutterResult
  private let ioQueue: DispatchQueue
  private let securityRegistry: SecurityScopedRegistry
  private let copyPickedFile: (URL, URL, Int) -> String?
  private let makePickerBatchDirectory: () -> URL
  private let onFinish: () -> Void
  private let finishLock = NSLock()
  private var cleanedUp = false

  init(
    mode: Mode,
    result: SingleShotFlutterResult,
    ioQueue: DispatchQueue,
    securityRegistry: SecurityScopedRegistry,
    makePickerBatchDirectory: @escaping () -> URL,
    copyPickedFile: @escaping (URL, URL, Int) -> String?,
    onFinish: @escaping () -> Void
  ) {
    self.mode = mode
    self.result = result
    self.ioQueue = ioQueue
    self.securityRegistry = securityRegistry
    self.makePickerBatchDirectory = makePickerBatchDirectory
    self.copyPickedFile = copyPickedFile
    self.onFinish = onFinish
    super.init()
  }

  func documentPicker(
    _ controller: UIDocumentPickerViewController,
    didPickDocumentsAt urls: [URL]
  ) {
    switch mode {
    case .openSingle:
      ioQueue.async { [weak self] in
        guard let self = self else { return }
        defer { self.cleanupOnce() }
        guard let first = urls.first else {
          self.result.send(nil)
          return
        }
        let batchDir = self.makePickerBatchDirectory()
        let copiedPath = self.copyPickedFile(first, batchDir, 0)
        self.result.send(copiedPath)
      }

    case .openMultiple:
      ioQueue.async { [weak self] in
        guard let self = self else { return }
        defer { self.cleanupOnce() }
        if urls.isEmpty {
          self.result.send([String]())
          return
        }
        let batchDir = self.makePickerBatchDirectory()
        var copiedPaths: [String] = []
        copiedPaths.reserveCapacity(urls.count)
        for (index, url) in urls.enumerated() {
          if let path = self.copyPickedFile(url, batchDir, index) {
            copiedPaths.append(path)
          }
        }
        self.result.send(copiedPaths)
      }

    case .directorySingle:
      defer { cleanupOnce() }
      guard let first = urls.first else {
        result.send(nil)
        return
      }
      _ = securityRegistry.startAccess(for: first)
      result.send(first.path)

    case .directoryMultiple:
      defer { cleanupOnce() }
      var paths: [String] = []
      paths.reserveCapacity(urls.count)
      for url in urls {
        _ = securityRegistry.startAccess(for: url)
        if !url.path.isEmpty {
          paths.append(url.path)
        }
      }
      result.send(paths)

    case .saveExport:
      let exportedPath = urls.first?.path
      cleanupOnce()
      if let exportedPath = exportedPath, !exportedPath.isEmpty {
        result.send(exportedPath)
      } else {
        result.send(nil)
      }
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    handleCancellation()
  }

  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    handleCancellation()
  }

  func handleCancellation() {
    cleanupOnce()
    switch mode {
    case .openMultiple, .directoryMultiple:
      result.send([String]())
    case .openSingle, .directorySingle, .saveExport:
      result.send(nil)
    }
  }

  private func cleanupOnce() {
    finishLock.lock()
    if cleanedUp {
      finishLock.unlock()
      return
    }
    cleanedUp = true
    finishLock.unlock()

    if case let .saveExport(stagingDirectory) = mode {
      ioQueue.async {
        try? FileManager.default.removeItem(at: stagingDirectory)
      }
    }
    if Thread.isMainThread {
      onFinish()
    } else {
      DispatchQueue.main.async { [onFinish] in
        onFinish()
      }
    }
  }
}

/// Unified iOS / iPadOS native plugin for `file_drop` providing
/// `UIDocumentPickerViewController` dialogs and `UIDropInteractionDelegate`
/// drag-and-drop with zero external dependencies.
public class FileDropPlugin: NSObject, FlutterPlugin, UIDropInteractionDelegate {
  private static let channelName = "com.infradise.file_drop"
  private static let tempRootFolderName = "com.infradise.file_drop"

  private let channel: FlutterMethodChannel
  private let ioQueue = DispatchQueue(
    label: "com.infradise.file_drop.io",
    qos: .userInitiated,
    attributes: .concurrent
  )
  private let securityRegistry = SecurityScopedRegistry()
  private var activePickerSession: DocumentPickerSession?
  private var attachedViews: [WeakViewBox] = []
  private var observers: [NSObjectProtocol] = []
  private var isHoveringDragSession = false

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
    registerLifecycleObservers()
    DispatchQueue.main.async { [weak self] in
      self?.attachDropInteractionsIfNeeded()
    }
  }

  deinit {
    for observer in observers {
      NotificationCenter.default.removeObserver(observer)
    }
    securityRegistry.releaseAll()
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    let instance = FileDropPlugin(channel: channel)
    registrar.addMethodCallDelegate(instance, channel: channel)
    registrar.addApplicationDelegate(instance)
  }

  public func applicationDidBecomeActive(_ application: UIApplication) {
    attachDropInteractionsIfNeeded()
  }

  private func registerLifecycleObservers() {
    let center = NotificationCenter.default
    observers.append(
      center.addObserver(
        forName: UIScene.didActivateNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.attachDropInteractionsIfNeeded()
      }
    )
    observers.append(
      center.addObserver(
        forName: UIWindow.didBecomeKeyNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.attachDropInteractionsIfNeeded()
      }
    )
  }

  private func attachDropInteractionsIfNeeded() {
    attachedViews.removeAll { $0.view == nil }
    for scene in UIApplication.shared.connectedScenes {
      guard let windowScene = scene as? UIWindowScene else { continue }
      for window in windowScene.windows where !window.isHidden {
        let targetView = resolveFlutterHostView(in: window)
        guard let hostView = targetView else { continue }
        if attachedViews.contains(where: { $0.view === hostView }) {
          continue
        }
        let interaction = UIDropInteraction(delegate: self)
        interaction.allowsSimultaneousDropSessions = true
        hostView.addInteraction(interaction)
        attachedViews.append(WeakViewBox(hostView))
      }
    }
  }

  private func resolveFlutterHostView(in window: UIWindow) -> UIView? {
    if let flutterVC = findFlutterViewController(from: window.rootViewController) {
      return flutterVC.view
    }
    return window.rootViewController?.view
  }

  private func findFlutterViewController(from controller: UIViewController?) -> FlutterViewController? {
    guard let controller = controller else { return nil }
    if let flutterVC = controller as? FlutterViewController {
      return flutterVC
    }
    for child in controller.children {
      if let found = findFlutterViewController(from: child) {
        return found
      }
    }
    if let nav = controller as? UINavigationController {
      for vc in nav.viewControllers {
        if let found = findFlutterViewController(from: vc) {
          return found
        }
      }
    }
    if let tab = controller as? UITabBarController, let vcs = tab.viewControllers {
      for vc in vcs {
        if let found = findFlutterViewController(from: vc) {
          return found
        }
      }
    }
    return nil
  }

  // MARK: - MethodChannel Handling

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    attachDropInteractionsIfNeeded()
    let safeResult = SingleShotFlutterResult(result)
    let args = call.arguments as? [String: Any]

    switch call.method {
    case "openFile":
      handleOpenFiles(arguments: args, allowMultiple: false, result: safeResult)
    case "openFiles":
      handleOpenFiles(arguments: args, allowMultiple: true, result: safeResult)
    case "getDirectoryPath", "openDirectory":
      handleOpenDirectories(arguments: args, allowMultiple: false, result: safeResult)
    case "getDirectoryPaths":
      handleOpenDirectories(arguments: args, allowMultiple: true, result: safeResult)
    case "saveFile":
      handleSaveFile(arguments: args, result: safeResult)
    case "clearTemporaryFiles":
      handleClearTemporaryFiles(result: safeResult)
    case "releaseDropSession":
      handleReleaseDropSession(arguments: args, result: safeResult)
    case "startAccessingSecurityScopedResource":
      safeResult.send(handleSecurityScope(arguments: args, start: true))
    case "stopAccessingSecurityScopedResource":
      safeResult.send(handleSecurityScope(arguments: args, start: false))
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Top ViewController Resolution

  private func topPresentingViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let orderedScenes = scenes.sorted { lhs, rhs in
      scenePriority(lhs.activationState) < scenePriority(rhs.activationState)
    }

    var rootController: UIViewController?
    for scene in orderedScenes {
      if let keyWindow = scene.windows.first(where: { $0.isKeyWindow && $0.rootViewController != nil }) {
        rootController = keyWindow.rootViewController
        break
      }
      if let visibleWindow = scene.windows.first(where: { !$0.isHidden && $0.rootViewController != nil }) {
        rootController = visibleWindow.rootViewController
        break
      }
    }

    guard var top = rootController else {
      return nil
    }
    while let presented = top.presentedViewController, !presented.isBeingDismissed {
      top = presented
    }
    return top
  }

  private func scenePriority(_ state: UIScene.ActivationState) -> Int {
    switch state {
    case .foregroundActive:
      return 0
    case .foregroundInactive:
      return 1
    case .background:
      return 2
    case .unattached:
      return 3
    @unknown default:
      return 4
    }
  }

  // MARK: - UIDocumentPickerViewController Dialogs

  private func handleOpenFiles(
    arguments: [String: Any]?,
    allowMultiple: Bool,
    result: SingleShotFlutterResult
  ) {
    let contentTypes = resolveAllowedContentTypes(from: arguments)
    let initialDirectory = arguments?["initialDirectory"] as? String

    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      guard self.activePickerSession == nil else {
        result.send(
          FlutterError(
            code: "PENDING_OPERATION",
            message: "Another document picker dialog is already active.",
            details: nil
          )
        )
        return
      }
      guard let presenter = self.topPresentingViewController() else {
        result.send(
          FlutterError(
            code: "NO_VIEW_CONTROLLER",
            message: "Unable to locate an active UIViewController to present UIDocumentPickerViewController.",
            details: nil
          )
        )
        return
      }

      let picker = UIDocumentPickerViewController(
        forOpeningContentTypes: contentTypes,
        asCopy: true
      )
      picker.allowsMultipleSelection = allowMultiple
      if let dirPath = initialDirectory, !dirPath.isEmpty {
        picker.directoryURL = URL(fileURLWithPath: dirPath, isDirectory: true)
      }

      let session = DocumentPickerSession(
        mode: allowMultiple ? .openMultiple : .openSingle,
        result: result,
        ioQueue: self.ioQueue,
        securityRegistry: self.securityRegistry,
        makePickerBatchDirectory: { [weak self] in
          self?.makeSubdirectory(category: "picker", id: UUID().uuidString)
            ?? FileManager.default.temporaryDirectory
        },
        copyPickedFile: { [weak self] sourceURL, batchDir, index in
          self?.stageFileToDirectory(sourceURL: sourceURL, batchDirectory: batchDir, index: index)?.path
        },
        onFinish: { [weak self] in
          self?.activePickerSession = nil
        }
      )
      self.activePickerSession = session
      picker.delegate = session
      picker.presentationController?.delegate = session
      presenter.present(picker, animated: true) {
        picker.presentationController?.delegate = session
      }
    }
  }

  private func handleOpenDirectories(
    arguments: [String: Any]?,
    allowMultiple: Bool,
    result: SingleShotFlutterResult
  ) {
    let initialDirectory = arguments?["initialDirectory"] as? String

    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      guard self.activePickerSession == nil else {
        result.send(
          FlutterError(
            code: "PENDING_OPERATION",
            message: "Another document picker dialog is already active.",
            details: nil
          )
        )
        return
      }
      guard let presenter = self.topPresentingViewController() else {
        result.send(
          FlutterError(
            code: "NO_VIEW_CONTROLLER",
            message: "Unable to locate an active UIViewController to present UIDocumentPickerViewController.",
            details: nil
          )
        )
        return
      }

      let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
      picker.allowsMultipleSelection = allowMultiple
      if let dirPath = initialDirectory, !dirPath.isEmpty {
        picker.directoryURL = URL(fileURLWithPath: dirPath, isDirectory: true)
      }

      let session = DocumentPickerSession(
        mode: allowMultiple ? .directoryMultiple : .directorySingle,
        result: result,
        ioQueue: self.ioQueue,
        securityRegistry: self.securityRegistry,
        makePickerBatchDirectory: { FileManager.default.temporaryDirectory },
        copyPickedFile: { _, _, _ in nil },
        onFinish: { [weak self] in
          self?.activePickerSession = nil
        }
      )
      self.activePickerSession = session
      picker.delegate = session
      picker.presentationController?.delegate = session
      presenter.present(picker, animated: true) {
        picker.presentationController?.delegate = session
      }
    }
  }

  private func handleSaveFile(
    arguments: [String: Any]?,
    result: SingleShotFlutterResult
  ) {
    let typedBytes = arguments?["bytes"] as? FlutterStandardTypedData
    let rawData = typedBytes?.data ?? Data()
    let rawSuggested = arguments?["suggestedName"] as? String
    var suggestedName = Self.sanitizeFileName(rawSuggested, fallback: "untitled")
    if let mimeType = (arguments?["mimeType"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
      !mimeType.isEmpty,
      (suggestedName as NSString).pathExtension.isEmpty,
      let ext = UTType(mimeType: mimeType)?.preferredFilenameExtension
    {
      suggestedName = "\(suggestedName).\(ext)"
    }
    let initialDirectory = arguments?["initialDirectory"] as? String

    ioQueue.async { [weak self] in
      guard let self = self else { return }
      let stagingDir = self.makeSubdirectory(category: "export", id: UUID().uuidString)
      let stagedFileURL = stagingDir.appendingPathComponent(suggestedName, isDirectory: false)
      do {
        try rawData.write(to: stagedFileURL, options: .atomic)
      } catch {
        try? FileManager.default.removeItem(at: stagingDir)
        result.send(
          FlutterError(
            code: "EXPORT_STAGE_FAILED",
            message: "Failed to write temporary export file: \(error.localizedDescription)",
            details: nil
          )
        )
        return
      }

      DispatchQueue.main.async { [weak self] in
        guard let self = self else {
          try? FileManager.default.removeItem(at: stagingDir)
          return
        }
        guard self.activePickerSession == nil else {
          try? FileManager.default.removeItem(at: stagingDir)
          result.send(
            FlutterError(
              code: "PENDING_OPERATION",
              message: "Another document picker dialog is already active.",
              details: nil
            )
          )
          return
        }
        guard let presenter = self.topPresentingViewController() else {
          try? FileManager.default.removeItem(at: stagingDir)
          result.send(
            FlutterError(
              code: "NO_VIEW_CONTROLLER",
              message: "Unable to locate an active UIViewController to present UIDocumentPickerViewController.",
              details: nil
            )
          )
          return
        }

        let picker = UIDocumentPickerViewController(
          forExporting: [stagedFileURL],
          asCopy: true
        )
        if let dirPath = initialDirectory, !dirPath.isEmpty {
          picker.directoryURL = URL(fileURLWithPath: dirPath, isDirectory: true)
        }

        let session = DocumentPickerSession(
          mode: .saveExport(stagingDirectory: stagingDir),
          result: result,
          ioQueue: self.ioQueue,
          securityRegistry: self.securityRegistry,
          makePickerBatchDirectory: { stagingDir },
          copyPickedFile: { _, _, _ in nil },
          onFinish: { [weak self] in
            self?.activePickerSession = nil
          }
        )
        self.activePickerSession = session
        picker.delegate = session
        picker.presentationController?.delegate = session
        presenter.present(picker, animated: true) {
          picker.presentationController?.delegate = session
        }
      }
    }
  }

  // MARK: - Temporary Cache & Session Lifecycle

  private func handleClearTemporaryFiles(result: SingleShotFlutterResult) {
    ioQueue.async { [weak self] in
      guard let self = self else { return }
      let root = self.temporaryRootDirectory(createIfMissing: false)
      let fm = FileManager.default
      if fm.fileExists(atPath: root.path) {
        do {
          try fm.removeItem(at: root)
        } catch {
          result.send(false)
          return
        }
      }
      result.send(true)
    }
  }

  private func handleReleaseDropSession(
    arguments: [String: Any]?,
    result: SingleShotFlutterResult
  ) {
    guard let rawSessionId = arguments?["sessionId"] as? String, !rawSessionId.isEmpty else {
      result.send(nil)
      return
    }
    let cleanId = Self.sanitizeIdentifier(rawSessionId)
    guard !cleanId.isEmpty else {
      result.send(nil)
      return
    }
    ioQueue.async { [weak self] in
      guard let self = self else { return }
      let sessionDir = self.temporaryRootDirectory(createIfMissing: false)
        .appendingPathComponent("drops", isDirectory: true)
        .appendingPathComponent(cleanId, isDirectory: true)
      if FileManager.default.fileExists(atPath: sessionDir.path) {
        try? FileManager.default.removeItem(at: sessionDir)
      }
      result.send(nil)
    }
  }

  // MARK: - Security-Scoped Bookmarks (iOS-Compatible Options)

  private func handleSecurityScope(arguments: [String: Any]?, start: Bool) -> Bool {
    guard let args = arguments else {
      return false
    }
    let typed = (args["appleBookmark"] as? FlutterStandardTypedData)
      ?? (args["apple-bookmark"] as? FlutterStandardTypedData)
    guard let bookmarkData = typed?.data, !bookmarkData.isEmpty else {
      return false
    }
    var isStale = false
    guard let url = try? URL(
      resolvingBookmarkData: bookmarkData,
      options: [],
      relativeTo: nil,
      bookmarkDataIsStale: &isStale
    ) else {
      return false
    }
    if start {
      return securityRegistry.startAccess(for: url)
    } else {
      securityRegistry.stopAccess(for: url)
      return true
    }
  }

  // MARK: - UTType Filter Mapping

  private func resolveAllowedContentTypes(from arguments: [String: Any]?) -> [UTType] {
    guard let rawGroups = arguments?["acceptedTypeGroups"] as? [[String: Any]],
          !rawGroups.isEmpty
    else {
      return [.item]
    }

    var resolved: [UTType] = []
    var seen = Set<String>()

    func appendType(_ type: UTType?) {
      guard let type = type else { return }
      if seen.insert(type.identifier).inserted {
        resolved.append(type)
      }
    }

    for group in rawGroups {
      if (group["allowsAll"] as? Bool) == true {
        return [.item]
      }
      let utis = (group["uniformTypeIdentifiers"] as? [String] ?? [])
        + (group["macUTIs"] as? [String] ?? [])
      let extensions = group["extensions"] as? [String] ?? []
      let mimeTypes = group["mimeTypes"] as? [String] ?? []

      if utis.isEmpty && extensions.isEmpty && mimeTypes.isEmpty {
        return [.item]
      }

      for uti in utis {
        let trimmed = uti.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
          appendType(UTType(trimmed))
        }
      }

      for ext in extensions {
        let clean = Self.stripLeadingDots(ext)
        if clean == "*" {
          return [.item]
        }
        if !clean.isEmpty {
          appendType(UTType(filenameExtension: clean))
        }
      }

      for mime in mimeTypes {
        let trimmed = mime.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch trimmed {
        case "", "*/*":
          return [.item]
        case "image/*":
          appendType(.image)
        case "video/*":
          appendType(.movie)
        case "audio/*":
          appendType(.audio)
        case "text/*":
          appendType(.text)
        default:
          appendType(UTType(mimeType: trimmed))
        }
      }
    }

    return resolved.isEmpty ? [.item] : resolved
  }

  // MARK: - UIDropInteractionDelegate (iOS / iPadOS Drag-and-Drop)

  public func dropInteraction(
    _ interaction: UIDropInteraction,
    canHandle session: UIDropSession
  ) -> Bool {
    return !session.items.isEmpty
  }

  public func dropInteraction(
    _ interaction: UIDropInteraction,
    sessionDidEnter session: UIDropSession
  ) {
    isHoveringDragSession = true
    let point = dropLocation(for: session, in: interaction)
    let payload: [String: Any] = [
      "x": Double(point.x),
      "y": Double(point.y),
      "offer": buildHoverOffer(for: session),
    ]
    channel.invokeMethod("onDragEntered", arguments: payload)
  }

  public func dropInteraction(
    _ interaction: UIDropInteraction,
    sessionDidUpdate session: UIDropSession
  ) -> UIDropProposal {
    if !isHoveringDragSession {
      isHoveringDragSession = true
    }
    let point = dropLocation(for: session, in: interaction)
    let payload: [String: Any] = [
      "x": Double(point.x),
      "y": Double(point.y),
      "offer": buildHoverOffer(for: session),
    ]
    channel.invokeMethod("onDragUpdated", arguments: payload)
    return UIDropProposal(operation: .copy)
  }

  public func dropInteraction(
    _ interaction: UIDropInteraction,
    sessionDidExit session: UIDropSession
  ) {
    guard isHoveringDragSession else { return }
    isHoveringDragSession = false
    let point = dropLocation(for: session, in: interaction)
    channel.invokeMethod(
      "onDragExited",
      arguments: [
        "x": Double(point.x),
        "y": Double(point.y),
      ]
    )
  }

  public func dropInteraction(
    _ interaction: UIDropInteraction,
    sessionDidEnd session: UIDropSession
  ) {
    guard isHoveringDragSession else { return }
    isHoveringDragSession = false
    channel.invokeMethod(
      "onDragExited",
      arguments: [
        "x": 0.0,
        "y": 0.0,
      ]
    )
  }

  public func dropInteraction(
    _ interaction: UIDropInteraction,
    performDrop session: UIDropSession
  ) {
    isHoveringDragSession = false
    let point = dropLocation(for: session, in: interaction)
    let sessionId = UUID().uuidString
    let dropBatchDir = makeSubdirectory(category: "drops", id: sessionId)

    let dragItems = session.items
    let itemCount = dragItems.count
    if itemCount == 0 {
      channel.invokeMethod(
        "onDragDone",
        arguments: [
          "x": Double(point.x),
          "y": Double(point.y),
          "sessionId": sessionId,
          "items": [[String: Any]](),
        ]
      )
      return
    }

    let slotLock = NSLock()
    var orderedSlots = Array<[[String: Any]]>(repeating: [], count: itemCount)
    var firstRawText: String?
    let group = DispatchGroup()

    func storeEntry(_ entry: [String: Any], at index: Int, rawTextCandidate: String? = nil) {
      slotLock.lock()
      orderedSlots[index].append(entry)
      if firstRawText == nil, let raw = rawTextCandidate, !raw.isEmpty {
        firstRawText = raw
      }
      slotLock.unlock()
    }

    for (index, dragItem) in dragItems.enumerated() {
      let provider = dragItem.itemProvider
      let classification = classifyItemProvider(provider)

      switch classification {
      case .directory(let typeIdentifier):
        group.enter()
        provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { [weak self] tempURL, _ in
          defer { group.leave() }
          guard let self = self, let tempURL = tempURL else { return }
          if let copiedURL = self.stageFileToDirectory(
            sourceURL: tempURL,
            batchDirectory: dropBatchDir,
            index: index,
            suggestedNameOverride: provider.suggestedName
          ) {
            var map: [String: Any] = [
              "path": copiedURL.path,
              "name": copiedURL.lastPathComponent,
              "isDirectory": true,
              "isPromised": false,
            ]
            if let bookmark = try? copiedURL.bookmarkData(
              options: .minimalBookmark,
              includingResourceValuesForKeys: nil,
              relativeTo: nil
            ) {
              map["appleBookmark"] = FlutterStandardTypedData(bytes: bookmark)
            }
            storeEntry(map, at: index)
          }
        }

      case .file(let typeIdentifier):
        group.enter()
        provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { [weak self] tempURL, _ in
          defer { group.leave() }
          guard let self = self, let tempURL = tempURL else { return }
          if let copiedURL = self.stageFileToDirectory(
            sourceURL: tempURL,
            batchDirectory: dropBatchDir,
            index: index,
            suggestedNameOverride: provider.suggestedName
          ) {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: copiedURL.path, isDirectory: &isDir)
            let resolvedMime = UTType(typeIdentifier)?.preferredMIMEType
              ?? UTType(filenameExtension: copiedURL.pathExtension)?.preferredMIMEType
            var map: [String: Any] = [
              "path": copiedURL.path,
              "name": copiedURL.lastPathComponent,
              "isDirectory": isDir.boolValue,
              "isPromised": false,
            ]
            if let mime = resolvedMime {
              map["mimeType"] = mime
            }
            if let bookmark = try? copiedURL.bookmarkData(
              options: .minimalBookmark,
              includingResourceValuesForKeys: nil,
              relativeTo: nil
            ) {
              map["appleBookmark"] = FlutterStandardTypedData(bytes: bookmark)
            }
            storeEntry(map, at: index)
          }
        }

      case .url(let typeIdentifier):
        group.enter()
        provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { [weak self] data, _ in
          defer { group.leave() }
          guard let data = data else { return }
          let url = URL(dataRepresentation: data, relativeTo: nil)
            ?? String(data: data, encoding: .utf8)
              .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
              .flatMap { URL(string: $0) }
          guard let resolvedURL = url else { return }
          if resolvedURL.isFileURL, let self = self,
             let copiedURL = self.stageFileToDirectory(
               sourceURL: resolvedURL,
               batchDirectory: dropBatchDir,
               index: index,
               suggestedNameOverride: provider.suggestedName
             )
          {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: copiedURL.path, isDirectory: &isDir)
            var map: [String: Any] = [
              "path": copiedURL.path,
              "name": copiedURL.lastPathComponent,
              "isDirectory": isDir.boolValue,
            ]
            if let mime = UTType(filenameExtension: copiedURL.pathExtension)?.preferredMIMEType {
              map["mimeType"] = mime
            }
            storeEntry(map, at: index)
          } else {
            let text = resolvedURL.absoluteString
            storeEntry(
              [
                "kind": "string",
                "mimeType": "text/uri-list",
                "value": text,
              ],
              at: index,
              rawTextCandidate: text
            )
          }
        }

      case .string(let typeIdentifier):
        group.enter()
        provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
          defer { group.leave() }
          guard let data = data,
                let text = String(data: data, encoding: .utf8)
                  ?? String(data: data, encoding: .utf16)
          else {
            return
          }
          storeEntry(
            [
              "kind": "string",
              "mimeType": "text/plain",
              "value": text,
            ],
            at: index,
            rawTextCandidate: text
          )
        }
      }
    }

    group.notify(queue: .main) { [weak self] in
      guard let self = self else { return }
      let flattened = orderedSlots.flatMap { $0 }
      var payload: [String: Any] = [
        "x": Double(point.x),
        "y": Double(point.y),
        "sessionId": sessionId,
        "items": flattened,
      ]
      if let rawText = firstRawText {
        payload["rawText"] = rawText
      }
      self.channel.invokeMethod("onDragDone", arguments: payload)
    }
  }

  // MARK: - Provider Classification & Hover Previews

  private enum ProviderKind {
    case directory(String)
    case file(String)
    case url(String)
    case string(String)
  }

  private func classifyItemProvider(_ provider: NSItemProvider) -> ProviderKind {
    let identifiers = provider.registeredTypeIdentifiers
    for id in identifiers {
      if let type = UTType(id), type.conforms(to: .folder) || type.conforms(to: .directory) {
        return .directory(id)
      }
    }

    // Prefer concrete file/media/document content types before generic URL or text representations.
    for id in identifiers {
      guard let type = UTType(id) else { continue }
      if type == .fileURL {
        return .file(id)
      }
      let isTextOrWebURL = type.conforms(to: .plainText)
        || (type.conforms(to: .url) && !type.conforms(to: .fileURL))
      if !isTextOrWebURL && (type.conforms(to: .content) || type.conforms(to: .data) || type.conforms(to: .item)) {
        return .file(id)
      }
    }

    if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
      return .file(UTType.fileURL.identifier)
    }
    if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
      return .url(UTType.url.identifier)
    }
    if provider.hasItemConformingToTypeIdentifier(UTType.utf8PlainText.identifier) {
      return .string(UTType.utf8PlainText.identifier)
    }
    if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
      return .string(UTType.plainText.identifier)
    }
    if let first = identifiers.first {
      return .file(first)
    }
    return .file(UTType.item.identifier)
  }

  private func buildHoverOffer(for session: UIDropSession) -> [String: Any] {
    var itemPreviews: [[String: Any]] = []
    var stringPreviews: [[String: Any]] = []

    for dragItem in session.items {
      let provider = dragItem.itemProvider
      switch classifyItemProvider(provider) {
      case .directory:
        var entry: [String: Any] = [
          "isDirectory": true,
          "isPromised": false,
        ]
        if let name = provider.suggestedName, !name.isEmpty {
          entry["name"] = name
        }
        itemPreviews.append(entry)

      case .file(let identifier):
        var entry: [String: Any] = [
          "isDirectory": false,
          "isPromised": false,
        ]
        if let name = provider.suggestedName, !name.isEmpty {
          entry["name"] = name
        }
        if let mime = UTType(identifier)?.preferredMIMEType {
          entry["mimeType"] = mime
        }
        itemPreviews.append(entry)

      case .url:
        stringPreviews.append(["mimeType": "text/uri-list"])

      case .string:
        stringPreviews.append(["mimeType": "text/plain"])
      }
    }

    return [
      "items": itemPreviews,
      "strings": stringPreviews,
      "isComplete": true,
      "allowedOperations": ["copy"],
    ]
  }

  private func dropLocation(
    for session: UIDropSession,
    in interaction: UIDropInteraction
  ) -> CGPoint {
    if let view = interaction.view {
      return session.location(in: view)
    }
    if let firstView = attachedViews.compactMap({ $0.view }).first {
      return session.location(in: firstView)
    }
    return .zero
  }

  // MARK: - File Staging & Sanitization Helpers

  private func temporaryRootDirectory(createIfMissing: Bool = true) -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(Self.tempRootFolderName, isDirectory: true)
    if createIfMissing {
      try? FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true,
        attributes: nil
      )
    }
    return root
  }

  private func makeSubdirectory(category: String, id: String) -> URL {
    let dir = temporaryRootDirectory(createIfMissing: true)
      .appendingPathComponent(category, isDirectory: true)
      .appendingPathComponent(Self.sanitizeIdentifier(id), isDirectory: true)
    try? FileManager.default.createDirectory(
      at: dir,
      withIntermediateDirectories: true,
      attributes: nil
    )
    return dir
  }

  private func stageFileToDirectory(
    sourceURL: URL,
    batchDirectory: URL,
    index: Int,
    suggestedNameOverride: String? = nil
  ) -> URL? {
    let accessed = sourceURL.startAccessingSecurityScopedResource()
    defer {
      if accessed {
        sourceURL.stopAccessingSecurityScopedResource()
      }
    }

    let sourceName = sourceURL.lastPathComponent
    let rawName: String
    if !sourceName.isEmpty {
      rawName = sourceName
    } else if let suggested = suggestedNameOverride, !suggested.isEmpty {
      let ext = sourceURL.pathExtension
      if !ext.isEmpty && !suggested.lowercased().hasSuffix(".\(ext.lowercased())") {
        rawName = "\(suggested).\(ext)"
      } else {
        rawName = suggested
      }
    } else {
      rawName = "item_\(index)"
    }

    let safeName = Self.sanitizeFileName(rawName, fallback: "item_\(index)")
    let slotDir = batchDirectory.appendingPathComponent("\(index)", isDirectory: true)
    let fm = FileManager.default
    do {
      try fm.createDirectory(at: slotDir, withIntermediateDirectories: true, attributes: nil)
      let destURL = slotDir.appendingPathComponent(safeName)
      if fm.fileExists(atPath: destURL.path) {
        try fm.removeItem(at: destURL)
      }
      try fm.copyItem(at: sourceURL, to: destURL)
      return destURL
    } catch {
      return nil
    }
  }

  private static func sanitizeFileName(_ rawName: String?, fallback: String) -> String {
    guard let rawName = rawName else { return fallback }
    var cleaned = rawName
      .replacingOccurrences(of: "\0", with: "_")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "\\", with: "_")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    while cleaned.hasPrefix("..") {
      cleaned = String(cleaned.dropFirst(2))
        .trimmingCharacters(in: CharacterSet(charactersIn: "._ "))
    }
    cleaned = cleaned.replacingOccurrences(of: "..", with: "_")
    if cleaned.isEmpty || cleaned == "." || cleaned == "_" {
      return fallback
    }
    return cleaned
  }

  private static func sanitizeIdentifier(_ raw: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    let filtered = raw.unicodeScalars.filter { allowed.contains($0) }
    return String(String.UnicodeScalarView(filtered))
  }

  private static func stripLeadingDots(_ ext: String) -> String {
    var trimmed = ext.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if trimmed.hasPrefix("*.") {
      trimmed.removeFirst(2)
    } else {
      while trimmed.hasPrefix(".") {
        trimmed.removeFirst()
      }
    }
    return trimmed
  }
}

