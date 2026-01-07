//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <ti_printer_plugin/ti_printer_plugin.h>

void fl_register_plugins(FlPluginRegistry* registry) {
  g_autoptr(FlPluginRegistrar) ti_printer_plugin_registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "TiPrinterPlugin");
  ti_printer_plugin_register_with_registrar(ti_printer_plugin_registrar);
}
