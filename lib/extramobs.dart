
import 'extramobs_platform_interface.dart';

class Extramobs {
  Future<String?> getPlatformVersion() {
    return ExtramobsPlatform.instance.getPlatformVersion();
  }
}
