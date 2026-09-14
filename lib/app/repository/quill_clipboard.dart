// 本文件整体建立在 quill 的剪贴板扩展点上，它们都标着 @experimental：
// `package:flutter_quill/internal.dart` 是官方给相关包/宿主用的内部 barrel
// （剪贴板接口的公开扩展点只有它），版本又已被本地 fork 锁定（pubspec 的
// dependency_overrides 指向 third_party），因此统一忽略 experimental 告警。
// ignore_for_file: experimental_member_use
import 'dart:io' as io;

import 'package:flutter/foundation.dart';
import 'package:flutter_quill/internal.dart';

// 剪贴板 HTML 净化：把「外部程序写进剪贴板的包装痕迹」挡在解析之前。
//
// 为什么要做：网页 / Office / 远程桌面等来源写富文本剪贴板时，用到的往往不只是
// HTML，而是 Windows 的 CF_HTML 包装：
//
//   Version:1.0 / StartHTML / EndHTML / StartFragment / EndFragment / SourceURL  ← 描述头
//   <html><body><!--StartFragment-->真正的片段<!--EndFragment--></body></html>   ← 上下文
//
// 其中 SourceURL 是**描述头里的元数据**（原本用途是让接收方解析片段里的相对
// 链接），不是内容。微软规范把它和 StartHTML 等并列在描述头里：
// https://learn.microsoft.com/en-us/windows/win32/dataxchg/html-clipboard-format
//
// 本项目的富文本粘贴链路是
//   ClipboardService.getHtmlText() → html 包 parse → DeltaX.fromHtml()
// 而「文档外」的文本不会被解析器丢掉（实测：<html> 之前的文本会被塞进 <body>），
// 所以任何没被清掉的包装行都会变成笔记正文。上游
// quill_native_bridge_windows 的 stripWindowsHtmlDescriptionHeaders 只删
// Version/StartHTML/EndHTML/StartFragment/EndFragment/StartSelection/EndSelection，
// **漏了 SourceURL** —— Windows 上从浏览器复制就会在正文里出现
// 「SourceURL:http://…」这种垃圾行（本机已实测命中：Windows 端创建的笔记
// 同步过来后正文里带 SourceURL）。
//
// 编辑器开发对这个是有惯例的：粘贴一律视为不可信输入，**先净化再解析**。
//   - ProseMirror：transformPastedHTML「用于在解析前改写粘贴进来的 HTML，
//     例如把它清理干净」https://prosemirror.net/docs/ref/#view.EditorProps.transformPastedHTML
//   - CKEditor 5：ClipboardPipeline + PasteFromOffice，按来源归一化成干净 HTML
//     https://ckeditor.com/docs/ckeditor5/latest/features/paste-from-word.html
// 因此这里不是「过度防御」，而是粘贴链路的常规一环。

/// CF_HTML 描述头字段名（微软规范定义，Chrome/Edge/IE/Office 均按此输出）。
///
/// 列表必须完整——上游 Windows 桥接漏掉 [SourceURL] 正是这次污染的根因，
/// 所以这里把规范里的字段收全。
const _cfHtmlHeaderKeys = <String>[
  'Version',
  'StartHTML',
  'EndHTML',
  'StartFragment',
  'EndFragment',
  'StartSelection',
  'EndSelection',
  'SourceURL',
];

/// 描述头行：`字段名:值`（值可为空，行尾 \r?\n 一并吃掉）。
final _descriptionHeaderLine = RegExp(
  '^(?:${_cfHtmlHeaderKeys.join('|')}):[^\\r\\n]*\\r?\\n?',
  caseSensitive: false,
);

/// 行首的空行（生产者常把头与文档用空行隔开）。
final _leadingBlankLines = RegExp(r'^(?:[ \t]*\r?\n)+');

/// `</html>` / `</body>` 之后紧跟（中间只允许空白或 `<br>`）的 SourceURL 行：
/// 有部分生产方不把它放进描述头，而是当作「尾随上下文」追加在文档末尾。
final _trailingSourceUrl = RegExp(
  r'(</(?:html|body)>)[\s]*(?:<br\s*/?>[\s]*)*SourceURL:\S*[\s]*$',
  caseSensitive: false,
);

/// 净化从系统剪贴板读到的 HTML，返回可直接交给解析器的内容。
///
/// 三步（都对正常 HTML 无副作用）：
///  1. 丢掉开头的 CF_HTML 描述头（含 SourceURL）——只处理字符串最开头连续的
///     已知字段行，避免误删正文中间同名文本；
///  2. 有 `<!--StartFragment-->` / `<!--EndFragment-->` 时只取标记之间的内容
///     （规范定义的「用户真正选中的片段」，同时甩掉上下文与尾随上下文）；
///  3. 兜底：删掉跟在 `</html>` / `</body>` 之后的 SourceURL 行。
String sanitizeClipboardHtml(String raw) {
  if (raw.isEmpty) return raw;
  var html = _stripDescriptionHeader(raw);
  html = _extractFragment(html);
  html = _stripTrailingSourceUrl(html);
  return html.isEmpty ? raw : html;
}

String _stripDescriptionHeader(String html) {
  var rest = html;
  var stripped = false;
  // 头与文档之间、以及被删行留下的空行
  rest = rest.replaceFirst(_leadingBlankLines, '');
  while (true) {
    final match = _descriptionHeaderLine.firstMatch(rest);
    if (match == null) break;
    stripped = true;
    rest = rest.substring(match.end);
  }
  if (!stripped) return html;
  return rest.replaceFirst(_leadingBlankLines, '');
}

String _extractFragment(String html) {
  final start = _markerEnd(html, 'StartFragment');
  if (start == null) return html;
  final end = _markerEnd(html, 'EndFragment');
  if (end == null || end <= start) return html;
  final fragment = html.substring(start, _markerStart(html, 'EndFragment')!);
  return fragment.isEmpty ? html : fragment;
}

/// `<!-- 名字 -->` 注释标记的起始位置（不满是 `>` 前的空格差异）。
int? _markerStart(String html, String name) {
  final index = html.indexOf('<!--$name');
  return index < 0 ? null : index;
}

/// 注释标记「结束」后的下标（即片段内容的起点）。
int? _markerEnd(String html, String name) {
  final start = _markerStart(html, name);
  if (start == null) return null;
  final close = html.indexOf('>', start);
  return close < 0 ? null : close + 1;
}

String _stripTrailingSourceUrl(String html) {
  return html.replaceFirstMapped(
    _trailingSourceUrl,
    (match) => match.group(1) ?? '',
  );
}

/// 把净化挂进 quill 的剪贴板入口。
///
/// quill 的富文本粘贴只从 [ClipboardServiceProvider] 取 HTML，所有粘贴入口
/// （⌘V / 右键菜单「粘贴」 / 工具栏按钮）都会经过它，所以这是唯一需要拦截的点。
void installSanitizingClipboardService() {
  ClipboardServiceProvider.setInstance(SanitizingClipboardService());
}

/// 与 quill 自带的 `DefaultClipboardService` 行为一致，仅在读取 HTML 时净化。
///
/// 不直接继承自带实现是因为它没有对外导出（只有 [ClipboardService] 与
/// [ClipboardServiceProvider] 在 `package:flutter_quill/internal.dart` 里）；
/// 各方法都是对 [QuillNativeProvider] 的薄封装，升级 quill 时留意是否新增能力。
class SanitizingClipboardService extends ClipboardService {
  SanitizingClipboardService();

  Future<bool> _supported(QuillNativeBridgeFeature feature) {
    return QuillNativeProvider.instance.isSupported(feature);
  }

  @override
  Future<String?> getHtmlText() async {
    if (!await _supported(QuillNativeBridgeFeature.getClipboardHtml)) {
      return null;
    }
    final html = await QuillNativeProvider.instance.getClipboardHtml();
    return html == null ? null : sanitizeClipboardHtml(html);
  }

  @override
  Future<String?> getHtmlFile() async {
    final text = await _readClipboardFile('html');
    return text == null ? null : sanitizeClipboardHtml(text);
  }

  @override
  Future<String?> getMarkdownFile() => _readClipboardFile('md');

  @override
  Future<Uint8List?> getImageFile() async {
    if (!await _supported(QuillNativeBridgeFeature.getClipboardImage)) {
      return null;
    }
    return QuillNativeProvider.instance.getClipboardImage();
  }

  @override
  Future<Uint8List?> getGifFile() async {
    if (!await _supported(QuillNativeBridgeFeature.getClipboardGif)) {
      return null;
    }
    return QuillNativeProvider.instance.getClipboardGif();
  }

  @override
  Future<void> copyImage(Uint8List imageBytes) async {
    if (!await _supported(
      QuillNativeBridgeFeature.copyImageToClipboard,
    )) {
      return;
    }
    await QuillNativeProvider.instance.copyImageToClipboard(imageBytes);
  }

  Future<String?> _readClipboardFile(String extension) async {
    if (!await _supported(QuillNativeBridgeFeature.getClipboardFiles)) {
      return null;
    }
    if (kIsWeb) {
      // 与上游一致：Web 上拿不到文件路径（dart:io 不可用）。
      return null;
    }
    final paths = await QuillNativeProvider.instance.getClipboardFiles();
    final path = paths.firstWhere(
      (path) => path.endsWith('.$extension'),
      orElse: () => '',
    );
    if (path.isEmpty) return null;
    return io.File(path).readAsString();
  }
}
