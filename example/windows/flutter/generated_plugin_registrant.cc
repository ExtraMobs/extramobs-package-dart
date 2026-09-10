//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <extramobs/extramobs_plugin_c_api.h>
#include <mssql/mssql_connection_plugin.h>

void RegisterPlugins(flutter::PluginRegistry* registry) {
  ExtramobsPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("ExtramobsPluginCApi"));
  MssqlConnectionPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("MssqlConnectionPlugin"));
}
