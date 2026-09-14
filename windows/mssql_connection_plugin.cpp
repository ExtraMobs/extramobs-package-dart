#include "include/mssql/mssql_connection_plugin.h"

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <memory>

namespace mssql_connection {

class MssqlConnectionPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  MssqlConnectionPlugin();

  virtual ~MssqlConnectionPlugin();

  // Disallow copy and assign.
  MssqlConnectionPlugin(const MssqlConnectionPlugin&) = delete;
  MssqlConnectionPlugin& operator=(const MssqlConnectionPlugin&) = delete;
};

// static
void MssqlConnectionPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows *registrar) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "mssql_connection",
          &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<MssqlConnectionPlugin>();

  channel->SetMethodCallHandler(
      [](const auto &call, auto result) {
        result->NotImplemented();
      });

  registrar->AddPlugin(std::move(plugin));
}

MssqlConnectionPlugin::MssqlConnectionPlugin() {}

MssqlConnectionPlugin::~MssqlConnectionPlugin() {}

}  // namespace mssql_connection

void MssqlConnectionPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  mssql_connection::MssqlConnectionPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
