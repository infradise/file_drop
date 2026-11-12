#include "include/file_drop/file_drop_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

#include <cstddef>
#include <cstring>
#include <string>
#include <vector>

#define FILE_DROP_PLUGIN(obj)                                     \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), file_drop_plugin_get_type(), \
                              FileDropPlugin))

struct _FileDropPlugin {
  GObject parent_instance;
  FlPluginRegistrar* registrar;
  FlMethodChannel* channel;
  gboolean is_dragging;
  gboolean has_drop_coords;
  gint drop_x;
  gint drop_y;
};

G_DEFINE_TYPE(FileDropPlugin, file_drop_plugin, G_TYPE_OBJECT)

namespace {

enum class DialogKind {
  kOpenSingle,
  kOpenMultiple,
  kSave,
  kDirectorySingle,
  kDirectoryMultiple,
};

struct DialogRequestContext {
  FlMethodCall* method_call;
  GtkFileChooserNative* dialog;
  DialogKind kind;
  gulong response_handler_id;
  std::vector<GtkFileFilter*> filters;
};

const gchar* LookupStringArg(FlValue* args, const gchar* key) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return nullptr;
  }
  FlValue* val = fl_value_lookup_string(args, key);
  if (val == nullptr || fl_value_get_type(val) != FL_VALUE_TYPE_STRING) {
    return nullptr;
  }
  const gchar* str = fl_value_get_string(val);
  return (str != nullptr && str[0] != '\0') ? str : nullptr;
}

gboolean LookupBoolArg(FlValue* args, const gchar* key, gboolean fallback) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return fallback;
  }
  FlValue* val = fl_value_lookup_string(args, key);
  if (val == nullptr || fl_value_get_type(val) != FL_VALUE_TYPE_BOOL) {
    return fallback;
  }
  return fl_value_get_bool(val);
}

std::string StripLeadingDots(const char* raw) {
  if (raw == nullptr) {
    return {};
  }
  std::string ext(raw);
  size_t pos = 0;
  if (ext.size() >= 2U && ext[0] == '*' && ext[1] == '.') {
    pos = 2U;
  } else {
    while (pos < ext.size() && ext[pos] == '.') {
      ++pos;
    }
  }
  return ext.substr(pos);
}

void ApplyGtkFilters(GtkFileChooser* chooser, FlValue* args,
                     std::vector<GtkFileFilter*>* out_filters) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return;
  }
  FlValue* groups = fl_value_lookup_string(args, "acceptedTypeGroups");
  if (groups == nullptr || fl_value_get_type(groups) != FL_VALUE_TYPE_LIST) {
    return;
  }

  const size_t group_len = fl_value_get_length(groups);
  for (size_t i = 0; i < group_len; ++i) {
    FlValue* group = fl_value_get_list_value(groups, i);
    if (group == nullptr || fl_value_get_type(group) != FL_VALUE_TYPE_MAP) {
      continue;
    }

    GtkFileFilter* filter = gtk_file_filter_new();
    const gchar* label = LookupStringArg(group, "label");
    gtk_file_filter_set_name(filter, label != nullptr ? label : "Files");

    bool added_any_rule = false;

    FlValue* extensions = fl_value_lookup_string(group, "extensions");
    if (extensions != nullptr &&
        fl_value_get_type(extensions) == FL_VALUE_TYPE_LIST) {
      const size_t ext_len = fl_value_get_length(extensions);
      for (size_t j = 0; j < ext_len; ++j) {
        FlValue* ext_val = fl_value_get_list_value(extensions, j);
        if (ext_val != nullptr &&
            fl_value_get_type(ext_val) == FL_VALUE_TYPE_STRING) {
          std::string cleaned = StripLeadingDots(fl_value_get_string(ext_val));
          if (!cleaned.empty()) {
            std::string pattern = "*." + cleaned;
            gtk_file_filter_add_pattern(filter, pattern.c_str());
            added_any_rule = true;
          }
        }
      }
    }

    FlValue* mime_types = fl_value_lookup_string(group, "mimeTypes");
    if (mime_types != nullptr &&
        fl_value_get_type(mime_types) == FL_VALUE_TYPE_LIST) {
      const size_t mime_len = fl_value_get_length(mime_types);
      for (size_t j = 0; j < mime_len; ++j) {
        FlValue* mime_val = fl_value_get_list_value(mime_types, j);
        if (mime_val != nullptr &&
            fl_value_get_type(mime_val) == FL_VALUE_TYPE_STRING) {
          const gchar* mime = fl_value_get_string(mime_val);
          if (mime != nullptr && mime[0] != '\0') {
            gtk_file_filter_add_mime_type(filter, mime);
            added_any_rule = true;
          }
        }
      }
    }

    if (!added_any_rule) {
      gtk_file_filter_add_pattern(filter, "*");
    }

    if (out_filters != nullptr) {
      out_filters->push_back(filter);
    }
    gtk_file_chooser_add_filter(chooser, filter);
  }
}

void OnDialogResponse(GtkNativeDialog* native_dialog, gint response_id,
                      gpointer user_data) {
  auto* ctx = static_cast<DialogRequestContext*>(user_data);
  if (ctx->response_handler_id != 0UL) {
    g_signal_handler_disconnect(native_dialog, ctx->response_handler_id);
    ctx->response_handler_id = 0UL;
  }

  GtkFileChooser* chooser = GTK_FILE_CHOOSER(ctx->dialog);
  g_autoptr(FlValue) result = nullptr;

  if (response_id == GTK_RESPONSE_ACCEPT) {
    switch (ctx->kind) {
      case DialogKind::kOpenSingle:
      case DialogKind::kDirectorySingle: {
        g_autofree gchar* filename = gtk_file_chooser_get_filename(chooser);
        result = (filename != nullptr && filename[0] != '\0')
                     ? fl_value_new_string(filename)
                     : fl_value_new_null();
        break;
      }
      case DialogKind::kOpenMultiple:
      case DialogKind::kDirectoryMultiple: {
        result = fl_value_new_list();
        g_autoptr(GSList) filenames = gtk_file_chooser_get_filenames(chooser);
        for (GSList* link = filenames; link != nullptr; link = link->next) {
          g_autofree gchar* filename = static_cast<gchar*>(link->data);
          if (filename != nullptr && filename[0] != '\0') {
            fl_value_append_take(result, fl_value_new_string(filename));
          }
        }
        break;
      }
      case DialogKind::kSave: {
        g_autofree gchar* filename = gtk_file_chooser_get_filename(chooser);
        if (filename != nullptr && filename[0] != '\0') {
          result = fl_value_new_map();
          fl_value_set_string_take(result, "path",
                                   fl_value_new_string(filename));

          GtkFileFilter* active = gtk_file_chooser_get_filter(chooser);
          int active_index = -1;
          if (active != nullptr) {
            for (size_t i = 0; i < ctx->filters.size(); ++i) {
              if (ctx->filters[i] == active) {
                active_index = static_cast<int>(i);
                break;
              }
            }
          }
          if (active_index >= 0) {
            fl_value_set_string_take(result, "activeFilterIndex",
                                     fl_value_new_int(active_index));
          } else {
            fl_value_set_string_take(result, "activeFilterIndex",
                                     fl_value_new_null());
          }
        } else {
          result = fl_value_new_null();
        }
        break;
      }
    }
  } else {
    if (ctx->kind == DialogKind::kOpenMultiple ||
        ctx->kind == DialogKind::kDirectoryMultiple) {
      result = fl_value_new_list();
    } else {
      result = fl_value_new_null();
    }
  }

  fl_method_call_respond_success(ctx->method_call, result, nullptr);

  gtk_native_dialog_destroy(native_dialog);
  g_object_unref(ctx->dialog);
  g_object_unref(ctx->method_call);
  delete ctx;
}

void ShowNativeChooser(FileDropPlugin* self, FlMethodCall* method_call,
                       DialogKind kind) {
  FlView* view = fl_plugin_registrar_get_view(self->registrar);
  GtkWindow* parent_window = nullptr;
  if (view != nullptr) {
    GtkWidget* toplevel = gtk_widget_get_toplevel(GTK_WIDGET(view));
    if (GTK_IS_WINDOW(toplevel)) {
      parent_window = GTK_WINDOW(toplevel);
    }
  }

  FlValue* args = fl_method_call_get_args(method_call);

  GtkFileChooserAction action = GTK_FILE_CHOOSER_ACTION_OPEN;
  const gchar* title = "Open File";
  const gchar* default_accept = "_Open";
  bool select_multiple = false;

  switch (kind) {
    case DialogKind::kOpenSingle:
      action = GTK_FILE_CHOOSER_ACTION_OPEN;
      title = "Open File";
      default_accept = "_Open";
      select_multiple = false;
      break;
    case DialogKind::kOpenMultiple:
      action = GTK_FILE_CHOOSER_ACTION_OPEN;
      title = "Open Files";
      default_accept = "_Open";
      select_multiple = true;
      break;
    case DialogKind::kSave:
      action = GTK_FILE_CHOOSER_ACTION_SAVE;
      title = "Save File";
      default_accept = "_Save";
      select_multiple = false;
      break;
    case DialogKind::kDirectorySingle:
      action = GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER;
      title = "Select Directory";
      default_accept = "_Open";
      select_multiple = false;
      break;
    case DialogKind::kDirectoryMultiple:
      action = GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER;
      title = "Select Directories";
      default_accept = "_Open";
      select_multiple = true;
      break;
  }

  const gchar* confirm_text = LookupStringArg(args, "confirmButtonText");
  GtkFileChooserNative* dialog = gtk_file_chooser_native_new(
      title, parent_window, action,
      confirm_text != nullptr ? confirm_text : default_accept, "_Cancel");

  GtkFileChooser* chooser = GTK_FILE_CHOOSER(dialog);
  gtk_file_chooser_set_select_multiple(chooser, select_multiple ? TRUE : FALSE);

  if (kind == DialogKind::kSave) {
    gtk_file_chooser_set_do_overwrite_confirmation(chooser, TRUE);
    gtk_file_chooser_set_create_folders(
        chooser, LookupBoolArg(args, "canCreateDirectories", TRUE));
    const gchar* suggested_name = LookupStringArg(args, "suggestedName");
    if (suggested_name != nullptr) {
      gtk_file_chooser_set_current_name(chooser, suggested_name);
    }
  } else if (kind == DialogKind::kDirectorySingle ||
             kind == DialogKind::kDirectoryMultiple) {
    gtk_file_chooser_set_create_folders(
        chooser, LookupBoolArg(args, "canCreateDirectories", TRUE));
  }

  const gchar* initial_dir = LookupStringArg(args, "initialDirectory");
  if (initial_dir != nullptr) {
    gtk_file_chooser_set_current_folder(chooser, initial_dir);
  }

  auto* ctx = new DialogRequestContext{
      FL_METHOD_CALL(g_object_ref(method_call)),
      dialog,
      kind,
      0UL,
      {},
  };

  if (kind == DialogKind::kOpenSingle || kind == DialogKind::kOpenMultiple ||
      kind == DialogKind::kSave) {
    ApplyGtkFilters(chooser, args, &ctx->filters);
  }

  ctx->response_handler_id =
      g_signal_connect(dialog, "response", G_CALLBACK(OnDialogResponse), ctx);
  gtk_native_dialog_show(GTK_NATIVE_DIALOG(dialog));
}

// --- GTK3 Drag & Drop Callbacks ---
// Note: GTK3 `(gint x, gint y)` in `drag-motion` and `drag-drop` are ALREADY
// in GDK logical widget coordinates (never divide by gtk_widget_get_scale_factor).

FlValue* MakeCoordsMap(gint x, gint y) {
  FlValue* map = fl_value_new_map();
  fl_value_set_string_take(map, "x",
                           fl_value_new_float(static_cast<double>(x)));
  fl_value_set_string_take(map, "y",
                           fl_value_new_float(static_cast<double>(y)));
  return map;
}

GdkDragAction SelectDragAction(GdkDragContext* context) {
  const GdkDragAction actions = gdk_drag_context_get_actions(context);
  if ((actions & GDK_ACTION_COPY) != 0) {
    return GDK_ACTION_COPY;
  }
  if ((actions & GDK_ACTION_LINK) != 0) {
    return GDK_ACTION_LINK;
  }
  if ((actions & GDK_ACTION_MOVE) != 0) {
    return GDK_ACTION_MOVE;
  }
  return GDK_ACTION_COPY;
}

gboolean OnDragMotion(GtkWidget* widget, GdkDragContext* context, gint x,
                      gint y, guint time, gpointer user_data) {
  auto* self = FILE_DROP_PLUGIN(user_data);
  if (self->channel == nullptr) {
    return FALSE;
  }

  GdkAtom target = gtk_drag_dest_find_target(widget, context, nullptr);
  if (target == GDK_NONE) {
    gdk_drag_status(context, static_cast<GdkDragAction>(0), time);
    return FALSE;
  }

  self->drop_x = x;
  self->drop_y = y;
  self->has_drop_coords = TRUE;

  g_autoptr(FlValue) args = MakeCoordsMap(x, y);
  if (!self->is_dragging) {
    self->is_dragging = TRUE;
    fl_method_channel_invoke_method(self->channel, "onDragEntered", args,
                                    nullptr, nullptr, nullptr);
  } else {
    fl_method_channel_invoke_method(self->channel, "onDragUpdated", args,
                                    nullptr, nullptr, nullptr);
  }

  gdk_drag_status(context, SelectDragAction(context), time);
  return TRUE;
}

void OnDragLeave(GtkWidget* /*widget*/, GdkDragContext* /*context*/,
                 guint /*time*/, gpointer user_data) {
  auto* self = FILE_DROP_PLUGIN(user_data);
  if (self->is_dragging && self->channel != nullptr) {
    self->is_dragging = FALSE;
    fl_method_channel_invoke_method(self->channel, "onDragExited", nullptr,
                                    nullptr, nullptr, nullptr);
  }
}

gboolean OnDragDrop(GtkWidget* widget, GdkDragContext* context, gint x, gint y,
                    guint time, gpointer user_data) {
  auto* self = FILE_DROP_PLUGIN(user_data);
  GdkAtom target = gtk_drag_dest_find_target(widget, context, nullptr);
  if (target == GDK_NONE) {
    self->is_dragging = FALSE;
    self->has_drop_coords = FALSE;
    gtk_drag_finish(context, FALSE, FALSE, time);
    return FALSE;
  }

  self->drop_x = x;
  self->drop_y = y;
  self->has_drop_coords = TRUE;
  gtk_drag_get_data(widget, context, target, time);
  return TRUE;
}

void OnDragDataReceived(GtkWidget* /*widget*/, GdkDragContext* context, gint x,
                        gint y, GtkSelectionData* selection_data,
                        guint /*info*/, guint time, gpointer user_data) {
  auto* self = FILE_DROP_PLUGIN(user_data);
  const gint effective_x = self->has_drop_coords ? self->drop_x : x;
  const gint effective_y = self->has_drop_coords ? self->drop_y : y;
  self->is_dragging = FALSE;
  self->has_drop_coords = FALSE;

  const gint length = gtk_selection_data_get_length(selection_data);
  const guchar* raw_bytes = gtk_selection_data_get_data(selection_data);
  if (length <= 0 || raw_bytes == nullptr || self->channel == nullptr) {
    gtk_drag_finish(context, FALSE, FALSE, time);
    return;
  }

  std::string raw_text(reinterpret_cast<const char*>(raw_bytes),
                       static_cast<size_t>(length));
  while (!raw_text.empty() && raw_text.back() == '\0') {
    raw_text.pop_back();
  }

  g_autoptr(FlValue) items = fl_value_new_list();
  g_auto(GStrv) uris = g_uri_list_extract_uris(raw_text.c_str());
  for (gchar** uri = uris; uri != nullptr && *uri != nullptr; ++uri) {
    g_autofree gchar* hostname = nullptr;
    g_autofree gchar* local_path =
        g_filename_from_uri(*uri, &hostname, nullptr);
    if (local_path == nullptr || local_path[0] == '\0') {
      continue;
    }

    const gboolean is_dir = g_file_test(local_path, G_FILE_TEST_IS_DIR);
    FlValue* entry = fl_value_new_map();
    fl_value_set_string_take(entry, "path", fl_value_new_string(local_path));
    fl_value_set_string_take(entry, "isDirectory", fl_value_new_bool(is_dir));
    fl_value_append_take(items, entry);
  }

  g_autoptr(FlValue) payload = MakeCoordsMap(effective_x, effective_y);
  fl_value_set_string_take(payload, "rawText",
                           fl_value_new_string(raw_text.c_str()));
  fl_value_set_string_take(payload, "items", fl_value_ref(items));

  fl_method_channel_invoke_method(self->channel, "onDragDone", payload, nullptr,
                                  nullptr, nullptr);
  gtk_drag_finish(context, TRUE, FALSE, time);
}

void HandleMethodCall(FileDropPlugin* self, FlMethodCall* method_call) {
  const gchar* method = fl_method_call_get_name(method_call);

  if (std::strcmp(method, "openFile") == 0) {
    ShowNativeChooser(self, method_call, DialogKind::kOpenSingle);
  } else if (std::strcmp(method, "openFiles") == 0) {
    ShowNativeChooser(self, method_call, DialogKind::kOpenMultiple);
  } else if (std::strcmp(method, "getSaveLocation") == 0) {
    ShowNativeChooser(self, method_call, DialogKind::kSave);
  } else if (std::strcmp(method, "getDirectoryPath") == 0) {
    ShowNativeChooser(self, method_call, DialogKind::kDirectorySingle);
  } else if (std::strcmp(method, "getDirectoryPaths") == 0) {
    ShowNativeChooser(self, method_call, DialogKind::kDirectoryMultiple);
  } else if (std::strcmp(method, "startAccessingSecurityScopedResource") == 0) {
    g_autoptr(FlValue) res = fl_value_new_bool(FALSE);
    fl_method_call_respond_success(method_call, res, nullptr);
  } else if (std::strcmp(method, "stopAccessingSecurityScopedResource") == 0) {
    g_autoptr(FlValue) res = fl_value_new_bool(TRUE);
    fl_method_call_respond_success(method_call, res, nullptr);
  } else {
    fl_method_call_respond_not_implemented(method_call, nullptr);
  }
}

void MethodCallCallback(FlMethodChannel* /*channel*/, FlMethodCall* method_call,
                        gpointer user_data) {
  FileDropPlugin* plugin = FILE_DROP_PLUGIN(user_data);
  HandleMethodCall(plugin, method_call);
}

}  // namespace

static void file_drop_plugin_dispose(GObject* object) {
  FileDropPlugin* self = FILE_DROP_PLUGIN(object);
  if (self->channel != nullptr) {
    fl_method_channel_set_method_call_handler(self->channel, nullptr, nullptr,
                                              nullptr);
  }
  g_clear_object(&self->channel);
  g_clear_object(&self->registrar);
  G_OBJECT_CLASS(file_drop_plugin_parent_class)->dispose(object);
}

static void file_drop_plugin_class_init(FileDropPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = file_drop_plugin_dispose;
}

static void file_drop_plugin_init(FileDropPlugin* self) {
  self->registrar = nullptr;
  self->channel = nullptr;
  self->is_dragging = FALSE;
  self->has_drop_coords = FALSE;
  self->drop_x = 0;
  self->drop_y = 0;
}

void file_drop_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  FileDropPlugin* plugin =
      FILE_DROP_PLUGIN(g_object_new(file_drop_plugin_get_type(), nullptr));
  plugin->registrar = FL_PLUGIN_REGISTRAR(g_object_ref(registrar));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  plugin->channel =
      fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar),
                            "com.infradise.file_drop", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(plugin->channel, MethodCallCallback,
                                            plugin, nullptr);

  FlView* view = fl_plugin_registrar_get_view(registrar);
  if (view != nullptr) {
    GtkWidget* widget = GTK_WIDGET(view);
    GtkTargetEntry entries[] = {
        {const_cast<gchar*>("text/uri-list"), 0, 0},
    };
    gtk_drag_dest_set(
        widget, static_cast<GtkDestDefaults>(0), entries, G_N_ELEMENTS(entries),
        static_cast<GdkDragAction>(GDK_ACTION_COPY | GDK_ACTION_MOVE |
                                   GDK_ACTION_LINK));
    gtk_drag_dest_add_uri_targets(widget);
    gtk_drag_dest_set_track_motion(widget, TRUE);

    g_signal_connect_object(widget, "drag-motion", G_CALLBACK(OnDragMotion),
                            plugin, static_cast<GConnectFlags>(0));
    g_signal_connect_object(widget, "drag-leave", G_CALLBACK(OnDragLeave),
                            plugin, static_cast<GConnectFlags>(0));
    g_signal_connect_object(widget, "drag-drop", G_CALLBACK(OnDragDrop), plugin,
                            static_cast<GConnectFlags>(0));
    g_signal_connect_object(widget, "drag-data-received",
                            G_CALLBACK(OnDragDataReceived), plugin,
                            static_cast<GConnectFlags>(0));
  }

  g_object_set_data_full(G_OBJECT(registrar), "com.infradise.file_drop.plugin",
                         plugin, g_object_unref);
}
