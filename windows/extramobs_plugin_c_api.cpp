#include "include/extramobs/extramobs_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "extramobs_plugin.h"

void ExtramobsPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  extramobs::ExtramobsPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
