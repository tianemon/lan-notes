// verify_sync 全链路联调脚本包装：把 temp/drafts/verify_sync.dart 的 97
// 场景纳入 flutter test 链路（脚本原注释的 `dart run` 入口在纯 Dart VM 下
// 无法编译 Flutter 框架源码）。真实网络栈 + 真实 UDP 场景整体耗时数分钟，
// 单独运行：flutter test test/verify_sync_runner_test.dart
import 'package:flutter_test/flutter_test.dart';

import '../temp/drafts/verify_sync.dart' as verify;

void main() {
  test('verify_sync 97 场景全链路', () async {
    await verify.main();
  }, timeout: const Timeout(Duration(minutes: 15)), tags: 'manual');
}
