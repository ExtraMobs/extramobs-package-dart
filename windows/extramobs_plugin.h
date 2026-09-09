#ifndef FLUTTER_PLUGIN_EXTRAMOBS_PLUGIN_H_
#define FLUTTER_PLUGIN_EXTRAMOBS_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>

namespace extramobs {

class ExtramobsPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  ExtramobsPlugin();

  virtual ~ExtramobsPlugin();

  // Disallow copy and assign.
  ExtramobsPlugin(const ExtramobsPlugin&) = delete;
  ExtramobsPlugin& operator=(const ExtramobsPlugin&) = delete;

  // Called when a method is called on this plugin's channel from Dart.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
};

}  // namespace extramobs

#endif  // FLUTTER_PLUGIN_EXTRAMOBS_PLUGIN_H_
