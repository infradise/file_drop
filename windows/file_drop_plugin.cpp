#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include <windows.h>
#include <ole2.h>
#include <shellapi.h>
#include <shlobj.h>
#include <shobjidl.h>

#include "include/file_drop/file_drop_plugin_c_api.h"

#include <flutter/encodable_value.h>
#include <flutter/flutter_view.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <flutter_windows.h>

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <utility>
#include <variant>
#include <vector>

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using FlutterChannel = flutter::MethodChannel<EncodableValue>;

std::string WideToUtf8(const std::wstring& wide) {
  if (wide.empty()) {
    return {};
  }
  const int wide_len = static_cast<int>(wide.size());
  const int size_needed = WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, wide.data(), wide_len, nullptr, 0, nullptr,
      nullptr);
  if (size_needed <= 0) {
    return {};
  }
  std::string utf8(static_cast<size_t>(size_needed), '\0');
  WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide.data(), wide_len,
                      utf8.data(), size_needed, nullptr, nullptr);
  return utf8;
}

std::wstring Utf8ToWide(const std::string& utf8) {
  if (utf8.empty()) {
    return {};
  }
  const int utf8_len = static_cast<int>(utf8.size());
  const int size_needed = MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, utf8.data(), utf8_len, nullptr, 0);
  if (size_needed <= 0) {
    return {};
  }
  std::wstring wide(static_cast<size_t>(size_needed), L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8.data(), utf8_len,
                      wide.data(), size_needed);
  return wide;
}

std::string StripLeadingDots(const std::string& ext) {
  size_t start = 0;
  if (ext.size() >= 2U && ext[0] == '*' && ext[1] == '.') {
    start = 2U;
  } else {
    while (start < ext.size() && ext[start] == '.') {
      ++start;
    }
  }
  return ext.substr(start);
}

class ScopedComInitializer {
 public:
  ScopedComInitializer()
      : hr_(::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED)) {}
  ~ScopedComInitializer() {
    if (SUCCEEDED(hr_)) {
      ::CoUninitialize();
    }
  }
  ScopedComInitializer(const ScopedComInitializer&) = delete;
  ScopedComInitializer& operator=(const ScopedComInitializer&) = delete;

 private:
  HRESULT hr_;
};

template <typename T>
class ScopedComPtr {
 public:
  ScopedComPtr() = default;
  ~ScopedComPtr() { Reset(); }
  ScopedComPtr(const ScopedComPtr&) = delete;
  ScopedComPtr& operator=(const ScopedComPtr&) = delete;

  T** Put() {
    Reset();
    return &ptr_;
  }
  T* Get() const { return ptr_; }
  T* operator->() const { return ptr_; }
  explicit operator bool() const { return ptr_ != nullptr; }

  void Reset() {
    if (ptr_ != nullptr) {
      ptr_->Release();
      ptr_ = nullptr;
    }
  }

 private:
  T* ptr_ = nullptr;
};

std::string GetShellItemPath(IShellItem* item) {
  if (item == nullptr) {
    return {};
  }
  PWSTR raw_path = nullptr;
  if (FAILED(item->GetDisplayName(SIGDN_FILESYSPATH, &raw_path)) ||
      raw_path == nullptr) {
    return {};
  }
  std::wstring wide_path(raw_path);
  ::CoTaskMemFree(raw_path);
  return WideToUtf8(wide_path);
}

const std::string* LookupString(const EncodableMap& map, const char* key) {
  const auto it = map.find(EncodableValue(key));
  if (it == map.end()) {
    return nullptr;
  }
  return std::get_if<std::string>(&it->second);
}

const EncodableList* LookupList(const EncodableMap& map, const char* key) {
  const auto it = map.find(EncodableValue(key));
  if (it == map.end()) {
    return nullptr;
  }
  return std::get_if<EncodableList>(&it->second);
}

void ApplyFileTypeFilters(IFileDialog* dialog, const EncodableMap& args) {
  const EncodableList* groups = LookupList(args, "acceptedTypeGroups");
  if (groups == nullptr || groups->empty()) {
    return;
  }

  std::vector<std::wstring> filter_labels;
  std::vector<std::wstring> filter_patterns;
  filter_labels.reserve(groups->size());
  filter_patterns.reserve(groups->size());

  for (const EncodableValue& raw_group : *groups) {
    const auto* group = std::get_if<EncodableMap>(&raw_group);
    if (group == nullptr) {
      continue;
    }
    const std::string* label = LookupString(*group, "label");
    std::wstring wide_label =
        (label != nullptr && !label->empty()) ? Utf8ToWide(*label) : L"Files";

    std::wstring spec;
    const EncodableList* extensions = LookupList(*group, "extensions");
    if (extensions != nullptr && !extensions->empty()) {
      for (const EncodableValue& ext_val : *extensions) {
        const auto* ext_str = std::get_if<std::string>(&ext_val);
        if (ext_str == nullptr) {
          continue;
        }
        std::string cleaned = StripLeadingDots(*ext_str);
        if (cleaned.empty()) {
          continue;
        }
        if (!spec.empty()) {
          spec += L";";
        }
        spec += L"*." + Utf8ToWide(cleaned);
      }
    }
    if (spec.empty()) {
      spec = L"*.*";
    }

    filter_labels.push_back(std::move(wide_label));
    filter_patterns.push_back(std::move(spec));
  }

  if (filter_labels.empty()) {
    return;
  }

  std::vector<COMDLG_FILTERSPEC> specs;
  specs.reserve(filter_labels.size());
  for (size_t i = 0; i < filter_labels.size(); ++i) {
    specs.push_back({filter_labels[i].c_str(), filter_patterns[i].c_str()});
  }
  dialog->SetFileTypes(static_cast<UINT>(specs.size()), specs.data());
}

void ConfigureCommonDialog(IFileDialog* dialog, const EncodableMap& args) {
  if (const std::string* initial_dir = LookupString(args, "initialDirectory");
      initial_dir != nullptr && !initial_dir->empty()) {
    const std::wstring wide_dir = Utf8ToWide(*initial_dir);
    ScopedComPtr<IShellItem> folder_item;
    if (SUCCEEDED(::SHCreateItemFromParsingName(
            wide_dir.c_str(), nullptr, IID_PPV_ARGS(folder_item.Put())))) {
      dialog->SetFolder(folder_item.Get());
    }
  }

  if (const std::string* confirm_text = LookupString(args, "confirmButtonText");
      confirm_text != nullptr && !confirm_text->empty()) {
    const std::wstring wide_confirm = Utf8ToWide(*confirm_text);
    dialog->SetOkButtonLabel(wide_confirm.c_str());
  }

  if (const std::string* suggested_name = LookupString(args, "suggestedName");
      suggested_name != nullptr && !suggested_name->empty()) {
    const std::wstring wide_name = Utf8ToWide(*suggested_name);
    dialog->SetFileName(wide_name.c_str());
  }
}

/// Reference-counted OLE `IDropTarget` delivering logical DPI-scaled Flutter
/// coordinates and dropped `CF_HDROP` filesystem items.
class FileDropComTarget : public IDropTarget {
 public:
  FileDropComTarget(HWND hwnd, std::shared_ptr<FlutterChannel> channel)
      : hwnd_(hwnd), channel_(std::move(channel)) {
    ::CoCreateInstance(CLSID_DragDropHelper, nullptr, CLSCTX_INPROC_SERVER,
                       IID_PPV_ARGS(drag_helper_.Put()));
  }

  FileDropComTarget(const FileDropComTarget&) = delete;
  FileDropComTarget& operator=(const FileDropComTarget&) = delete;

  HRESULT Register() {
    if (hwnd_ == nullptr || !::IsWindow(hwnd_)) {
      return E_HANDLE;
    }
    const HRESULT hr = ::RegisterDragDrop(hwnd_, this);
    registered_ = SUCCEEDED(hr);
    return hr;
  }

  void Revoke() {
    if (drag_helper_active_ && drag_helper_) {
      drag_helper_->DragLeave();
      drag_helper_active_ = false;
    }
    drag_helper_.Reset();
    if (registered_ && hwnd_ != nullptr && ::IsWindow(hwnd_)) {
      ::RevokeDragDrop(hwnd_);
    }
    registered_ = false;
    hwnd_ = nullptr;
    channel_.reset();
  }

  // IUnknown
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid,
                                           void** ppv_object) override {
    if (ppv_object == nullptr) {
      return E_POINTER;
    }
    if (riid == IID_IUnknown || riid == IID_IDropTarget) {
      *ppv_object = static_cast<IDropTarget*>(this);
      AddRef();
      return S_OK;
    }
    *ppv_object = nullptr;
    return E_NOINTERFACE;
  }

  ULONG STDMETHODCALLTYPE AddRef() override { return ++ref_count_; }

  ULONG STDMETHODCALLTYPE Release() override {
    const ULONG remaining = --ref_count_;
    if (remaining == 0U) {
      delete this;
    }
    return remaining;
  }

  // IDropTarget
  HRESULT STDMETHODCALLTYPE DragEnter(IDataObject* data_obj, DWORD /*key_state*/,
                                      POINTL pt, DWORD* effect) override {
    if (effect == nullptr) {
      return E_POINTER;
    }
    FORMATETC fmt = {static_cast<CLIPFORMAT>(CF_HDROP), nullptr,
                     DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
    has_hdrop_ =
        (data_obj != nullptr && SUCCEEDED(data_obj->QueryGetData(&fmt)));
    *effect = ChooseEffect(*effect);

    if (drag_helper_ && data_obj != nullptr && hwnd_ != nullptr) {
      POINT screen_pt = {pt.x, pt.y};
      drag_helper_active_ = SUCCEEDED(
          drag_helper_->DragEnter(hwnd_, data_obj, &screen_pt, *effect));
    }

    if (has_hdrop_ && channel_ && hwnd_ != nullptr) {
      const auto coords = ToFlutterLogicalPoint(pt);
      channel_->InvokeMethod(
          "onDragEntered",
          std::make_unique<EncodableValue>(EncodableMap{
              {EncodableValue("x"), EncodableValue(coords.first)},
              {EncodableValue("y"), EncodableValue(coords.second)},
          }));
    }
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE DragOver(DWORD /*key_state*/, POINTL pt,
                                     DWORD* effect) override {
    if (effect == nullptr) {
      return E_POINTER;
    }
    *effect = ChooseEffect(*effect);

    if (drag_helper_active_ && drag_helper_) {
      POINT screen_pt = {pt.x, pt.y};
      drag_helper_->DragOver(&screen_pt, *effect);
    }

    if (has_hdrop_ && channel_ && hwnd_ != nullptr) {
      const auto coords = ToFlutterLogicalPoint(pt);
      channel_->InvokeMethod(
          "onDragUpdated",
          std::make_unique<EncodableValue>(EncodableMap{
              {EncodableValue("x"), EncodableValue(coords.first)},
              {EncodableValue("y"), EncodableValue(coords.second)},
          }));
    }
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE DragLeave() override {
    if (drag_helper_active_ && drag_helper_) {
      drag_helper_->DragLeave();
      drag_helper_active_ = false;
    }
    if (has_hdrop_ && channel_) {
      channel_->InvokeMethod("onDragExited",
                             std::make_unique<EncodableValue>());
    }
    has_hdrop_ = false;
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE Drop(IDataObject* data_obj, DWORD /*key_state*/,
                                 POINTL pt, DWORD* effect) override {
    if (effect == nullptr) {
      return E_POINTER;
    }
    *effect = ChooseEffect(*effect);

    if (drag_helper_active_ && drag_helper_ && data_obj != nullptr) {
      POINT screen_pt = {pt.x, pt.y};
      drag_helper_->Drop(data_obj, &screen_pt, *effect);
      drag_helper_active_ = false;
    }

    EncodableList dropped_items;
    FORMATETC fmt = {static_cast<CLIPFORMAT>(CF_HDROP), nullptr,
                     DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
    STGMEDIUM medium{};
    if (data_obj != nullptr && SUCCEEDED(data_obj->GetData(&fmt, &medium))) {
      if (medium.tymed == TYMED_HGLOBAL && medium.hGlobal != nullptr) {
        auto* hdrop = static_cast<HDROP>(::GlobalLock(medium.hGlobal));
        if (hdrop != nullptr) {
          const UINT file_count =
              ::DragQueryFileW(hdrop, 0xFFFFFFFFU, nullptr, 0U);
          dropped_items.reserve(static_cast<size_t>(file_count));
          for (UINT i = 0U; i < file_count; ++i) {
            const UINT char_len = ::DragQueryFileW(hdrop, i, nullptr, 0U);
            if (char_len == 0U) {
              continue;
            }
            std::wstring wide_path(static_cast<size_t>(char_len) + 1U, L'\0');
            ::DragQueryFileW(hdrop, i, wide_path.data(), char_len + 1U);
            wide_path.resize(static_cast<size_t>(char_len));

            const DWORD attrs = ::GetFileAttributesW(wide_path.c_str());
            const bool is_dir = (attrs != INVALID_FILE_ATTRIBUTES) &&
                                ((attrs & FILE_ATTRIBUTE_DIRECTORY) != 0U);

            dropped_items.push_back(EncodableValue(EncodableMap{
                {EncodableValue("path"), EncodableValue(WideToUtf8(wide_path))},
                {EncodableValue("isDirectory"), EncodableValue(is_dir)},
            }));
          }
          ::GlobalUnlock(medium.hGlobal);
        }
      }
      ::ReleaseStgMedium(&medium);
    }

    if (channel_ && hwnd_ != nullptr && !dropped_items.empty()) {
      const auto coords = ToFlutterLogicalPoint(pt);
      channel_->InvokeMethod(
          "onDragDone",
          std::make_unique<EncodableValue>(EncodableMap{
              {EncodableValue("x"), EncodableValue(coords.first)},
              {EncodableValue("y"), EncodableValue(coords.second)},
              {EncodableValue("items"), EncodableValue(dropped_items)},
          }));
    }

    has_hdrop_ = false;
    return S_OK;
  }

 protected:
  virtual ~FileDropComTarget() = default;

 private:
  DWORD ChooseEffect(DWORD allowed) const {
    if (!has_hdrop_) {
      return DROPEFFECT_NONE;
    }
    if ((allowed & DROPEFFECT_COPY) != 0U) {
      return DROPEFFECT_COPY;
    }
    if ((allowed & DROPEFFECT_LINK) != 0U) {
      return DROPEFFECT_LINK;
    }
    return DROPEFFECT_COPY;
  }

  std::pair<double, double> ToFlutterLogicalPoint(POINTL screen_pt) const {
    POINT client_pt = {screen_pt.x, screen_pt.y};
    ::ScreenToClient(hwnd_, &client_pt);
    const UINT dpi = FlutterDesktopGetDpiForHWND(hwnd_);
    const double scale =
        (dpi > 0U) ? (static_cast<double>(dpi) / 96.0) : 1.0;
    return {
        static_cast<double>(client_pt.x) / scale,
        static_cast<double>(client_pt.y) / scale,
    };
  }

  std::atomic<ULONG> ref_count_{1U};
  HWND hwnd_;
  std::shared_ptr<FlutterChannel> channel_;
  ScopedComPtr<IDropTargetHelper> drag_helper_;
  bool registered_ = false;
  bool drag_helper_active_ = false;
  bool has_hdrop_ = false;
};

class FileDropPlugin final : public flutter::Plugin {
 public:
  FileDropPlugin(HWND view_hwnd, std::shared_ptr<FlutterChannel> channel)
      : view_hwnd_(view_hwnd),
        channel_(std::move(channel)),
        ole_init_hr_(::OleInitialize(nullptr)) {
    if (SUCCEEDED(ole_init_hr_) && view_hwnd_ != nullptr &&
        ::IsWindow(view_hwnd_)) {
      drop_target_ = new FileDropComTarget(view_hwnd_, channel_);
      if (FAILED(drop_target_->Register())) {
        drop_target_->Release();
        drop_target_ = nullptr;
      }
    }
  }

  FileDropPlugin(const FileDropPlugin&) = delete;
  FileDropPlugin& operator=(const FileDropPlugin&) = delete;

  ~FileDropPlugin() override {
    if (channel_) {
      channel_->SetMethodCallHandler(nullptr);
    }
    if (drop_target_ != nullptr) {
      drop_target_->Revoke();
      drop_target_->Release();
      drop_target_ = nullptr;
    }
    if (SUCCEEDED(ole_init_hr_)) {
      ::OleUninitialize();
    }
  }

  void HandleMethodCall(
      const flutter::MethodCall<EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    const EncodableMap empty_args;
    const auto* args_ptr =
        call.arguments() != nullptr
            ? std::get_if<EncodableMap>(call.arguments())
            : nullptr;
    const EncodableMap& args = (args_ptr != nullptr) ? *args_ptr : empty_args;

    const std::string& method = call.method_name();
    if (method == "openFile") {
      HandleOpenDialog(args, /*allow_multiple=*/false, /*pick_folders=*/false,
                       std::move(result));
    } else if (method == "openFiles") {
      HandleOpenDialog(args, /*allow_multiple=*/true, /*pick_folders=*/false,
                       std::move(result));
    } else if (method == "getDirectoryPath") {
      HandleOpenDialog(args, /*allow_multiple=*/false, /*pick_folders=*/true,
                       std::move(result));
    } else if (method == "getDirectoryPaths") {
      HandleOpenDialog(args, /*allow_multiple=*/true, /*pick_folders=*/true,
                       std::move(result));
    } else if (method == "getSaveLocation") {
      HandleSaveDialog(args, std::move(result));
    } else if (method == "startAccessingSecurityScopedResource") {
      result->Success(EncodableValue(false));
    } else if (method == "stopAccessingSecurityScopedResource") {
      result->Success(EncodableValue(true));
    } else {
      result->NotImplemented();
    }
  }

 private:
  HWND OwnerWindow() const {
    if (view_hwnd_ == nullptr || !::IsWindow(view_hwnd_)) {
      return nullptr;
    }
    HWND root = ::GetAncestor(view_hwnd_, GA_ROOT);
    return root != nullptr ? root : view_hwnd_;
  }

  void HandleOpenDialog(
      const EncodableMap& args, bool allow_multiple, bool pick_folders,
      std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    ScopedComInitializer com;
    ScopedComPtr<IFileOpenDialog> dialog;
    HRESULT hr = ::CoCreateInstance(CLSID_FileOpenDialog, nullptr,
                                    CLSCTX_INPROC_SERVER,
                                    IID_PPV_ARGS(dialog.Put()));
    if (FAILED(hr) || !dialog) {
      result->Error("dialog_create_failed",
                    "Failed to create IFileOpenDialog instance.");
      return;
    }

    FILEOPENDIALOGOPTIONS options = 0;
    if (SUCCEEDED(dialog->GetOptions(&options))) {
      options |= FOS_FORCEFILESYSTEM;
      if (allow_multiple) {
        options |= FOS_ALLOWMULTISELECT;
      }
      if (pick_folders) {
        options |= FOS_PICKFOLDERS;
      }
      dialog->SetOptions(options);
    }

    ConfigureCommonDialog(dialog.Get(), args);
    if (!pick_folders) {
      ApplyFileTypeFilters(dialog.Get(), args);
    }

    hr = dialog->Show(OwnerWindow());
    if (hr == HRESULT_FROM_WIN32(ERROR_CANCELLED)) {
      if (allow_multiple) {
        result->Success(EncodableValue(EncodableList{}));
      } else {
        result->Success(EncodableValue());
      }
      return;
    }
    if (FAILED(hr)) {
      result->Error("dialog_show_failed", "Failed to show IFileOpenDialog.");
      return;
    }

    if (allow_multiple) {
      EncodableList paths;
      ScopedComPtr<IShellItemArray> items;
      if (SUCCEEDED(dialog->GetResults(items.Put())) && items) {
        DWORD count = 0U;
        if (SUCCEEDED(items->GetCount(&count))) {
          paths.reserve(static_cast<size_t>(count));
          for (DWORD i = 0U; i < count; ++i) {
            ScopedComPtr<IShellItem> item;
            if (SUCCEEDED(items->GetItemAt(i, item.Put()))) {
              std::string path = GetShellItemPath(item.Get());
              if (!path.empty()) {
                paths.push_back(EncodableValue(std::move(path)));
              }
            }
          }
        }
      }
      result->Success(EncodableValue(std::move(paths)));
    } else {
      ScopedComPtr<IShellItem> item;
      if (SUCCEEDED(dialog->GetResult(item.Put())) && item) {
        std::string path = GetShellItemPath(item.Get());
        if (!path.empty()) {
          result->Success(EncodableValue(std::move(path)));
          return;
        }
      }
      result->Success(EncodableValue());
    }
  }

  void HandleSaveDialog(
      const EncodableMap& args,
      std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    ScopedComInitializer com;
    ScopedComPtr<IFileSaveDialog> dialog;
    HRESULT hr = ::CoCreateInstance(CLSID_FileSaveDialog, nullptr,
                                    CLSCTX_INPROC_SERVER,
                                    IID_PPV_ARGS(dialog.Put()));
    if (FAILED(hr) || !dialog) {
      result->Error("dialog_create_failed",
                    "Failed to create IFileSaveDialog instance.");
      return;
    }

    FILEOPENDIALOGOPTIONS options = 0;
    if (SUCCEEDED(dialog->GetOptions(&options))) {
      options |= FOS_FORCEFILESYSTEM | FOS_OVERWRITEPROMPT;
      dialog->SetOptions(options);
    }

    ConfigureCommonDialog(dialog.Get(), args);
    ApplyFileTypeFilters(dialog.Get(), args);

    hr = dialog->Show(OwnerWindow());
    if (hr == HRESULT_FROM_WIN32(ERROR_CANCELLED)) {
      result->Success(EncodableValue());
      return;
    }
    if (FAILED(hr)) {
      result->Error("dialog_show_failed", "Failed to show IFileSaveDialog.");
      return;
    }

    ScopedComPtr<IShellItem> item;
    if (FAILED(dialog->GetResult(item.Put())) || !item) {
      result->Success(EncodableValue());
      return;
    }

    std::string path = GetShellItemPath(item.Get());
    if (path.empty()) {
      result->Success(EncodableValue());
      return;
    }

    EncodableValue active_filter_index;
    UINT type_index = 0U;
    if (SUCCEEDED(dialog->GetFileTypeIndex(&type_index)) && type_index > 0U) {
      active_filter_index =
          EncodableValue(static_cast<int32_t>(type_index - 1U));
    }

    result->Success(EncodableValue(EncodableMap{
        {EncodableValue("path"), EncodableValue(std::move(path))},
        {EncodableValue("activeFilterIndex"), active_filter_index},
    }));
  }

  HWND view_hwnd_;
  std::shared_ptr<FlutterChannel> channel_;
  HRESULT ole_init_hr_;
  FileDropComTarget* drop_target_ = nullptr;
};

}  // namespace

void FileDropPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar_ref) {
  auto* registrar =
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar_ref);

  FlutterDesktopViewRef view_ref =
      FlutterDesktopPluginRegistrarGetView(registrar_ref);
  HWND hwnd = (view_ref != nullptr) ? FlutterDesktopViewGetHWND(view_ref)
                                    : nullptr;
  if (hwnd == nullptr && registrar->GetView() != nullptr) {
    hwnd = registrar->GetView()->GetNativeWindow();
  }

  auto channel = std::make_shared<FlutterChannel>(
      registrar->messenger(), "com.infradise.file_drop",
      &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<FileDropPlugin>(hwnd, channel);
  auto* plugin_ptr = plugin.get();

  channel->SetMethodCallHandler(
      [plugin_ptr](const auto& call, auto result) {
        plugin_ptr->HandleMethodCall(call, std::move(result));
      });

  registrar->AddPlugin(std::move(plugin));
}
