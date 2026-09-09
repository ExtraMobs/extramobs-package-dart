import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'extramobs_method_channel.dart';

abstract class ExtramobsPlatform extends PlatformInterface {
  /// Constructs a ExtramobsPlatform.
  ExtramobsPlatform() : super(token: _token);

  static final Object _token = Object();

  static ExtramobsPlatform _instance = MethodChannelExtramobs();

  /// The default instance of [ExtramobsPlatform] to use.
  ///
  /// Defaults to [MethodChannelExtramobs].
  static ExtramobsPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [ExtramobsPlatform] when
  /// they register themselves.
  static set instance(ExtramobsPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
