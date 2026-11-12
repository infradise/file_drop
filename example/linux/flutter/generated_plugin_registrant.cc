//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <file_drop/file_drop_plugin.h>

void fl_register_plugins(FlPluginRegistry* registry) {
  g_autoptr(FlPluginRegistrar) file_drop_registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "FileDropPlugin");
  file_drop_plugin_register_with_registrar(file_drop_registrar);
}
