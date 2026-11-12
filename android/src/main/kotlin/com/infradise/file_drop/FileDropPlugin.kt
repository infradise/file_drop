package com.infradise.file_drop

import android.app.Activity
import android.content.ClipData
import android.content.ClipDescription
import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.view.DragAndDropPermissions
import android.view.DragEvent
import android.view.View
import android.view.ViewGroup
import android.webkit.MimeTypeMap
import io.flutter.embedding.android.FlutterView
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.lang.ref.WeakReference
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Zero-dependency Android native plugin (`minSdk = 24`) for `file_drop`.
 *
 * Implements Storage Access Framework (SAF) file/directory dialogs, content URI
 * streaming/enumeration, and multi-window / tablet / DeX drag-and-drop via pure
 * Android SDK APIs (`android.*`) with zero `androidx.*` or third-party Maven
 * dependencies.
 */
class FileDropPlugin :
  FlutterPlugin,
  MethodCallHandler,
  ActivityAware,
  PluginRegistry.ActivityResultListener,
  View.OnDragListener {

  private class SingleShotResult(
    private val mainHandler: Handler,
    private val delegate: Result,
  ) {
    private val completed = AtomicBoolean(false)

    fun success(value: Any?) {
      if (completed.compareAndSet(false, true)) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
          delegate.success(value)
        } else {
          mainHandler.post { delegate.success(value) }
        }
      }
    }

    fun error(code: String, message: String?, details: Any?) {
      if (completed.compareAndSet(false, true)) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
          delegate.error(code, message, details)
        } else {
          mainHandler.post { delegate.error(code, message, details) }
        }
      }
    }

    fun notImplemented() {
      if (completed.compareAndSet(false, true)) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
          delegate.notImplemented()
        } else {
          mainHandler.post { delegate.notImplemented() }
        }
      }
    }
  }

  private data class PendingPickerRequest(
    val requestCode: Int,
    val result: SingleShotResult,
    val saveBytes: ByteArray? = null,
    val fallbackName: String? = null,
  )

  private data class DropItemSnapshot(
    val uri: Uri?,
    val text: String?,
  )

  private val mainHandler = Handler(Looper.getMainLooper())
  private val requestLock = Any()
  private val activeDropSessions = ConcurrentHashMap<String, DragAndDropPermissions>()

  private var applicationContext: Context? = null
  private var channel: MethodChannel? = null
  private var executor: ExecutorService? = null
  private var activityBinding: ActivityPluginBinding? = null
  private var activity: Activity? = null
  private var attachedDragViewRef: WeakReference<View>? = null
  private var pendingRequest: PendingPickerRequest? = null

  private var currentDragOffer: Map<String, Any?>? = null
  private var isDragInside = false

  override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
    applicationContext = flutterPluginBinding.applicationContext
    executor = Executors.newCachedThreadPool()
    val methodChannel = MethodChannel(flutterPluginBinding.binaryMessenger, CHANNEL_NAME)
    methodChannel.setMethodCallHandler(this)
    channel = methodChannel
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    detachDragListener()
    cancelPendingRequest("DETACHED", "FlutterEngine detached while dialog was pending.")
    releaseAllDropSessions()
    channel?.setMethodCallHandler(null)
    channel = null
    executor?.shutdown()
    executor = null
    applicationContext = null
  }

  // MARK: - ActivityAware Lifecycle

  override fun onAttachedToActivity(binding: ActivityPluginBinding) {
    bindActivity(binding)
  }

  override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
    bindActivity(binding)
  }

  override fun onDetachedFromActivityForConfigChanges() {
    detachDragListener()
    activityBinding?.removeActivityResultListener(this)
    activityBinding = null
    activity = null
  }

  override fun onDetachedFromActivity() {
    detachDragListener()
    activityBinding?.removeActivityResultListener(this)
    activityBinding = null
    activity = null
    cancelPendingRequest("ACTIVITY_DETACHED", "Activity detached before picker completed.")
  }

  private fun bindActivity(binding: ActivityPluginBinding) {
    activityBinding?.removeActivityResultListener(this)
    activityBinding = binding
    activity = binding.activity
    binding.addActivityResultListener(this)
    attachDragListenerIfNeeded()
    mainHandler.post { attachDragListenerIfNeeded() }
  }

  private fun attachDragListenerIfNeeded() {
    val currentActivity = activity ?: return
    val decorView = currentActivity.window?.decorView ?: return
    val targetView = findFlutterView(decorView)
      ?: currentActivity.findViewById<View>(android.R.id.content)
      ?: decorView
    val existing = attachedDragViewRef?.get()
    if (existing === targetView) {
      return
    }
    existing?.setOnDragListener(null)
    targetView.setOnDragListener(this)
    attachedDragViewRef = WeakReference(targetView)
  }

  private fun detachDragListener() {
    attachedDragViewRef?.get()?.setOnDragListener(null)
    attachedDragViewRef = null
    isDragInside = false
    currentDragOffer = null
  }

  private fun findFlutterView(root: View): FlutterView? {
    if (root is FlutterView) {
      return root
    }
    if (root is ViewGroup) {
      for (i in 0 until root.childCount) {
        val found = findFlutterView(root.getChildAt(i))
        if (found != null) {
          return found
        }
      }
    }
    return null
  }

  // MARK: - MethodCallHandler

  override fun onMethodCall(call: MethodCall, result: Result) {
    attachDragListenerIfNeeded()
    val safeResult = SingleShotResult(mainHandler, result)

    when (call.method) {
      "openFile" -> launchOpenDocument(call, safeResult, allowMultiple = false)
      "openFiles" -> launchOpenDocument(call, safeResult, allowMultiple = true)
      "saveFile" -> launchSaveDocument(call, safeResult)
      "openDirectory" -> launchOpenDirectory(call, safeResult, returnMetadataMap = true)
      "getDirectoryPath" -> launchOpenDirectory(call, safeResult, returnMetadataMap = false)
      "getDirectoryPaths" -> safeResult.error(
        "UNSUPPORTED",
        "Android ACTION_OPEN_DOCUMENT_TREE supports selecting a single directory only.",
        null,
      )
      "requestDirectoryAccess" -> launchRequestDirectoryAccess(call, safeResult)
      "readContentUri" -> handleReadContentUri(call, safeResult)
      "statContentUri" -> handleStatContentUri(call, safeResult)
      "writeContentUri" -> handleWriteContentUri(call, safeResult)
      "listDirectory" -> handleListDirectory(call, safeResult)
      "clearTemporaryFiles" -> handleClearTemporaryFiles(safeResult)
      "releaseDropSession" -> handleReleaseDropSession(call, safeResult)
      "startAccessingSecurityScopedResource" -> safeResult.success(false)
      "stopAccessingSecurityScopedResource" -> safeResult.success(true)
      else -> safeResult.notImplemented()
    }
  }

  // MARK: - SAF Picker & Export Intents

  private fun launchOpenDocument(
    call: MethodCall,
    result: SingleShotResult,
    allowMultiple: Boolean,
  ) {
    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
      addCategory(Intent.CATEGORY_OPENABLE)
      putExtra(Intent.EXTRA_ALLOW_MULTIPLE, allowMultiple)
    }

    val mimeFilters = resolveMimeFilters(call.argument<List<Map<*, *>>>("acceptedTypeGroups"))
    when {
      mimeFilters.isEmpty() -> intent.type = "*/*"
      mimeFilters.size == 1 -> intent.type = mimeFilters.first()
      else -> {
        intent.type = "*/*"
        intent.putExtra(Intent.EXTRA_MIME_TYPES, mimeFilters.toTypedArray())
      }
    }

    applyInitialUriExtra(intent, call.argument<String>("initialDirectory"))
    val requestCode = if (allowMultiple) REQ_OPEN_FILES else REQ_OPEN_FILE
    startPickerRequest(PendingPickerRequest(requestCode = requestCode, result = result), intent)
  }

  private fun launchSaveDocument(call: MethodCall, result: SingleShotResult) {
    val bytes = call.argument<ByteArray>("bytes") ?: ByteArray(0)
    val rawSuggestedName = call.argument<String>("suggestedName")
    val explicitMimeType = call.argument<String>("mimeType")
    val safeTitle = sanitizeFileName(rawSuggestedName, fallback = "download")
    val groups = call.argument<List<Map<*, *>>>("acceptedTypeGroups")
    val saveMime = resolveSaveMimeType(explicitMimeType, rawSuggestedName, groups)

    val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
      addCategory(Intent.CATEGORY_OPENABLE)
      type = saveMime
      putExtra(Intent.EXTRA_TITLE, safeTitle)
    }
    applyInitialUriExtra(intent, call.argument<String>("initialDirectory"))

    startPickerRequest(
      PendingPickerRequest(
        requestCode = REQ_SAVE_FILE,
        result = result,
        saveBytes = bytes,
      ),
      intent,
    )
  }

  private fun launchOpenDirectory(
    call: MethodCall,
    result: SingleShotResult,
    returnMetadataMap: Boolean,
  ) {
    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
      addFlags(
        Intent.FLAG_GRANT_READ_URI_PERMISSION or
          Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
          Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
          Intent.FLAG_GRANT_PREFIX_URI_PERMISSION,
      )
    }
    applyInitialUriExtra(intent, call.argument<String>("initialDirectory"))
    val requestCode = if (returnMetadataMap) REQ_OPEN_DIRECTORY else REQ_GET_DIRECTORY_PATH
    startPickerRequest(PendingPickerRequest(requestCode = requestCode, result = result), intent)
  }

  private fun launchRequestDirectoryAccess(call: MethodCall, result: SingleShotResult) {
    val rawUri = call.argument<String>("uri") ?: call.argument<String>("path")
    val fallbackName = call.argument<String>("name")
    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
      addFlags(
        Intent.FLAG_GRANT_READ_URI_PERMISSION or
          Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
          Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
          Intent.FLAG_GRANT_PREFIX_URI_PERMISSION,
      )
    }
    applyInitialUriExtra(intent, rawUri)
    startPickerRequest(
      PendingPickerRequest(
        requestCode = REQ_REQUEST_DIR_ACCESS,
        result = result,
        fallbackName = fallbackName,
      ),
      intent,
    )
  }

  @Suppress("DEPRECATION")
  private fun startPickerRequest(request: PendingPickerRequest, intent: Intent) {
    val currentActivity = activity
    if (currentActivity == null) {
      request.result.error(
        "NO_ACTIVITY",
        "FileDropPlugin requires an attached foreground Activity.",
        null,
      )
      return
    }
    synchronized(requestLock) {
      if (pendingRequest != null) {
        request.result.error(
          "PENDING_OPERATION",
          "Another file or directory dialog is already active.",
          null,
        )
        return
      }
      pendingRequest = request
    }

    try {
      currentActivity.startActivityForResult(intent, request.requestCode)
    } catch (e: Exception) {
      synchronized(requestLock) {
        if (pendingRequest === request) {
          pendingRequest = null
        }
      }
      request.result.error(
        "ACTIVITY_LAUNCH_FAILED",
        "Failed to launch system document picker: ${e.message}",
        null,
      )
    }
  }

  private fun cancelPendingRequest(code: String, message: String) {
    val active: PendingPickerRequest?
    synchronized(requestLock) {
      active = pendingRequest
      pendingRequest = null
    }
    active?.result?.error(code, message, null)
  }

  // MARK: - ActivityResultListener

  override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
    val request: PendingPickerRequest = synchronized(requestLock) {
      val current = pendingRequest
      if (current == null || current.requestCode != requestCode) {
        return false
      }
      pendingRequest = null
      current
    }

    val context = applicationContext
    if (context == null) {
      request.result.error("NO_CONTEXT", "Application context is unavailable.", null)
      return true
    }

    if (resultCode != Activity.RESULT_OK || data == null) {
      when (requestCode) {
        REQ_OPEN_FILES -> request.result.success(emptyList<String>())
        REQ_REQUEST_DIR_ACCESS -> request.result.error(
          "directory_access_denied",
          "User cancelled directory access prompt.",
          null,
        )
        else -> request.result.success(null)
      }
      return true
    }

    when (requestCode) {
      REQ_OPEN_FILE -> {
        val uri = extractSelectedUris(data).firstOrNull()
        if (uri == null) {
          request.result.success(null)
          return true
        }
        runInBackground(request.result) {
          val batchDir = makeCacheSubdirectory(context, "picker", UUID.randomUUID().toString())
          val copied = copyContentUriToFile(context, uri, batchDir, 0, "picked_file")
          request.result.success(copied?.absolutePath)
        }
      }

      REQ_OPEN_FILES -> {
        val uris = extractSelectedUris(data)
        if (uris.isEmpty()) {
          request.result.success(emptyList<String>())
          return true
        }
        runInBackground(request.result) {
          val batchDir = makeCacheSubdirectory(context, "picker", UUID.randomUUID().toString())
          val paths = ArrayList<String>(uris.size)
          for ((index, uri) in uris.withIndex()) {
            val copied = copyContentUriToFile(context, uri, batchDir, index, "picked_file_$index")
            if (copied != null) {
              paths.add(copied.absolutePath)
            }
          }
          request.result.success(paths)
        }
      }

      REQ_SAVE_FILE -> {
        val targetUri = data.data
        if (targetUri == null) {
          request.result.success(null)
          return true
        }
        val payload = request.saveBytes ?: ByteArray(0)
        runInBackground(request.result) {
          writeBytesToContentUri(context.contentResolver, targetUri, payload)
          request.result.success(targetUri.toString())
        }
      }

      REQ_OPEN_DIRECTORY -> {
        val treeUri = data.data
        if (treeUri == null) {
          request.result.success(null)
          return true
        }
        runInBackground(request.result) {
          takePersistableTreePermission(context.contentResolver, treeUri)
          val folderName = queryDisplayName(context, treeUri)
            ?: extractUriSegmentName(treeUri)
          request.result.success(
            mapOf(
              "uri" to treeUri.toString(),
              "name" to folderName,
              "isContentUri" to true,
            ),
          )
        }
      }

      REQ_GET_DIRECTORY_PATH -> {
        val treeUri = data.data
        if (treeUri == null) {
          request.result.success(null)
          return true
        }
        runInBackground(request.result) {
          takePersistableTreePermission(context.contentResolver, treeUri)
          request.result.success(treeUri.toString())
        }
      }

      REQ_REQUEST_DIR_ACCESS -> {
        val treeUri = data.data
        if (treeUri == null) {
          request.result.error(
            "directory_access_denied",
            "No directory URI returned by system picker.",
            null,
          )
          return true
        }
        runInBackground(request.result) {
          takePersistableTreePermission(context.contentResolver, treeUri)
          val folderName = queryDisplayName(context, treeUri)
            ?: request.fallbackName?.takeIf { it.isNotBlank() }
            ?: extractUriSegmentName(treeUri)
          request.result.success(
            mapOf(
              "uri" to treeUri.toString(),
              "name" to folderName,
              "isContentUri" to true,
            ),
          )
        }
      }
    }

    return true
  }

  // MARK: - SAF Content URI Operations

  private fun handleReadContentUri(call: MethodCall, result: SingleShotResult) {
    val context = applicationContext
    val rawUri = call.argument<String>("uri")
    if (context == null || rawUri.isNullOrEmpty()) {
      result.error("INVALID_URI", "Missing content URI for readContentUri.", null)
      return
    }
    val startArg = (call.argument<Number>("start"))?.toLong()
    val endArg = (call.argument<Number>("end"))?.toLong()

    runInBackground(result) {
      val uri = Uri.parse(rawUri)
      val bytes = context.contentResolver.openInputStream(uri)?.use { stream ->
        readStreamSlice(stream, startArg, endArg)
      } ?: throw IllegalStateException("Unable to open InputStream for $rawUri")
      result.success(bytes)
    }
  }

  private fun handleStatContentUri(call: MethodCall, result: SingleShotResult) {
    val context = applicationContext
    val rawUri = call.argument<String>("uri")
    if (context == null || rawUri.isNullOrEmpty()) {
      result.success(mapOf("exists" to false, "length" to 0L, "lastModified" to 0L))
      return
    }

    runInBackground(result) {
      val uri = Uri.parse(rawUri)
      val queryUri = resolveQueryableDocumentUri(context, uri)
      var exists = false
      var byteLength = 0L
      var lastModified = 0L

      val projection = arrayOf(
        OpenableColumns.SIZE,
        DocumentsContract.Document.COLUMN_LAST_MODIFIED,
      )
      try {
        context.contentResolver.query(queryUri, projection, null, null, null)?.use { cursor ->
          if (cursor.moveToFirst()) {
            exists = true
            val sizeIdx = cursor.getColumnIndex(OpenableColumns.SIZE)
            if (sizeIdx >= 0 && !cursor.isNull(sizeIdx)) {
              byteLength = cursor.getLong(sizeIdx)
            }
            val modIdx = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_LAST_MODIFIED)
            if (modIdx >= 0 && !cursor.isNull(modIdx)) {
              lastModified = cursor.getLong(modIdx)
            }
          }
        }
      } catch (_: Exception) {
        exists = false
      }

      if (!exists && DocumentsContract.isTreeUri(uri)) {
        // Fallback probe when a provider omits root row metadata for a valid tree URI.
        try {
          val docId = DocumentsContract.getTreeDocumentId(uri)
          val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(uri, docId)
          context.contentResolver.query(
            childrenUri,
            arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID),
            null,
            null,
            null,
          )?.use {
            exists = true
          }
        } catch (_: Exception) {
          exists = false
        }
      }

      result.success(
        mapOf(
          "exists" to exists,
          "length" to byteLength,
          "lastModified" to lastModified,
        ),
      )
    }
  }

  private fun handleWriteContentUri(call: MethodCall, result: SingleShotResult) {
    val context = applicationContext
    val rawUri = call.argument<String>("uri")
    val bytes = call.argument<ByteArray>("bytes") ?: ByteArray(0)
    if (context == null || rawUri.isNullOrEmpty()) {
      result.error("INVALID_URI", "Missing content URI for writeContentUri.", null)
      return
    }

    runInBackground(result) {
      val uri = Uri.parse(rawUri)
      writeBytesToContentUri(context.contentResolver, uri, bytes)
      result.success(null)
    }
  }

  private fun handleListDirectory(call: MethodCall, result: SingleShotResult) {
    val context = applicationContext
    val rawUri = call.argument<String>("uri") ?: call.argument<String>("path")
    if (context == null || rawUri.isNullOrEmpty()) {
      result.error("INVALID_URI", "Missing directory URI for listDirectory.", null)
      return
    }

    runInBackground(result) {
      val uri = Uri.parse(rawUri)
      if (!DocumentsContract.isTreeUri(uri)) {
        result.error(
          "directory_access_required",
          "Directory access permission is required on Android.",
          rawUri,
        )
        return@runInBackground
      }

      val parentDocId = try {
        if (DocumentsContract.isDocumentUri(context, uri)) {
          DocumentsContract.getDocumentId(uri)
        } else {
          DocumentsContract.getTreeDocumentId(uri)
        }
      } catch (_: IllegalArgumentException) {
        result.error(
          "directory_access_required",
          "Directory access permission is required on Android.",
          rawUri,
        )
        return@runInBackground
      }

      val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(uri, parentDocId)
      val projection = arrayOf(
        DocumentsContract.Document.COLUMN_DOCUMENT_ID,
        DocumentsContract.Document.COLUMN_DISPLAY_NAME,
        DocumentsContract.Document.COLUMN_MIME_TYPE,
        DocumentsContract.Document.COLUMN_SIZE,
        DocumentsContract.Document.COLUMN_LAST_MODIFIED,
      )

      val entries = ArrayList<Map<String, Any?>>()
      try {
        val cursor = context.contentResolver.query(childrenUri, projection, null, null, null)
        if (cursor == null) {
          result.error(
            "directory_access_required",
            "Directory access permission is required on Android.",
            rawUri,
          )
          return@runInBackground
        }
        cursor.use { c ->
          val idIndex = c.getColumnIndex(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
          val nameIndex = c.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
          val mimeIndex = c.getColumnIndex(DocumentsContract.Document.COLUMN_MIME_TYPE)
          val sizeIndex = c.getColumnIndex(DocumentsContract.Document.COLUMN_SIZE)
          val modIndex = c.getColumnIndex(DocumentsContract.Document.COLUMN_LAST_MODIFIED)

          while (c.moveToNext()) {
            if (idIndex < 0 || c.isNull(idIndex)) {
              continue
            }
            val childDocId = c.getString(idIndex)
            val childUri = DocumentsContract.buildDocumentUriUsingTree(uri, childDocId)
            val displayName = if (nameIndex >= 0 && !c.isNull(nameIndex)) {
              c.getString(nameIndex)
            } else {
              extractUriSegmentName(childUri)
            }
            val mimeType = if (mimeIndex >= 0 && !c.isNull(mimeIndex)) {
              c.getString(mimeIndex)
            } else {
              null
            }
            val size = if (sizeIndex >= 0 && !c.isNull(sizeIndex)) c.getLong(sizeIndex) else null
            val modified = if (modIndex >= 0 && !c.isNull(modIndex)) c.getLong(modIndex) else null
            val isDirectory = mimeType == DocumentsContract.Document.MIME_TYPE_DIR

            entries.add(
              mapOf(
                "uri" to childUri.toString(),
                "path" to childUri.toString(),
                "name" to displayName,
                "mimeType" to mimeType,
                "length" to size,
                "lastModified" to modified,
                "isDirectory" to isDirectory,
                "isContentUri" to true,
              ),
            )
          }
        }
      } catch (_: SecurityException) {
        result.error(
          "directory_access_required",
          "Directory access permission is required on Android.",
          rawUri,
        )
        return@runInBackground
      }

      result.success(entries)
    }
  }

  private fun handleClearTemporaryFiles(result: SingleShotResult) {
    val context = applicationContext
    if (context == null) {
      result.success(false)
      return
    }
    runInBackground(result) {
      val root = File(context.cacheDir, CACHE_ROOT_DIR_NAME)
      val deleted = if (root.exists()) root.deleteRecursively() else true
      result.success(deleted)
    }
  }

  private fun handleReleaseDropSession(call: MethodCall, result: SingleShotResult) {
    val rawSessionId = call.argument<String>("sessionId")
    if (rawSessionId.isNullOrEmpty()) {
      result.success(null)
      return
    }
    val permissions = activeDropSessions.remove(rawSessionId)
    try {
      permissions?.release()
    } catch (_: Throwable) {
      // Ignore release failures if already revoked by the OS.
    }

    val context = applicationContext
    val cleanId = sanitizeIdentifier(rawSessionId)
    if (context == null || cleanId.isEmpty()) {
      result.success(null)
      return
    }
    runInBackground(result) {
      val dropDir = File(File(context.cacheDir, CACHE_ROOT_DIR_NAME), "drops/$cleanId")
      if (dropDir.exists()) {
        dropDir.deleteRecursively()
      }
      result.success(null)
    }
  }

  private fun releaseAllDropSessions() {
    val keys = activeDropSessions.keys().toList()
    for (key in keys) {
      val perm = activeDropSessions.remove(key)
      try {
        perm?.release()
      } catch (_: Throwable) {
        // Ignore on shutdown.
      }
    }
  }

  // MARK: - View.OnDragListener (Multi-Window / Tablet / DeX Drag-and-Drop)

  override fun onDrag(view: View, event: DragEvent): Boolean {
    val density = view.resources.displayMetrics.density.let { if (it > 0f) it else 1f }
    val logicalX = (event.x / density).toDouble()
    val logicalY = (event.y / density).toDouble()

    return when (event.action) {
      DragEvent.ACTION_DRAG_STARTED -> {
        currentDragOffer = buildHoverOffer(event.clipDescription)
        true
      }

      DragEvent.ACTION_DRAG_ENTERED -> {
        isDragInside = true
        val offer = currentDragOffer ?: buildHoverOffer(event.clipDescription).also {
          currentDragOffer = it
        }
        channel?.invokeMethod(
          "onDragEntered",
          mapOf(
            "x" to logicalX,
            "y" to logicalY,
            "offer" to offer,
          ),
        )
        true
      }

      DragEvent.ACTION_DRAG_LOCATION -> {
        if (!isDragInside) {
          isDragInside = true
        }
        val offer = currentDragOffer ?: buildHoverOffer(event.clipDescription).also {
          currentDragOffer = it
        }
        channel?.invokeMethod(
          "onDragUpdated",
          mapOf(
            "x" to logicalX,
            "y" to logicalY,
            "offer" to offer,
          ),
        )
        true
      }

      DragEvent.ACTION_DRAG_EXITED -> {
        if (isDragInside) {
          isDragInside = false
          channel?.invokeMethod(
            "onDragExited",
            mapOf(
              "x" to logicalX,
              "y" to logicalY,
            ),
          )
        }
        true
      }

      DragEvent.ACTION_DRAG_ENDED -> {
        currentDragOffer = null
        if (isDragInside) {
          isDragInside = false
          channel?.invokeMethod(
            "onDragExited",
            mapOf(
              "x" to 0.0,
              "y" to 0.0,
            ),
          )
        }
        true
      }

      DragEvent.ACTION_DROP -> {
        isDragInside = false
        currentDragOffer = null
        handleDropEvent(event, logicalX, logicalY)
      }

      else -> false
    }
  }

  private fun handleDropEvent(event: DragEvent, logicalX: Double, logicalY: Double): Boolean {
    val context = applicationContext ?: return false
    val clipData = event.clipData ?: return false
    if (clipData.itemCount <= 0) {
      return false
    }

    val sessionId = UUID.randomUUID().toString()
    val permissions: DragAndDropPermissions? = try {
      activity?.requestDragAndDropPermissions(event)
    } catch (_: Throwable) {
      null
    }
    if (permissions != null) {
      activeDropSessions[sessionId] = permissions
    }

    val snapshots = ArrayList<DropItemSnapshot>(clipData.itemCount)
    for (i in 0 until clipData.itemCount) {
      val item = clipData.getItemAt(i)
      snapshots.add(
        DropItemSnapshot(
          uri = item.uri,
          text = item.text?.toString(),
        ),
      )
    }

    val bgExecutor = executor
    if (bgExecutor == null || bgExecutor.isShutdown) {
      activeDropSessions.remove(sessionId)?.release()
      return false
    }

    bgExecutor.execute {
      val dropBatchDir = makeCacheSubdirectory(context, "drops", sessionId)
      val itemsPayload = ArrayList<Map<String, Any?>>(snapshots.size)
      var rawText: String? = null

      for ((index, snapshot) in snapshots.withIndex()) {
        val uri = snapshot.uri
        if (uri != null) {
          val scheme = uri.scheme?.lowercase()
          if (scheme == "http" || scheme == "https") {
            val urlString = uri.toString()
            if (rawText == null) {
              rawText = urlString
            }
            itemsPayload.add(
              mapOf(
                "kind" to "string",
                "mimeType" to "text/uri-list",
                "value" to urlString,
              ),
            )
            continue
          }

          if (scheme == "file") {
            val path = uri.path
            if (!path.isNullOrEmpty()) {
              val localFile = File(path)
              itemsPayload.add(
                mapOf(
                  "path" to localFile.absolutePath,
                  "name" to localFile.name,
                  "isDirectory" to localFile.isDirectory,
                  "isContentUri" to false,
                ),
              )
              continue
            }
          }

          if (isDirectoryContentUri(context, uri)) {
            val dirName = queryDisplayName(context, uri) ?: extractUriSegmentName(uri)
            itemsPayload.add(
              mapOf(
                "uri" to uri.toString(),
                "path" to uri.toString(),
                "name" to dirName,
                "isDirectory" to true,
                "isContentUri" to true,
              ),
            )
            continue
          }

          val mimeType = try {
            context.contentResolver.getType(uri)
          } catch (_: Exception) {
            null
          }
          val copiedFile = copyContentUriToFile(
            context,
            uri,
            dropBatchDir,
            index,
            "dropped_file_$index",
          )
          if (copiedFile != null) {
            itemsPayload.add(
              mapOf(
                "path" to copiedFile.absolutePath,
                "name" to copiedFile.name,
                "mimeType" to mimeType,
                "isDirectory" to false,
                "isContentUri" to false,
              ),
            )
          } else {
            val fallbackName = sanitizeFileName(
              queryDisplayName(context, uri),
              fallback = "dropped_file_$index",
            )
            itemsPayload.add(
              mapOf(
                "uri" to uri.toString(),
                "path" to uri.toString(),
                "name" to fallbackName,
                "mimeType" to mimeType,
                "isDirectory" to false,
                "isContentUri" to true,
              ),
            )
          }
        } else if (snapshot.text != null) {
          if (rawText == null) {
            rawText = snapshot.text
          }
          itemsPayload.add(
            mapOf(
              "kind" to "string",
              "mimeType" to "text/plain",
              "value" to snapshot.text,
            ),
          )
        }
      }

      mainHandler.post {
        val activeChannel = channel
        if (activeChannel == null) {
          activeDropSessions.remove(sessionId)?.release()
          executor?.execute { dropBatchDir.deleteRecursively() }
          return@post
        }
        val payload = HashMap<String, Any?>()
        payload["x"] = logicalX
        payload["y"] = logicalY
        payload["sessionId"] = sessionId
        payload["items"] = itemsPayload
        if (rawText != null) {
          payload["rawText"] = rawText
        }
        activeChannel.invokeMethod("onDragDone", payload)
      }
    }

    return true
  }

  private fun buildHoverOffer(description: ClipDescription?): Map<String, Any?> {
    if (description == null || description.mimeTypeCount <= 0) {
      return mapOf(
        "items" to listOf(mapOf("isDirectory" to false, "isPromised" to false)),
        "strings" to emptyList<Map<String, Any?>>(),
        "isComplete" to false,
        "allowedOperations" to listOf("copy"),
      )
    }

    val itemPreviews = ArrayList<Map<String, Any?>>()
    val stringPreviews = ArrayList<Map<String, Any?>>()

    for (i in 0 until description.mimeTypeCount) {
      val mime = description.getMimeType(i) ?: continue
      when {
        mime == DocumentsContract.Document.MIME_TYPE_DIR -> {
          itemPreviews.add(mapOf("isDirectory" to true, "isPromised" to false))
        }
        mime == ClipDescription.MIMETYPE_TEXT_PLAIN ||
          mime == ClipDescription.MIMETYPE_TEXT_HTML ||
          mime == ClipDescription.MIMETYPE_TEXT_URILIST -> {
          stringPreviews.add(mapOf("mimeType" to mime))
        }
        mime != ClipDescription.MIMETYPE_TEXT_INTENT -> {
          itemPreviews.add(
            mapOf(
              "mimeType" to mime,
              "isDirectory" to false,
              "isPromised" to false,
            ),
          )
        }
      }
    }

    // When a file manager advertises both a concrete file MIME type and a generic URI list,
    // keep the file preview primary so file-only targets accept the hover cleanly.
    if (itemPreviews.isNotEmpty()) {
      stringPreviews.removeAll { it["mimeType"] == ClipDescription.MIMETYPE_TEXT_URILIST }
    }

    return mapOf(
      "items" to itemPreviews,
      "strings" to stringPreviews,
      "isComplete" to false,
      "allowedOperations" to listOf("copy"),
    )
  }

  // MARK: - Helpers & Traversal Sanitization

  private fun runInBackground(result: SingleShotResult, task: () -> Unit) {
    val bg = executor
    if (bg == null || bg.isShutdown) {
      result.error("ENGINE_DETACHED", "Background executor is no longer active.", null)
      return
    }
    bg.execute {
      try {
        task()
      } catch (se: SecurityException) {
        result.error("SECURITY_ERROR", se.message, null)
      } catch (e: Exception) {
        result.error("IO_ERROR", e.message, null)
      }
    }
  }

  private fun extractSelectedUris(data: Intent): List<Uri> {
    val result = ArrayList<Uri>()
    val clipData: ClipData? = data.clipData
    if (clipData != null && clipData.itemCount > 0) {
      for (i in 0 until clipData.itemCount) {
        val uri = clipData.getItemAt(i)?.uri
        if (uri != null) {
          result.add(uri)
        }
      }
    } else {
      data.data?.let { result.add(it) }
    }
    return result
  }

  private fun applyInitialUriExtra(intent: Intent, initialDirectory: String?) {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
      !initialDirectory.isNullOrBlank() &&
      initialDirectory.startsWith("content://")
    ) {
      try {
        intent.putExtra(DocumentsContract.EXTRA_INITIAL_URI, Uri.parse(initialDirectory))
      } catch (_: Exception) {
        // Ignore malformed initial URI hints.
      }
    }
  }

  private fun resolveMimeFilters(groups: List<Map<*, *>>?): List<String> {
    if (groups.isNullOrEmpty()) {
      return emptyList()
    }
    val resolved = LinkedHashSet<String>()
    for (group in groups) {
      if (group["allowsAll"] == true) {
        return emptyList()
      }
      val mimeTypes = (group["mimeTypes"] as? List<*>)
        ?.mapNotNull { (it as? String)?.trim() }
        ?.filter { it.isNotEmpty() }
        ?: emptyList()
      val extensions = (group["extensions"] as? List<*>)
        ?.mapNotNull { (it as? String)?.trim() }
        ?.filter { it.isNotEmpty() }
        ?: emptyList()

      if (mimeTypes.isEmpty() && extensions.isEmpty()) {
        return emptyList()
      }

      for (mime in mimeTypes) {
        if (mime == "*/*") {
          return emptyList()
        }
        resolved.add(mime)
      }
      for (rawExt in extensions) {
        val clean = stripLeadingDots(rawExt)
        if (clean == "*") {
          return emptyList()
        }
        val mapped = lookupMimeFromExtension(clean)
        if (mapped != null) {
          resolved.add(mapped)
        } else {
          // If an unknown custom extension cannot be mapped to a strict MIME type,
          // broaden to `*/*` so SAF does not hide matching files from the user.
          return emptyList()
        }
      }
    }
    return resolved.toList()
  }

  private fun resolveSaveMimeType(
    explicitMimeType: String?,
    suggestedName: String?,
    groups: List<Map<*, *>>?,
  ): String {
    val trimmedExplicit = explicitMimeType?.trim()
    if (!trimmedExplicit.isNullOrEmpty() && trimmedExplicit != "*/*") {
      return trimmedExplicit
    }
    if (!suggestedName.isNullOrBlank()) {
      val dot = suggestedName.lastIndexOf('.')
      if (dot >= 0 && dot < suggestedName.length - 1) {
        val ext = suggestedName.substring(dot + 1).lowercase()
        lookupMimeFromExtension(ext)?.let { return it }
      }
    }
    val filters = resolveMimeFilters(groups)
    val concrete = filters.firstOrNull { !it.endsWith("/*") }
    if (concrete != null) {
      return concrete
    }
    return filters.firstOrNull() ?: "application/octet-stream"
  }

  private fun lookupMimeFromExtension(ext: String): String? {
    if (ext.isEmpty()) {
      return null
    }
    MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext)?.let { return it }
    return FALLBACK_EXTENSION_MIMES[ext]
  }

  private fun takePersistableTreePermission(resolver: ContentResolver, treeUri: Uri) {
    val flags = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
    try {
      resolver.takePersistableUriPermission(treeUri, flags)
    } catch (_: SecurityException) {
      try {
        resolver.takePersistableUriPermission(treeUri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
      } catch (_: SecurityException) {
        // Ephemeral grant remains valid for the active process session.
      }
    }
  }

  private fun isDirectoryContentUri(context: Context, uri: Uri): Boolean {
    if (DocumentsContract.isTreeUri(uri) && !DocumentsContract.isDocumentUri(context, uri)) {
      return true
    }
    try {
      val type = context.contentResolver.getType(uri)
      if (type == DocumentsContract.Document.MIME_TYPE_DIR) {
        return true
      }
    } catch (_: Exception) {
      // Fall through to cursor query.
    }
    val queryUri = resolveQueryableDocumentUri(context, uri)
    try {
      context.contentResolver.query(
        queryUri,
        arrayOf(DocumentsContract.Document.COLUMN_MIME_TYPE),
        null,
        null,
        null,
      )?.use { cursor ->
        if (cursor.moveToFirst() && !cursor.isNull(0)) {
          return cursor.getString(0) == DocumentsContract.Document.MIME_TYPE_DIR
        }
      }
    } catch (_: Exception) {
      return false
    }
    return false
  }

  private fun resolveQueryableDocumentUri(context: Context, uri: Uri): Uri {
    if (DocumentsContract.isTreeUri(uri) && !DocumentsContract.isDocumentUri(context, uri)) {
      return try {
        val docId = DocumentsContract.getTreeDocumentId(uri)
        DocumentsContract.buildDocumentUriUsingTree(uri, docId)
      } catch (_: Exception) {
        uri
      }
    }
    return uri
  }

  private fun queryDisplayName(context: Context, uri: Uri): String? {
    val queryUri = resolveQueryableDocumentUri(context, uri)
    try {
      context.contentResolver.query(
        queryUri,
        arrayOf(OpenableColumns.DISPLAY_NAME),
        null,
        null,
        null,
      )?.use { cursor ->
        if (cursor.moveToFirst()) {
          val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
          if (index >= 0 && !cursor.isNull(index)) {
            val name = cursor.getString(index)
            if (!name.isNullOrBlank()) {
              return name
            }
          }
        }
      }
    } catch (_: Exception) {
      return null
    }
    return null
  }

  private fun makeCacheSubdirectory(context: Context, category: String, id: String): File {
    val root = File(context.cacheDir, CACHE_ROOT_DIR_NAME)
    val sub = File(File(root, category), sanitizeIdentifier(id))
    if (!sub.exists()) {
      sub.mkdirs()
    }
    return sub
  }

  private fun copyContentUriToFile(
    context: Context,
    uri: Uri,
    batchDirectory: File,
    index: Int,
    fallbackName: String,
  ): File? {
    val rawName = queryDisplayName(context, uri)
    val safeName = sanitizeFileName(rawName, fallback = fallbackName)
    val slotDir = File(batchDirectory, index.toString())
    if (!slotDir.exists() && !slotDir.mkdirs()) {
      return null
    }
    val destFile = File(slotDir, safeName)
    val canonicalParent = slotDir.canonicalPath + File.separator
    if (!destFile.canonicalPath.startsWith(canonicalParent)) {
      return null
    }

    return try {
      val input = context.contentResolver.openInputStream(uri) ?: return null
      input.use { inStream ->
        FileOutputStream(destFile).use { outStream ->
          val buffer = ByteArray( STREAM_BUFFER_SIZE )
          while (true) {
            val read = inStream.read(buffer)
            if (read < 0) {
              break
            }
            if (read > 0) {
              outStream.write(buffer, 0, read)
            }
          }
          outStream.flush()
        }
      }
      destFile
    } catch (_: Exception) {
      if (destFile.exists()) {
        destFile.delete()
      }
      null
    }
  }

  private fun writeBytesToContentUri(resolver: ContentResolver, uri: Uri, bytes: ByteArray) {
    val outStream = (try {
      resolver.openOutputStream(uri, "wt")
    } catch (_: Exception) {
      null
    }) ?: resolver.openOutputStream(uri, "w")
      ?: resolver.openOutputStream(uri)
      ?: throw IllegalStateException("Unable to open OutputStream for $uri")

    outStream.use { stream ->
      stream.write(bytes)
      stream.flush()
    }
  }

  private fun readStreamSlice(stream: InputStream, start: Long?, end: Long?): ByteArray {
    val startOffset = (start ?: 0L).coerceAtLeast(0L)
    if (end != null && end <= startOffset) {
      return ByteArray(0)
    }

    var remainingSkip = startOffset
    val skipScratch = ByteArray(minOf(STREAM_BUFFER_SIZE.toLong(), maxOf(remainingSkip, 1L)).toInt())
    while (remainingSkip > 0L) {
      val skipped = stream.skip(remainingSkip)
      if (skipped > 0L) {
        remainingSkip -= skipped
        continue
      }
      val toRead = minOf(skipScratch.size.toLong(), remainingSkip).toInt()
      val read = stream.read(skipScratch, 0, toRead)
      if (read < 0) {
        return ByteArray(0)
      }
      remainingSkip -= read.toLong()
    }

    val maxBytes = end?.let { (it - startOffset).coerceAtLeast(0L) }
    val out = ByteArrayOutputStream()
    val buffer = ByteArray(STREAM_BUFFER_SIZE)
    var totalRead = 0L

    while (maxBytes == null || totalRead < maxBytes) {
      val toRead = if (maxBytes == null) {
        buffer.size
      } else {
        minOf(buffer.size.toLong(), maxBytes - totalRead).toInt()
      }
      if (toRead <= 0) {
        break
      }
      val read = stream.read(buffer, 0, toRead)
      if (read < 0) {
        break
      }
      if (read > 0) {
        out.write(buffer, 0, read)
        totalRead += read.toLong()
      }
    }
    return out.toByteArray()
  }

  companion object {
    private const val CHANNEL_NAME = "com.infradise.file_drop"
    private const val CACHE_ROOT_DIR_NAME = "com.infradise.file_drop"
    private const val STREAM_BUFFER_SIZE = 64 * 1024

    private const val REQ_OPEN_FILE = 0xFD01
    private const val REQ_OPEN_FILES = 0xFD02
    private const val REQ_SAVE_FILE = 0xFD03
    private const val REQ_OPEN_DIRECTORY = 0xFD04
    private const val REQ_GET_DIRECTORY_PATH = 0xFD05
    private const val REQ_REQUEST_DIR_ACCESS = 0xFD06

    private val FALLBACK_EXTENSION_MIMES = mapOf(
      "avif" to "image/avif",
      "csv" to "text/csv",
      "dart" to "text/x-dart",
      "heic" to "image/heic",
      "json" to "application/json",
      "md" to "text/markdown",
      "mjs" to "text/javascript",
      "svg" to "image/svg+xml",
      "toml" to "application/toml",
      "ts" to "text/typescript",
      "wasm" to "application/wasm",
      "webp" to "image/webp",
      "yaml" to "application/yaml",
      "yml" to "application/yaml",
    )

    internal fun sanitizeFileName(rawName: String?, fallback: String): String {
      if (rawName.isNullOrBlank()) {
        return fallback
      }
      var cleaned = rawName
        .replace('\u0000', '_')
        .replace('/', '_')
        .replace('\\', '_')
        .trim()
      while (cleaned.startsWith("..")) {
        cleaned = cleaned.removePrefix("..").trimStart('.', '_', ' ')
      }
      cleaned = cleaned.replace("..", "_")
      if (cleaned.isEmpty() || cleaned == "." || cleaned == "_") {
        return fallback
      }
      return cleaned
    }

    private fun sanitizeIdentifier(raw: String): String {
      val sb = StringBuilder(raw.length)
      for (ch in raw) {
        if (ch.isLetterOrDigit() || ch == '-' || ch == '_') {
          sb.append(ch)
        }
      }
      return sb.toString()
    }

    private fun stripLeadingDots(rawExt: String): String {
      var trimmed = rawExt.trim().lowercase()
      if (trimmed.startsWith("*.")) {
        trimmed = trimmed.substring(2)
      } else {
        trimmed = trimmed.trimStart('.')
      }
      return trimmed
    }

    private fun extractUriSegmentName(uri: Uri): String {
      val last = uri.lastPathSegment ?: return "directory"
      val colonIdx = last.lastIndexOf(':')
      val slashIdx = last.lastIndexOf('/')
      val cut = maxOf(colonIdx, slashIdx)
      val candidate = if (cut >= 0 && cut < last.length - 1) {
        last.substring(cut + 1)
      } else {
        last
      }
      return sanitizeFileName(candidate, fallback = "directory")
    }
  }
}

