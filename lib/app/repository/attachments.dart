import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// 本地插图附件存储（task-29 富文本；task-30 图片跨设备同步扩展）。
///
/// 图片经 [saveImage] 压缩后存入应用支持目录的 `attachments/` 子目录，
/// 文件名 = 内容 sha256 前 16 位 + `.jpg`（内容寻址：同一图片去重、重复
/// 插入不产生副本）。delta embed 节点仅存相对路径 `attachments/<hash>.jpg`，
/// 渲染时经 [resolveFile] 解析为绝对路径（编辑器 embed builder 用）。
///
/// **跨设备同步（task-30，协议 v4）**：接收方在笔记合并后解析 delta 中的
/// 图片引用，本地缺失时经同步层发 file_request 向对端请求；对端分片传输
/// （64KB → base64），本类提供分片写入临时文件（.part）→ [finalize] 校验
/// sha256 后重命名落盘的完整链路。落盘成功后经静态事件流 [attachmentReady]
/// 通知 UI（_LocalImageEmbedBuilder 重建 Image.file）。
///
/// **纯 Dart 设计（task-30）**：本文件不依赖 Flutter/path_provider——附件
/// 目录由 [directoryProvider] 注入（生产默认见 providers.dart
/// [defaultAttachmentsDirectory]；联调脚本注入临时目录）。联调脚本
/// （temp/drafts/verify_sync.dart）用 `dart run` 驱动真实网络栈，不能引入
/// Flutter 依赖，因此存储层必须保持纯 Dart。
///
/// 附件随应用卸载删除；笔记清空后不再被引用的图片成为孤儿文件，暂不
/// 回收（个人量级可忽略，见 docs/开发进度.md 遗留问题）。
class AttachmentsStore {
  AttachmentsStore({Future<Directory> Function()? directoryProvider})
      : _directoryProvider = directoryProvider;

  /// attachments 子目录名（delta embed 相对路径的第一段）。
  static const String dirName = 'attachments';

  /// 单文件大小上限（20MB，task-30 安全边界）：
  /// - 发送方收到 file_request 时 expectedSize 超限 → 拒绝；
  /// - 接收方分片累计字节超限 → 中断传输并丢弃临时文件。
  static const int maxFileSizeBytes = 20 * 1024 * 1024;

  /// 附件 hash 合法性：内容寻址文件名主体（sha256 前 16 位十六进制）。
  static final RegExp _hashPattern = RegExp(r'^[a-f0-9]{16}$');

  /// 附件就绪事件（静态广播，task-30）：任一实例 [finalize] 校验成功落盘后
  /// 发出就绪 hash，UI（_LocalImageEmbedBuilder）订阅后重建 Image.file。
  ///
  /// 用静态流解耦实例：编辑器与同步层各自持有 AttachmentsStore 实例（同一
  /// 目录），但就绪事件是全局事件，静态广播保证任一实例落盘都能通知到 UI。
  static final StreamController<String> _readyController =
      StreamController<String>.broadcast();

  /// 附件就绪事件流（就绪 hash：sha256 前 16 位）。
  static Stream<String> get attachmentReady => _readyController.stream;

  /// 附件目录解析器（生产由 providers.dart 注入应用支持目录；测试注入临时
  /// 目录）。为 null 时兜底到系统临时目录（联调脚本未注入时可用）。
  final Future<Directory> Function()? _directoryProvider;

  Future<Directory>? _cachedDir;

  /// attachments 目录（懒解析并缓存；已存在则复用）。
  Future<Directory> get directory => _cachedDir ??= _resolveDir();

  Future<Directory> _resolveDir() async {
    final provider = _directoryProvider;
    if (provider != null) {
      final dir = await provider();
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return dir;
    }
    // 纯 Dart 兜底：系统临时目录随机子目录（生产必须注入，见 providers.dart）。
    return Directory.systemTemp.createTemp('lan_notes_attachments');
  }

  /// hash 是否合法（16 位十六进制；非法 hash 直接拒绝，防路径注入）。
  static bool isValidHash(String hash) => _hashPattern.hasMatch(hash);

  /// 附件是否已存在：有 ext 查 `attachments/<hash>.<ext>`；无 ext 扫描目录
  /// 匹配 `attachments/<hash>.*`（兼容旧 .jpg 命名）。
  Future<bool> exists(String hash, {String? ext}) async {
    if (!isValidHash(hash)) return false;
    final dir = await directory;
    if (ext != null && ext.isNotEmpty) {
      return File(p.join(dir.path, '$hash.$ext')).existsSync();
    }
    return _findByHash(dir, hash) != null;
  }

  /// 按 hash 扫描附件目录查找文件（任意扩展名）；找不到返回 null。
  Future<File?> resolveByHash(String hash) async {
    if (!isValidHash(hash)) return null;
    final dir = await directory;
    return _findByHash(dir, hash);
  }

  /// 目录内按 `<hash>.*` 前缀查找（内容寻址命名：hash 主体唯一）。
  ///
  /// **排除 `.part` 分片临时文件**（task-30 修复）：分片传输过程中产生的
  /// `<hash>.part` 不算「文件已存在」——否则 `exists()`/`resolveByHash()`
  /// 会把它误判为已完成文件，导致断线重连/修复后不再重新请求（曾致
  /// 附件重传校验 FAIL）。
  File? _findByHash(Directory dir, String hash) {
    if (!dir.existsSync()) return null;
    for (final entry in dir.listSync()) {
      if (entry is File) {
        final name = entry.uri.pathSegments.last;
        if (name.startsWith('$hash.') && !name.endsWith('.part')) {
          return entry;
        }
      }
    }
    return null;
  }

  /// 创建分片接收临时文件（`<hash>.part`）；已存在则截断（重传场景）。
  Future<void> createTemp(String hash) async {
    if (!isValidHash(hash)) return;
    final dir = await directory;
    final temp = File(p.join(dir.path, '$hash.part'));
    await temp.writeAsBytes(const [], flush: true);
  }

  /// 追加分片字节到临时文件（顺序到达——WebSocket 保序，简单按序追加；
  /// 内容正确性由 [finalize] 的 sha256 校验兜底）。
  Future<void> appendChunk(String hash, Uint8List bytes) async {
    if (!isValidHash(hash) || bytes.isEmpty) return;
    final dir = await directory;
    final temp = File(p.join(dir.path, '$hash.part'));
    final raf = await temp.open(mode: FileMode.append);
    try {
      await raf.writeFrom(bytes);
    } finally {
      await raf.close();
    }
  }

  /// 校验并落盘：读临时文件 → sha256 前 16 位 == [hash] → 重命名为
  /// `attachments/<hash>.jpg` → 删除临时文件。
  ///
  /// 校验失败（数据被篡改/不完整）：删除临时文件返回 false（调用方可重新
  /// 请求）；成功时经 [attachmentReady] 发出就绪通知（UI 刷新）。
  Future<bool> finalize(String hash, {String? ext}) async {
    if (!isValidHash(hash)) return false;
    final dir = await directory;
    final temp = File(p.join(dir.path, '$hash.part'));
    final name = (ext != null && ext.isNotEmpty) ? '$hash.$ext' : '$hash.jpg';
    final target = File(p.join(dir.path, name));
    try {
      if (!await temp.exists()) return false;
      final bytes = await temp.readAsBytes();
      final actual = sha256.convert(bytes).toString().substring(0, 16);
      if (actual != hash) {
        await temp.delete();
        return false;
      }
      // 目标已存在（重传/内容寻址去重）：直接删临时即可。
      if (await target.exists()) {
        await temp.delete();
      } else {
        await temp.rename(target.path);
      }
      if (!_readyController.isClosed) {
        _readyController.add(hash);
      }
      return true;
    } catch (_) {
      if (await temp.exists()) {
        await temp.delete();
      }
      return false;
    }
  }

  /// 丢弃临时文件（会话断开中断传输 / 校验失败 / 大小超限）。
  Future<void> discardTemp(String hash) async {
    if (!isValidHash(hash)) return;
    final dir = await directory;
    final temp = File(p.join(dir.path, '$hash.part'));
    if (await temp.exists()) {
      await temp.delete();
    }
  }

  /// 临时文件是否存在（联调脚本断言传输进行中/已清理用）。
  Future<bool> tempExists(String hash) async {
    if (!isValidHash(hash)) return false;
    final dir = await directory;
    return File(p.join(dir.path, '$hash.part')).existsSync();
  }

  /// 读取附件文件字节（联调脚本断言内容 sha256 一致用）；不存在返回 null。
  Future<Uint8List?> readFile(String hash) async {
    if (!isValidHash(hash)) return null;
    final dir = await directory;
    final file = File(p.join(dir.path, '$hash.jpg'));
    if (!file.existsSync()) return null;
    return file.readAsBytes();
  }

  /// 保存图片**原始字节**（不压缩不缩放，用户确认：绝对原图），
  /// 返回 delta embed 相对路径（`attachments/<hash>.<ext>`）。
  ///
  /// 扩展名按文件 magic 判断（jpg/png/gif/webp/bmp/heic）；
  /// 无法识别格式抛 [FormatException]。
  Future<String> saveImage(Uint8List bytes) async {
    final ext = _extensionFor(bytes);
    if (ext == null) {
      throw const FormatException('无法识别的图片格式');
    }
    final hash = sha256.convert(bytes).toString().substring(0, 16);
    final name = '$hash.$ext';
    final dir = await directory;
    final file = File(p.join(dir.path, name));
    if (!await file.exists()) {
      await file.writeAsBytes(bytes, flush: true);
    }
    return '$dirName/$name';
  }

  /// 按文件头 magic 判断图片扩展名；未知返回 null。
  static String? _extensionFor(Uint8List bytes) {
    if (bytes.length < 12) return null;
    // JPEG: FFD8FF
    if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) return 'jpg';
    // PNG: 89504E47
    if (bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47) {
      return 'png';
    }
    // GIF: GIF87a / GIF89a
    if (bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x38) {
      return 'gif';
    }
    // WebP: RIFF....WEBP
    if (bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46 &&
        bytes[8] == 0x57 && bytes[9] == 0x45 && bytes[10] == 0x42 && bytes[11] == 0x50) {
      return 'webp';
    }
    // BMP: BM
    if (bytes[0] == 0x42 && bytes[1] == 0x4D) return 'bmp';
    // HEIC/HEIF: ftyp 盒（ftypheic/ftypheix/ftypmif1 等）
    if (bytes[4] == 0x66 && bytes[5] == 0x74 && bytes[6] == 0x79 && bytes[7] == 0x70) {
      return 'heic';
    }
    return null;
  }

  /// 把 delta embed 相对路径（`attachments/<hash>.jpg`）解析为绝对文件；
  /// 文件不存在返回 null（对端未同步附件等场景，embed builder 渲染占位）。
  ///
  /// 只取 basename 参与拼接，防止异常数据中的目录穿越。
  Future<File?> resolveFile(String relativePath) async {
    final dir = await directory;
    final file = File(p.join(dir.path, p.basename(relativePath)));
    return file.existsSync() ? file : null;
  }


}
