// 剪贴板 HTML 净化回归：粘网页/Office 内容时不能把 CF_HTML 的包装痕迹
// （描述头、SourceURL、片段外的上下文）带进正文。
//
// 背景：本项目的粘贴链路是「剪贴板 HTML → html 包 parse → DeltaX.fromHtml」，
// 解析器不会丢掉文档外的文本（会塞进 `body`），而上游
// quill_native_bridge_windows 的 stripWindowsHtmlDescriptionHeaders 漏掉了
// SourceURL，导致 Windows 上从浏览器复制会粘出 "SourceURL:http://…" 垃圾行。
import 'package:flutter_test/flutter_test.dart';

import 'package:lan_notes/app/repository/quill_clipboard.dart';

/// Chrome/Edge 在 Windows 上写入剪贴板的 CF_HTML（`clipboard_util_win.cc` 的
/// 拼接顺序：描述头 → SourceURL → `<html>`），即 SourceURL 在 `<html>` 之前。
const _windowsCfHtml = 'Version:0.9\r\n'
    'StartHTML:0000000105\r\n'
    'EndHTML:0000000300\r\n'
    'StartFragment:0000000141\r\n'
    'EndFragment:0000000280\r\n'
    'SourceURL:http://127.0.0.1:8890/\r\n'
    '<html>\r\n'
    '<body>\r\n'
    '<!--StartFragment--><span>qwen3-reranker-8b</span><!--EndFragment-->\r\n'
    '</body>\r\n'
    '</html>';

void main() {
  group('sanitizeClipboardHtml', () {
    test('完整 CF_HTML：只保留片段内容，描述头与 SourceURL 全丢', () {
      expect(
        sanitizeClipboardHtml(_windowsCfHtml),
        '<span>qwen3-reranker-8b</span>',
      );
    });

    test('Windows 桥接净化后残留的 SourceURL 行（头已被删掉）也会丢掉', () {
      // quill_native_bridge_windows 0.0.2 的真实输出：Version/StartHTML 等
      // 被删，SourceURL 留在 <html> 之前。
      const cleanedByBridge = '\r\n'
          'SourceURL:http://127.0.0.1:8890/\r\n'
          '<html>\r\n'
          '<body>\r\n'
          '<!--StartFragment--><span>qwen3-reranker-8b</span><!--EndFragment-->\r\n'
          '</body>\r\n'
          '</html>';
      expect(
        sanitizeClipboardHtml(cleanedByBridge),
        '<span>qwen3-reranker-8b</span>',
      );
    });

    test('SourceURL 压在 </html> 之后（尾随上下文）会丢掉', () {
      const trailing = '<html><body>'
          '<!--StartFragment-->正文<!--EndFragment-->'
          '</body></html>\nSourceURL:http://127.0.0.1:8890/';
      expect(sanitizeClipboardHtml(trailing), '正文');
    });

    test('无片段标记时，</body> 后的 SourceURL 行同样清掉', () {
      const trailingNoMarkers = '<html><body><p>正文</p></body></html>\r\n'
          '<br>\r\nSourceURL:http://127.0.0.1:8890/';
      expect(sanitizeClipboardHtml(trailingNoMarkers), '<html><body><p>正文</p></body></html>');
    });

    test('Chrome/macOS 的原生剪贴板 HTML（<meta charset> 前缀）原样通过', () {
      const chromeMac = "<meta charset='utf-8'><b>粗体</b> 正文";
      expect(sanitizeClipboardHtml(chromeMac), chromeMac);
    });

    test('普通网页片段（无任何包装）原样通过', () {
      const plain = '<div>第一段</div><div>第二段</div>';
      expect(sanitizeClipboardHtml(plain), plain);
    });

    test('正文中间出现的 SourceURL 文本不受影响', () {
      const doc = '<p>配置示例：</p><p>SourceURL:http://127.0.0.1:8890/</p>'
          '<p>正文继续</p>';
      expect(sanitizeClipboardHtml(doc), doc);
    });

    test('空串与纯文本不会被改动', () {
      expect(sanitizeClipboardHtml(''), '');
      expect(sanitizeClipboardHtml('普通文本，没有标签'), '普通文本，没有标签');
    });
  });
}
