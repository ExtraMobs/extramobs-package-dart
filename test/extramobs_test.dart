import 'package:flutter_test/flutter_test.dart';
import 'package:extramobs/extramobs.dart';
import 'package:extramobs/extramobs_platform_interface.dart';
import 'package:extramobs/extramobs_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockExtramobsPlatform
    with MockPlatformInterfaceMixin
    implements ExtramobsPlatform {
  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final ExtramobsPlatform initialPlatform = ExtramobsPlatform.instance;

  test('$MethodChannelExtramobs is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelExtramobs>());
  });

  test('getPlatformVersion', () async {
    Extramobs extramobsPlugin = Extramobs();
    MockExtramobsPlatform fakePlatform = MockExtramobsPlatform();
    ExtramobsPlatform.instance = fakePlatform;

    expect(await extramobsPlugin.getPlatformVersion(), '42');
  });
}
