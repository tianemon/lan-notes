import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:gal/gal.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/note.dart';
import '../repository/attachments.dart';
import '../repository/providers.dart';
import 'widgets/editor_search_panel.dart';
import 'widgets/glass_style.dart';
import '../theme.dart';

/// 保存状态：保存中 / 已保存 / 保存失败。
///
/// 新建且尚无任何内容时无状态可显示（编辑器内用 null 表示）。
enum _SaveStatus { saving, saved, error }

/// 笔记编辑页（自动保存，见 docs/技术架构.md 第 4/5/6 节）。
///
/// 路由 `/editor/:id?`：无 [id] 为新建模式，首次自动保存时经
/// [NoteRepository.createNote] 创建（UUID v4），随后把路由替换为编辑态
/// `/editor/<id>`（避免刷新后回到新建态）；有 [id] 为编辑模式，经
/// [editorNoteProvider]（单条笔记流）加载并实时同步已有笔记。
///
/// 自动保存：标题/正文任一变更防抖 1s 后写库（新建→创建、已有→更新，
/// version 由仓库自动递增），AppBar 显示保存状态；返回前若仍有未保存
/// 变更则立即兜底保存。
///
/// 编辑模式实时同步（task-18）：有 [id] 时订阅 [editorNoteProvider] 流——
/// 另一台设备修改当前笔记（远端 mergeRemoteNote 写库）后 drift 自动推送，
/// 本页直接替换标题/正文输入框内容（LWW 强覆盖，最后保存者赢；本地未保存
/// 输入可能被覆盖，用户已确认接受）；本地保存写库回推内容与当前输入一致时
/// 跳过，避免光标跳动/输入打断。
///
/// 富文本（task-29）：正文由纯文本 TextField 换为 QuillEditor（所见即所得），
/// content 存 delta JSON（Quill Document 序列化）；自动保存 / 实时同步 / 字数
/// 统计均按 delta 适配；本地插图经 [AttachmentsStore] 压缩落盘后以 embed 节点
/// 引用（`attachments/<hash>.jpg`），渲染走 [_LocalImageEmbedBuilder]。
class EditorPage extends ConsumerStatefulWidget {
  const EditorPage({super.key, this.id});

  /// 待编辑笔记 id；为 null 表示新建。
  final String? id;

  @override
  ConsumerState<EditorPage> createState() => _EditorPageState();
}

/// 搜索高亮每次跳转都新建一个 AnimationController（旧的高亮先 dispose），
/// 故用 TickerProviderStateMixin——Single 版本在整个 State 生命周期只允许
/// 创建一个 ticker，第二次跳转必抛断言（表现：高亮只生效一次）。
class _EditorPageState extends ConsumerState<EditorPage>
    with TickerProviderStateMixin {
  /// 内容变更到触发保存的防抖时长。
  static const Duration _debounceDuration = Duration(seconds: 1);

  /// 持续输入强制保存的最大间隔（idle 防抖之外的上限）：
  /// 防止一直输入导致防抖反复重置、长期不落盘。
  static const Duration _maxSaveInterval = Duration(seconds: 5);

  /// 搜索关键词高亮总时长：保持 2s + 渐隐 0.8s（用户确认交互）。
  static const Duration _highlightDuration = Duration(milliseconds: 2800);

  final TextEditingController _titleController = TextEditingController();
  final FocusNode _titleFocusNode = FocusNode();

  /// 正文富文本控制器（task-29）：QuillEditor 所见即所得，内容序列化为
  /// delta JSON 存库。
  final QuillController _contentController = QuillController.basic();
  final FocusNode _contentFocusNode = FocusNode();
  final ScrollController _contentScrollController = ScrollController();

  /// 本地插图存储（task-29）：压缩落盘 + 路径解析（task-30 目录注入：
  /// 生产默认应用支持目录，见 providers.dart defaultAttachmentsDirectory）。
  static final AttachmentsStore _attachments = AttachmentsStore(
    directoryProvider: defaultAttachmentsDirectory,
  );

  /// 正文文档变化订阅（_attachDocListener 管理，替换文档后重建）。
  StreamSubscription<DocChange>? _docSub;

  /// 当前笔记标签（编辑态从笔记流加载，增删后经 setTags 持久化同步）。
  final List<String> _tags = [];

  /// 当前笔记 id；新建模式在首次保存前为 null。
  String? _noteId;

  /// 最近一次已持久化的标题/正文快照，用于判断内容是否真的变化
  /// （避免无变更时也写库递增 version）。
  String _savedTitle = '';
  String _savedContent = '';

  /// 是否存在尚未持久化的内容变更。
  bool _dirty = false;

  /// 程序化填充输入框/替换文档期间抑制 onChanged，避免把加载/远端覆盖内容
  /// 误判为用户输入。
  bool _suppressChanges = false;

  /// 编辑态笔记是否已加载完成（加载完成前显示 loading）。
  bool _initialized = false;

  /// 最近一次右键的全局位置（编辑区 Listener 记录）。
  /// contextMenuBuilder 用它判断右键是否落在图片上（精确、无时间残留）。
  Offset? _lastRightClickPosition;

  /// 编辑器 GlobalKey（保存菜单 clamp 在编辑区内用）。
  final GlobalKey _editorKey = GlobalKey();

  /// 编辑器状态 key（QuillEditorConfig.editorKey）：笔记内搜索的滚动
  /// 定位与关键词高亮要用 renderEditor 的几何信息（官方推荐用法：
  /// editorKey.currentState?.renderEditor.getLocalRectForCaret）。
  final GlobalKey<EditorState> _quillEditorKey = GlobalKey<EditorState>();

  /// 正文关键词高亮浮层（搜索跳转后显示，2s 后渐隐移除）。
  OverlayEntry? _searchHighlightEntry;
  AnimationController? _searchHighlightAnim;

  /// 图片 GlobalKey → 文件映射（右键命中判断用）。
  /// 每次判断实时取 key 的当前 RenderBox 矩形——滚动后依然准确。
  final Map<GlobalKey, File> _imageKeys = {};

  /// 图片右键回调：记录位置（contextMenuBuilder 判断用）+ 弹保存菜单
  /// （桌面右键与移动端长按统一走编辑页 Overlay）。
  void _onImageTap(File file, Offset position) {
    _lastRightClickPosition = position;
    _showImageMenu(file, position);
  }

  /// 保存菜单弹层（编辑页级唯一：打开新菜单前先关旧的——依次长按/右键
  /// 不叠加、每次重新定位）。桌面右键与移动端长按统一走这里。
  OverlayEntry? _imageMenuEntry;

  /// 打开保存菜单：锚定在 anchorGlobal 处（桌面右键=鼠标位置、移动端
  /// 长按=图片底部中心），滚动时按锚点相对图片的偏移跟随图片。
  void _showImageMenu(File file, Offset anchorGlobal) {
    final context = this.context;
    final overlay = Overlay.of(context);
    _imageMenuEntry?.remove();
    _imageMenuEntry = null;
    final key = _keyForFile(file);
    // 锚点相对图片左上角的偏移（滚动后按新位置 + 偏移还原）。
    final box0 = key?.currentContext?.findRenderObject() as RenderBox?;
    final imageTopLeft0 = box0?.localToGlobal(Offset.zero) ?? Offset.zero;
    final anchorOffset = anchorGlobal - imageTopLeft0;
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) {
        // 每次 build 实时取图片当前位置：滚动后 markNeedsBuild 重新定位，
        // 菜单绝对锚定在图片上（桌面鼠标位置 / 移动端图片底部）。
        final box = key?.currentContext?.findRenderObject() as RenderBox?;
        final imageTopLeft = box?.localToGlobal(Offset.zero) ?? Offset.zero;
        final position = imageTopLeft + anchorOffset;
        // 钳制在编辑区域内：不悬浮到 AppBar/工具栏等其他组件上方。
        final editorBox =
            _editorKey.currentContext?.findRenderObject() as RenderBox?;
        final editorRect = editorBox == null
            ? null
            : editorBox.localToGlobal(Offset.zero) & editorBox.size;
        // 菜单约 110x44（icon+文字+内边距），clamp 后始终在编辑区内。
        const menuSize = Size(110, 44);
        var left = position.dx - menuSize.width / 2;
        var top = position.dy + 6;
        if (editorRect != null) {
          left = left.clamp(editorRect.left, editorRect.right - menuSize.width);
          top = top.clamp(editorRect.top, editorRect.bottom - menuSize.height);
        }
        return Stack(
          children: [
            // ModalBarrier：官方遮罩（非全屏 translucent GestureDetector），
            // 正确管理 pointer/hover 生命周期，点击外部关闭——避免
            // overlay 出现时 mouse_tracker hit test 0 尺寸渲染盒导致卡死。
            Positioned.fill(
              child: ModalBarrier(
                dismissible: true,
                onDismiss: () {
                  entry.remove();
                  _imageMenuEntry = null;
                },
              ),
            ),
            Positioned(
              left: left,
              top: top,
              child: Material(
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(12),
                elevation: 4,
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () {
                    entry.remove();
                    _imageMenuEntry = null;
                    _saveToLocal(context, file);
                  },
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.download_outlined, size: 20),
                        SizedBox(width: 10),
                        Text('保存图片'),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
    overlay.insert(entry);
    _imageMenuEntry = entry;
  }

  /// 文件 → 图片 GlobalKey（实时定位用）。
  GlobalKey? _keyForFile(File file) {
    for (final e in _imageKeys.entries) {
      if (e.value.path == file.path) return e.key;
    }
    return null;
  }

  /// 编辑器滚动 → 保存菜单跟随图片重新定位；关键词高亮跟随滚动。
  void _onEditorScroll() {
    _imageMenuEntry?.markNeedsBuild();
    _searchHighlightEntry?.markNeedsBuild();
  }

  /// 图片渲染后注册 GlobalKey（右键命中判断用）。
  void _registerImageKey(GlobalKey key, File file) {
    _imageKeys[key] = file;
  }

  /// 图片销毁时注销。
  void _unregisterImageKey(GlobalKey key) {
    _imageKeys.remove(key);
  }

  /// 右键位置命中的图片文件：实时取每个 key 的当前矩形判断
  /// （滚动后 rect 依然准确）。
  File? _imageAtPosition(Offset globalPosition) {
    for (final entry in _imageKeys.entries) {
      final box = entry.key.currentContext?.findRenderObject() as RenderBox?;
      if (box == null) continue;
      final rect = box.localToGlobal(Offset.zero) & box.size;
      if (rect.contains(globalPosition)) return entry.value;
    }
    return null;
  }

  /// 保存图片到本地：移动端存系统相册（gal），桌面端选择目录复制。
  Future<void> _saveToLocal(BuildContext context, File file) async {
    final fileName = file.uri.pathSegments.last;
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        // 移动端：保存到系统相册（gal 包；Android 13+ 免权限，iOS 需相册权限）。
        final bytes = await file.readAsBytes();
        await Gal.putImageBytes(bytes, name: fileName);
        showAppSnackBar('已保存到相册');
      } else if (Platform.isMacOS) {
        // macOS：自研原生保存面板（NSOpenPanel 中文按钮"保存"，替代
        // file_picker 的英文 "Open" 面板——App 无中文本地化导致回退英文，
        // 且"打开"语义不符）。
        const channel = MethodChannel('easynote/save_directory');
        final dir = await channel.invokeMethod<String>('pick');
        if (dir == null || dir.isEmpty) return; // 用户取消
        final target = File('$dir/$fileName');
        await file.copy(target.path);
        showAppSnackBar('已保存到 $dir');
      } else {
        // Windows 等桌面端：file_picker 选择目录并复制。
        final dir = await FilePicker.platform.getDirectoryPath(
          dialogTitle: '选择保存位置',
        );
        if (dir == null) return; // 用户取消
        final target = File('$dir/$fileName');
        await file.copy(target.path);
        showAppSnackBar('已保存到 $dir');
      }
    } catch (e) {
      showAppSnackBar('保存失败：$e');
    }
  }

  /// 返回兜底保存进行中标记，防止用户连按返回重复触发。
  bool _popInProgress = false;

  /// 防抖定时器。
  Timer? _debounce;

  /// 持续输入强制保存定时器：从「本轮未保存变更的起点」开始计时，
  /// 到点无论是否仍在输入都触发一次保存。
  Timer? _maxIntervalTimer;

  /// 字数统计缓存：避免每个字符 setState 重建时整页 build 反复
  /// 全量 toPlainText()。仅在变更回调中刷新。
  int _wordCountCache = 0;

  /// 编辑态单条笔记流订阅（initState 中经 [ref.listenManual] 建立，
  /// dispose 时关闭；Riverpod 2.x 的 ref.listen 仅限 build 内使用）。
  ProviderSubscription<AsyncValue<Note?>>? _noteSub;

  /// 最近一次本地保存落库的 version（null = 尚无本地保存）。
  ///
  /// drift 流会把自己写库的变更原样推回（echo）。保存期间用户若继续输入，
  /// 流推送内容与当前输入不再一致，仅靠内容比较会误判为「远端修改」走
  /// 强覆盖路径（正在输入的内容被替换，需求 12）。用 version 判定：
  /// 推送 version 等于本地刚保存的 version → 保存回推，只对齐快照，
  /// 不覆盖输入框；远端修改 version 恒更大（LWW +1），互不干扰。
  int? _lastSavedVersion;

  /// 保存串行队列：防抖与返回兜底共用，保证同一时刻只有一个写库请求。
  Future<void> _saveChain = Future.value();

  _SaveStatus? _saveStatus;

  /// 进入编辑页时笔记是否为空（标题与正文均无内容，只认第一帧数据）。
  ///
  /// 返回时用于识别「进入时就空、现在仍空」的空笔记 → 物理删除不留痕。
  bool _baselineEmpty = true;

  /// 基线是否已捕获（只认进入后的第一帧数据）。
  bool _baselineCaptured = false;

  /// 当前笔记是否「仅本机保存」（AppBar 开关；随笔记流同步）。
  bool _localOnly = false;

  /// 底部格式工具栏是否收起（移动端默认收起为单按钮：不遮挡输入、
  /// 不粘连碍眼；点击展开完整工具栏）。
  bool _toolbarCollapsed = true;

  @override
  void initState() {
    super.initState();
    _contentScrollController.addListener(_onEditorScroll);
    _noteId = widget.id;
    _attachDocListener();
    // 方案B（无新建态）：路由恒带 id，进入即编辑态，直接订阅笔记流。
    _subscribeNoteStream();
  }

  /// 订阅正文文档变化（QuillEditor 输入 → 自动保存链）。
  ///
  /// [QuillController.changes] 为当前 document 的变更流；远端强覆盖会替换
  /// 整个 document（[QuillController.document] setter），替换后需重新订阅
  /// 新文档的流（_applyRemoteNote 中调用）。
  void _attachDocListener() {
    _docSub?.cancel();
    _docSub = _contentController.changes.listen((_) {
      // 文档任何变化（输入/撤销/远端覆盖）都会让搜索高亮的 offset 失效：
      // 立即移除高亮（比等它自然渐隐更正确）。
      _removeSearchHighlight();
      _onChanged();
    });
  }

  @override
  void dispose() {
    _noteSub?.close();
    _debounce?.cancel();
    _maxIntervalTimer?.cancel();
    _docSub?.cancel();
    _titleController.dispose();
    _titleFocusNode.dispose();
    _contentController.dispose();
    _contentFocusNode.dispose();
    _contentScrollController
      ..removeListener(_onEditorScroll)
      ..dispose();
    _imageMenuEntry?.remove();
    _removeSearchHighlight();
    super.dispose();
  }

  // ---------- 加载与实时同步 ----------

  /// 编辑态：订阅 [editorNoteProvider] 单条笔记流（drift watchSingle，
  /// task-18 编辑模式实时同步）。
  ///
  /// 流语义：
  /// - 首帧（loading）保持加载态；首次 data 推送填充输入框并置为已加载；
  /// - 推送内容与当前输入一致（本地保存回推）→ 仅对齐已保存快照，不更新
  ///   controller（避免光标跳动/输入打断）；
  /// - 推送内容不一致（远端修改，LWW 强覆盖）→ 直接替换标题/正文输入框；
  ///   覆盖后用户继续输入照常防抖保存（version+1 推送），保存回推内容一致
  ///   跳过，不产生循环。
  void _subscribeNoteStream() {
    final id = _noteId;
    if (id == null) {
      // 新建模式（/editor 无 id）：无既有笔记可订阅——直接按「空笔记
      // 已就绪」处理，捕获空基线（S1 判定用）；首次保存创建笔记后由
      // _performSave 转入编辑态并订阅笔记流。
      // 直接赋值不走 _setStatus（initState 路径无需 setState）。
      _initialized = true;
      _saveStatus = _SaveStatus.saved;
      _captureBaseline(title: '', content: '');
      return;
    }
    _noteSub = ref.listenManual(
      editorNoteProvider(id),
      _onNoteStream,
      fireImmediately: true,
    );
  }

  /// 单条笔记流回调：[previous] 为上一次状态（首帧为 null）。
  void _onNoteStream(AsyncValue<Note?>? previous, AsyncValue<Note?> next) {
    if (!mounted) return;
    // StreamProvider 首帧为 loading（fireImmediately 触发）：保持加载态。
    if (next.isLoading && previous == null) return;
    final note = next.valueOrNull;
    if (note == null) {
      // 笔记不存在（远端删除/读取失败）：首次加载按空笔记继续编辑；
      // 后续推送 null 不覆盖当前输入（删除场景保持现状）。
      if (!_initialized) {
        setState(() => _initialized = true);
        _setStatus(_SaveStatus.saved);
      }
      _captureBaseline(title: '', content: '');
      return;
    }
    // 进入后的首帧数据 = 笔记进入时的状态：记录空态基线（返回时识别
    // 空笔记用）并同步「仅本机保存」标记。
    _captureBaseline(title: note.title, content: note.content);
    if (_localOnly != note.localOnly) {
      setState(() => _localOnly = note.localOnly);
    }
    // 本地保存回推判定（需求 12）：version 等于刚保存的版本 → 是自己保存
    // 触发的 drift 流推送，不是远端修改。保存期间继续输入时内容比较会
    // 不成立，若不在此拦截会误走 _applyRemoteNote 强覆盖（输入被替换）。
    // 只对齐快照，绝不触碰输入框；新输入由后续防抖保存正常落库。
    if (_lastSavedVersion != null && note.version == _lastSavedVersion) {
      debugPrint(
        '[editor] 保存回推 echo：version=${note.version}，'
        '跳过覆盖（输入保持不变）',
      );
      _savedTitle = note.title;
      _savedContent = note.content;
      _syncTags(note.tags);
      if (!_initialized) {
        setState(() => _initialized = true);
      }
      return;
    }
    if (note.title == _titleController.text && note.content == _contentDelta) {
      // 内容与当前输入一致（本地保存回推）：不更新 controller，避免
      // 光标跳动/输入打断；仅对齐已保存快照（版本/时间戳可能变化）。
      _savedTitle = note.title;
      _savedContent = note.content;
      // 标签可能被远端单独修改（内容未变）：仅同步标签，不动输入框。
      _syncTags(note.tags);
      if (!_initialized) {
        setState(() => _initialized = true);
      }
      return;
    }
    _applyRemoteNote(note);
  }

  /// 远端内容强覆盖输入框（LWW 最后保存者赢，直接替换；本地未保存输入
  /// 可能被覆盖，用户已确认接受）。
  ///
  /// 正文替换整个 Quill Document（[QuillController.document] setter），
  /// 替换后重建文档变更订阅；_suppressChanges 抑制替换本身触发保存。
  void _applyRemoteNote(Note note) {
    // 取消待保存：pending 防抖基于被覆盖前的输入，不应再写库（否则被
    // 丢弃的输入会以更高 version 复活，违反「最后保存者赢」）。
    _debounce?.cancel();
    _maxIntervalTimer?.cancel();
    _suppressChanges = true;
    // 记录替换前的光标位置：替换 document 会把 selection 重置到开头
    // （光标跳最前），替换后按焦点位置恢复（clamp 到新内容长度）。
    final titleFocus = _titleFocusNode.hasFocus;
    final titleOffset = _titleController.selection.baseOffset;
    final bodyFocus = _contentFocusNode.hasFocus;
    final bodyOffset = _contentController.selection.baseOffset;
    _titleController.text = note.title;
    _contentController.document = _documentFromStored(note.content);
    _suppressChanges = false;
    if (titleFocus) {
      _titleController.selection = TextSelection.collapsed(
        offset: titleOffset.clamp(0, _titleController.text.length),
      );
    }
    if (bodyFocus) {
      final len = _contentController.document.toPlainText().length;
      _contentController.updateSelection(
        TextSelection.collapsed(offset: bodyOffset.clamp(0, len)),
        ChangeSource.local,
      );
    }
    _attachDocListener(); // 文档已替换：重建变更订阅
    // 流推送的是库内最新值，即已保存快照。
    _savedTitle = note.title;
    _savedContent = note.content;
    _dirty = false;
    _setStatus(_SaveStatus.saved);
    // 刷新字数统计缓存（首次填充 + 远端覆盖均走此路径）。
    _wordCountCache =
        _titleController.text.length +
        _contentController.document.toPlainText().length;
    _syncTags(note.tags);
    if (!_initialized) {
      setState(() => _initialized = true);
    } else {
      // 非首次加载的覆盖才是真正的远端修改：刷新字数统计。
      // （静默同步：不弹提示、不打断输入，状态由 AppBar 图标表达）
      setState(() {});
    }
  }

  /// 把存量 content（delta JSON；兼容纯文本兜底）解析为 Quill Document。
  ///
  /// 解析失败（非法 JSON / 非 delta 数组 / 纯文本）时按纯文本构造
  /// `[{"insert":"文本\n"}]`（补尾换行；空内容 → 空文档），保证编辑页
  /// 永不因存量数据格式崩溃。
  static Document _documentFromStored(String stored) {
    if (stored.isEmpty) return Document();
    try {
      final decoded = jsonDecode(stored);
      if (decoded is List) {
        return Document.fromJson(decoded.cast<Map<String, dynamic>>());
      }
    } catch (_) {
      // 非 JSON：按纯文本转换
    }
    final text = stored.endsWith('\n') ? stored : '$stored\n';
    return Document.fromJson([
      {'insert': text},
    ]);
  }

  /// 同步标签到本地状态：与当前一致时跳过（避免无意义重建）。
  void _syncTags(List<String> tags) {
    if (listEquals(tags, _tags)) return;
    setState(() {
      _tags
        ..clear()
        ..addAll(tags);
    });
  }

  // ---------- 进入基线（空笔记判定） ----------

  /// 记录进入编辑页时的空态（只认第一帧数据，后续推送不覆盖）。
  void _captureBaseline({required String title, required String content}) {
    if (_baselineCaptured) return;
    _baselineEmpty =
        title.trim().isEmpty && Note.plainTextOf(content).trim().isEmpty;
    _baselineCaptured = true;
  }

  // ---------- 自动保存 ----------

  /// 正文当前 delta JSON 序列化（Quill Document → 存库/比较的字符串）。
  String get _contentDelta =>
      jsonEncode(_contentController.document.toDelta().toJson());

  /// 标题/正文任一变更：置脏并调度保存（保存逻辑统一读取 controller）。
  ///
  /// 触发即视为待保存（_dirty = true），不逐字符序列化比较——「撤销回到
  /// 已保存内容」的边界情况由 _performSave 写库前的相等检查兜底跳过。
  /// 每次变更刷新字数统计缓存 + setState（task-28）。
  ///
  /// 保存调度双保险：
  /// - idle 防抖 1s：停手即存；
  /// - max interval 5s：持续输入时强制落盘一次，避免长期不落盘、闪退丢稿。
  ///
  /// 状态语义（用户确认）：编辑期间（存在未保存变更）始终显示转圈
  /// 「刷新」图标——表达「尚未落盘完成」；停手防抖保存完成 → 对勾。
  /// 相比此前「仅写库瞬间转圈、编辑中显示对勾」，语义更准确：
  /// 编辑中 = 未完成态，停手保存后 = 完成态。
  void _onChanged() {
    if (_suppressChanges) return;
    _dirty = true;
    // 编辑中：状态切到「保存中」（转圈）。已有未保存变更时保持不变；
    // 保存失败（error）时保留错误提示，不覆盖。
    if (_saveStatus != _SaveStatus.saving && _saveStatus != _SaveStatus.error) {
      _setStatus(_SaveStatus.saving);
    }
    // 字数缓存仅在变化时刷新 UI：每键全量提取不可避免（缓存语义），
    // 但整页 setState 每键一次会让光标区外的整棵子树无谓重建（低优修复）。
    final wordCount =
        _titleController.text.length +
        _contentController.document.toPlainText().length;
    if (wordCount != _wordCountCache) {
      _wordCountCache = wordCount;
      setState(() {});
    }
    // idle 防抖重置。
    _debounce?.cancel();
    _debounce = Timer(_debounceDuration, () {
      _enqueueSave();
    });
    // max-interval 从本轮未保存变更的起点计时（只启动一次，
    // 保存成功后由 _performSave 取消）。
    _maxIntervalTimer ??= Timer(_maxSaveInterval, () {
      _enqueueSave();
    });
  }

  /// 标题+正文合计字数（中英文按字符计；正文按 delta 纯文本提取，task-29）。
  /// 走缓存：仅在变更回调中全量提取，build 反复调用不再重复计算。
  int get _wordCount => _wordCountCache;

  /// 把一次保存追加到串行队列并返回其完成时机。
  Future<void> _enqueueSave() {
    _saveChain = _saveChain
        .then((_) => _performSave())
        .catchError((Object _) {});
    return _saveChain;
  }

  /// 执行一次保存：新建→createNote，已有→updateNote（version 自动递增）。
  ///
  /// 每次保存以执行时刻的输入快照为准；保存期间若有新输入，保持脏标记
  /// 并交由队列中的下一次保存处理，避免丢字。
  Future<void> _performSave() async {
    if (!mounted) return;
    if (!_dirty) return;
    final title = _titleController.text;
    final content = _contentDelta;
    // 撤销后回到已保存内容：无需写库（不递增 version），并取消强存定时器。
    if (_noteId != null && title == _savedTitle && content == _savedContent) {
      _dirty = false;
      _maxIntervalTimer?.cancel();
      _maxIntervalTimer = null;
      _setStatus(_SaveStatus.saved);
      return;
    }
    final noteId = _noteId;
    if (noteId == null) {
      // 新建模式兜底创建（M3，/editor 无 id 路由）：防抖窗口内输入后
      // 首次保存在此创建笔记，随后转入编辑态（订阅新 id 的笔记流）。
      final created = await ref
          .read(noteRepositoryProvider)
          .createNote(title: title, content: content);
      if (!mounted) return;
      setState(() {
        _noteId = created.id;
        _lastSavedVersion = created.version;
        _savedTitle = created.title;
        _savedContent = created.content;
      });
      _dirty = false;
      _maxIntervalTimer?.cancel();
      _maxIntervalTimer = null;
      _setStatus(_SaveStatus.saved);
      _subscribeNoteStream();
      return;
    }
    // 真正写库开始：才亮「保存中」。
    _setStatus(_SaveStatus.saving);
    try {
      final updated = await ref
          .read(noteRepositoryProvider)
          .updateNote(id: noteId, title: title, content: content);
      // 记录本次落库版本：drift 流回推（echo）按 version 识别，
      // 避免保存期间的输入被误判为远端修改而覆盖（需求 12）。
      _lastSavedVersion = updated.version;
      _savedTitle = updated.title;
      _savedContent = updated.content;
      if (!mounted) return;
      // 让出一个事件循环：drift 变更流触发 SyncService._onLocalChange
      // 完成增量推送（局域网 fire-and-forget，微秒级）后，才显示对勾
      // ——对勾语义 = 已保存 + 已触发同步（单机时推送循环 0 次即完成，
      // 对勾同样成立，用户确认）。
      await Future<void>.delayed(Duration.zero);
      if (!mounted) return;
      final changedDuringSave =
          _titleController.text != title || _contentDelta != content;
      _dirty = changedDuringSave;
      if (changedDuringSave) {
        // 保存期间又有新输入：保持「保存中」，链上后续保存会再次执行。
        _setStatus(_SaveStatus.saving);
        // 正常输入场景下 _onChanged 已调度新的防抖；若没有 pending 防抖
        // （保存期间被远端覆盖取消，见 _applyRemoteNote），补一次防抖保存，
        // 避免停留在「保存中」且已保存快照过期。
        if (_debounce == null || !_debounce!.isActive) {
          _debounce = Timer(_debounceDuration, () {
            _enqueueSave();
          });
        }
      } else {
        // 本轮未保存变更已全部落盘：取消强存定时器（下轮变更重新计时）。
        _maxIntervalTimer?.cancel();
        _maxIntervalTimer = null;
        _setStatus(_SaveStatus.saved);
      }
    } catch (_) {
      if (!mounted) return;
      _dirty = true;
      _setStatus(_SaveStatus.error);
    }
  }

  // ---------- 返回兜底保存 ----------

  void _onPopInvoked(bool didPop, Object? result) {
    if (didPop) return;
    unawaited(_flushBeforeLeave());
  }

  /// 返回流程（用户确认方案 A：自动保存心智——所见即所存，返回不打扰）：
  ///
  /// - **新建后没输入任何内容** → 无笔记可存，直接离开；
  /// - **进入时为空且现在仍为空** → 物理删除，静默不留痕；
  /// - 其余情况一律**静默兜底落盘**所有未保存变更后离开（不弹「保存/
  ///   不保存」；内容与已保存一致时 _performSave 的相等检查自动跳过）。
  Future<void> _flushBeforeLeave() async {
    if (_popInProgress) return;
    _popInProgress = true;
    _debounce?.cancel();
    _maxIntervalTimer?.cancel();
    final noteId = _noteId;
    if (noteId == null) {
      final isEmptyNow =
          _titleController.text.trim().isEmpty &&
          _contentController.document.toPlainText().trim().isEmpty;
      if (isEmptyNow) {
        // 新建模式且没输入：还没有笔记，直接离开。
        if (mounted) context.pop();
        return;
      }
      // 防抖窗口内输入后立即返回（首次保存还没创建笔记）：兜底创建。
      await _flushPendingSave();
      return;
    }
    // S1 完善：基线未捕获（进入后立刻返回，drift 首帧未推送）时主动等
    // 一帧——StreamProvider.future 随下一次流推送完成，通常毫秒级；500ms
    // 超时兜底。拿到「进入时状态」再裁决：既不误删有内容的笔记，也不把
    // 本应删除的空笔记残留下来；极端等不到（超时）则走保存路径保数据。
    if (!_baselineCaptured) {
      try {
        await ref
            .read(editorNoteProvider(noteId).future)
            .timeout(const Duration(milliseconds: 500));
      } catch (_) {}
      if (!mounted) return;
    }
    final isEmptyNow =
        _titleController.text.trim().isEmpty &&
        _contentController.document.toPlainText().trim().isEmpty;
    if (isEmptyNow && _baselineEmpty && _baselineCaptured) {
      // 进入时为空、现在仍为空：直接物理删除（同步会广播删除，对端一致）。
      // 基线必须已捕获（S1）：未捕获时上方已等首帧，仍未知则走保存路径。
      await ref.read(noteRepositoryProvider).deleteNote(noteId);
      if (!mounted) return;
      context.pop();
      return;
    }
    // 返回即保存：兜底落盘待保存变更（含防抖窗口内的输入与格式类变更）。
    await _flushPendingSave();
  }

  /// 落盘待保存变更后离开（无改动 / 选择「保存」共用）。
  ///
  /// 保存失败时沿用原确认框（重试留在编辑页 / 仍要离开）。
  Future<void> _flushPendingSave() async {
    if (_dirty) {
      await _enqueueSave();
    }
    if (!mounted) return;
    if (!_dirty) {
      context.pop();
      return;
    }
    final leave = await _confirmLeaveWithUnsaved();
    if (!mounted) return;
    if (leave) {
      context.pop();
    } else {
      // 重试：立即重新保存，停留在编辑页。
      _popInProgress = false;
      _enqueueSave();
    }
  }

  /// 保存失败离开确认框：返回 true 表示放弃未保存内容仍要离开。
  Future<bool> _confirmLeaveWithUnsaved() {
    return showGlassDialog<bool>(
      context: context,
      title: const Text('保存失败'),
      content: const Text('笔记尚未保存成功，仍然离开吗？'),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('重试'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('仍要离开'),
        ),
      ],
    ).then((value) => value ?? false);
  }

  // ---------- 笔记内搜索（跳转 + 关键词高亮渐隐） ----------

  /// 打开笔记内搜索浮层。
  void _openNoteSearch() {
    // 上次跳转的关键词高亮若还没消失（2.8s 窗口内再开搜索），先移除：
    // 否则高亮 Overlay 会垫在弹窗下面，透过半透明 barrier 显示出来。
    _removeSearchHighlight();
    showEditorSearchPanel(
      context,
      controller: _contentController,
      onJump: _jumpToMatch,
      history: ref.read(searchHistoryProvider),
    );
  }

  /// 跳转到匹配处：滚动定位（不改光标）+ 关键词高亮 2s 后渐隐。
  void _jumpToMatch(EditorSearchMatch match) {
    final editorState = _quillEditorKey.currentState;
    if (editorState == null) return;
    final renderEditor = editorState.renderEditor;
    // 匹配 offset 可能因远端同步覆盖而失效（浮层打开期间文档仍可能被
    // 对端改写）：越界则放弃跳转，不做半截定位。
    if (match.end > _contentController.document.toPlainText().length) return;
    // 滚动：目标行移到视口上方约 1/4 处（animateTo 平滑到位）。
    try {
      final startRect = renderEditor.getLocalRectForCaret(
        TextPosition(offset: match.start),
      );
      final scroll = editorState.scrollController;
      if (scroll.hasClients) {
        final target =
            (startRect.top - scroll.position.viewportDimension * 0.25).clamp(
              0.0,
              scroll.position.maxScrollExtent,
            );
        if ((target - scroll.offset).abs() > 4) {
          scroll.animateTo(
            target,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
          );
        }
      }
    } on RangeError {
      // offset 越界（文档刚被改写）：放弃滚动，仍尝试高亮可见部分。
    }
    _showSearchHighlight(match);
  }

  /// 显示关键词高亮浮层：全屏 Overlay + CustomPaint 画匹配矩形，
  /// 2s 保持后 0.8s 渐隐移除（TweenSequence 两段）；滚动跟随由
  /// _onEditorScroll 的 markNeedsBuild 驱动重建（每次重取全局坐标）。
  void _showSearchHighlight(EditorSearchMatch match) {
    _removeSearchHighlight();
    final editorState = _quillEditorKey.currentState;
    if (editorState == null) return;
    final renderEditor = editorState.renderEditor;
    List<Rect> rects;
    try {
      rects = _matchRects(renderEditor, match.start, match.end);
    } on RangeError {
      return; // 文档刚被改写，offset 失效：不显示高亮。
    }
    final anim = AnimationController(vsync: this, duration: _highlightDuration);
    // 保持 2s（用户确认：显示 2 秒后渐渐隐去）→ 0.8s 渐隐。
    final fade = TweenSequence<double>([
      TweenSequenceItem(tween: ConstantTween(1.0), weight: 2.0),
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.0), weight: 0.8),
    ]).animate(anim);
    final pageContext = context;
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => AnimatedBuilder(
        animation: fade,
        builder: (context, child) {
          if (!renderEditor.attached) return const SizedBox.shrink();
          // 内容坐标 → 全局坐标：renderEditor 随滚动平移，滚动后
          // markNeedsBuild 重建时重新取 origin，高亮始终钉在关键词上。
          final origin = renderEditor.localToGlobal(Offset.zero);
          final color = Theme.of(
            pageContext,
          ).colorScheme.primary.withValues(alpha: 0.30 * fade.value);
          return IgnorePointer(
            child: CustomPaint(
              size: MediaQuery.sizeOf(pageContext),
              painter: _SearchHighlightPainter(
                rects.map((r) => r.shift(origin)).toList(),
                color,
              ),
            ),
          );
        },
      ),
    );
    Overlay.of(context).insert(entry);
    _searchHighlightEntry = entry;
    _searchHighlightAnim = anim;
    anim.forward().whenComplete(_removeSearchHighlight);
  }

  /// 匹配区间在 renderEditor 内容坐标系中的矩形（getLocalRectForCaret
  /// 推导，quill 未公开 getBoxesForSelection）：
  /// - 同一行：起点 caret 左缘 → 终点 caret 左缘；
  /// - 跨行：首行从起点到右缘 + 中间整行（行高步进）+ 末行到终点。
  List<Rect> _matchRects(RenderEditor renderEditor, int start, int end) {
    final startRect = renderEditor.getLocalRectForCaret(
      TextPosition(offset: start),
    );
    // 终点用 upstream affinity：关键词恰好在行尾结束时，downstream 会把
    // caret 归到下一行行首（多画一整行高亮），upstream 停在本行行尾。
    final endRect = renderEditor.getLocalRectForCaret(
      TextPosition(offset: end, affinity: TextAffinity.upstream),
    );
    final rects = <Rect>[];
    if ((startRect.top - endRect.top).abs() < 0.5) {
      final left = startRect.left.clamp(0.0, endRect.left);
      rects.add(
        Rect.fromLTRB(left, startRect.top, endRect.left, startRect.bottom),
      );
      return rects;
    }
    final contentWidth = renderEditor.size.width;
    rects.add(
      Rect.fromLTRB(
        startRect.left,
        startRect.top,
        contentWidth,
        startRect.bottom,
      ),
    );
    final lineHeight = startRect.height;
    var y = startRect.bottom;
    // 防呆上限（行高异常时避免死循环）。
    var guard = 0;
    while (y < endRect.top - 0.5 && guard++ < 1000) {
      final bottom = (y + lineHeight).clamp(y, endRect.top);
      rects.add(Rect.fromLTRB(0, y, contentWidth, bottom));
      y += lineHeight;
    }
    rects.add(Rect.fromLTRB(0, endRect.top, endRect.left, endRect.bottom));
    return rects;
  }

  /// 移除关键词高亮浮层（渐隐完成 / 内容变化 / 页面销毁时调用）。
  void _removeSearchHighlight() {
    _searchHighlightEntry?.remove();
    _searchHighlightEntry = null;
    _searchHighlightAnim?.dispose();
    _searchHighlightAnim = null;
  }

  // ---------- 仅本机保存 ----------

  /// 切换「仅本机保存」（AppBar 开关，同步层按此标记拦截内容传输）。
  ///
  /// 开启 = 不再同步到其他设备，且**其他设备上已有的副本会被删除**
  /// （对端收到标记即删，不可撤销，因此开启前先确认）；关闭 = 恢复同步。
  Future<void> _toggleLocalOnly(bool value) async {
    final noteId = _noteId;
    if (noteId == null) return;
    if (value && !_localOnly) {
      final confirmed = await showGlassDialog<bool>(
        context: context,
        title: const Text('仅本机保存'),
        content: const Text(
          '开启后这篇笔记不再同步到其他设备，'
          '其他设备上已有的副本会被删除。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('开启'),
          ),
        ],
      );
      if (confirmed != true || !mounted) return;
    }
    setState(() => _localOnly = value);
    await ref.read(noteRepositoryProvider).setLocalOnly(noteId, value);
    if (!mounted) return;
    showAppSnackBar(value ? '已设为仅本机保存' : '已恢复同步到其他设备');
  }

  // ---------- UI ----------

  void _setStatus(_SaveStatus? status) {
    if (!mounted || _saveStatus == status) return;
    setState(() => _saveStatus = status);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: _onPopInvoked,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('编辑笔记'),
          actions: [
            _SaveStatusIndicator(status: _saveStatus),
            // 原「移到回收站」按钮位置改为「仅本机保存」开关（用户确认：
            // 编辑页不再提供删除入口，删除走列表菜单）。
            _LocalOnlyToggle(value: _localOnly, onChanged: _toggleLocalOnly),
            const SizedBox(width: 8),
          ],
        ),
        body: Stack(
          children: [
            // 编辑器卡片始终构建；加载中叠加浮层。
            // （列表侧 heroTag 恒为 null，编辑页未包 Hero——无飞行过渡，
            // 相关注释已对齐现实，勿再引用 Hero。）
            _buildEditor(),
            if (!_initialized)
              const Positioned.fill(
                // AbsorbPointer：加载期间拦截点击，避免误触空白编辑器
                child: AbsorbPointer(
                  child: ColoredBox(
                    color: Colors.transparent,
                    child: Center(child: CircularProgressIndicator()),
                  ),
                ),
              ),
          ],
        ),
        // 底部栏（工具栏+字数）：包 AnimatedPadding 跟随键盘上移——
        // 注：Scaffold 的 bottomNavigationBar 默认**不会**随键盘顶起
        // （Flutter 已知行为，body 才避让键盘），否则键盘弹出时被盖。
        // 这里手动加 viewInsets.bottom 内边距，让工具栏/字数显示在键盘上方。
        bottomNavigationBar: AnimatedPadding(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          padding: EdgeInsets.only(
            bottom:
                MediaQuery.of(context).viewInsets.bottom +
                MediaQuery.paddingOf(context).bottom,
          ),
          child: _buildToolbar(),
        ),
      ),
    );
  }

  /// 编辑器主体：干净输入区（无卡片框包裹，直接铺在页面背景，像备忘录）。
  /// 布局：标题 → 标签编辑（task-28，仅编辑态）→ 富文本工具栏 → 正文
  /// QuillEditor → 底部字数统计。
  /// （历史上有列表→编辑页的 Hero 过渡（task-25），列表侧 heroTag 已
  /// 恒为 null、本页未包 Hero，过渡不存在——保留此说明防误恢复。）
  Widget _buildEditor() {
    final editorCard = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _TitleField(
          controller: _titleController,
          focusNode: _titleFocusNode,
          onChanged: (_) => _onChanged(),
        ),

        // 标签编辑（task-28）：仅编辑态展示——新建态首次保存前无笔记
        // 可打标签（保存成功后路由替换为编辑态再展示）。
        Expanded(
          // 编辑区全局 Listener：记录每次右键位置（判断是否在图片上，
          // 供 contextMenuBuilder 精确决定是否追加「保存图片」）。
          child: Listener(
            // 记录所有指针 down 位置（右键/触摸长按都更新）：
            // contextMenuBuilder 用它判断是否命中图片——长按文字时位置
            // 是文字，不会残留上次图片位置（移动端误判修复）。
            onPointerDown: (event) {
              _lastRightClickPosition = event.position;
            },
            child: QuillEditor.basic(
              key: _editorKey,
              controller: _contentController,
              focusNode: _contentFocusNode,
              scrollController: _contentScrollController,
              config: QuillEditorConfig(
                editorKey: _quillEditorKey,
                placeholder: '正文',
                expands: true,
                padding: EdgeInsets.symmetric(vertical: 8),
                embedBuilders: [
                  _LocalImageEmbedBuilder(
                    onImageTap: _onImageTap,
                    onKeyReady: _registerImageKey,
                    onKeyDispose: _unregisterImageKey,
                    onSave: (file) {
                      if (mounted) _saveToLocal(context, file);
                    },
                    onShowMenu: _showImageMenu,
                  ),
                ],
                // 显示前拦截：图片右键（标志）→ 空菜单；其他情况 → 默认菜单
                // （复制/粘贴正常）。比事后 removeAny 更干净（无闪烁）。
                contextMenuBuilder: (context, state) {
                  // 右键位置命中图片：quill 菜单返回空并立即关闭——
                  // 保存菜单由编辑页 Overlay 统一管理（可每次右键重新定位、
                  // 可跟随图片滚动；quill 菜单无法做到，且已开菜单会短路
                  // 后续右键——showToolbar 源码 `toolbar != null` 直接 return）。
                  final position = _lastRightClickPosition;
                  final imageFile = position == null
                      ? null
                      : _imageAtPosition(position);
                  if (imageFile != null) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      state.hideToolbar();
                    });
                    return const SizedBox.shrink();
                  }
                  // 默认 4 选项菜单（剪切/复制/粘贴/全选）。曾尝试自定义紧凑
                  // 工具栏/精简项数，用户要求恢复原样（宽度不强改）。
                  return QuillRawEditorConfig.defaultContextMenuBuilder(
                    context,
                    state,
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
      child: editorCard,
    );
  }

  /// 富文本工具栏（task-29）：精简 QuillSimpleToolbar，只留基础格式按钮
  /// （加粗/斜体/下划线/标题/列表/引用/代码块/清除格式）+ 本地插图按钮。
  ///
  /// 底行为常驻结构（用户确认）：[锤子][撤销][重做][搜索]…[字数] 无论
  /// 格式面板是否展开都显示——撤销/重做从格式面板提出（showUndo/showRedo
  /// = false），不用展开即可直接点击；锤子即展开/收起切换。
  Widget _buildToolbar() {
    // 底部工具栏：贴底（bottomNavigationBar，Scaffold 默认随键盘顶起——
    // 键盘弹出时工具栏保持在输入法上方）。
    final children = <Widget>[
      if (_toolbarCollapsed)
        const SizedBox.shrink()
      else
        QuillSimpleToolbar(
          controller: _contentController,
          config: QuillSimpleToolbarConfig(
            multiRowsDisplay: true,
            showDividers: false,
            // 紧凑：缩小图标与按钮触控区（iconSize 14 × factor 1.2 ≈ 17px，
            // 默认 15×1.6=24px），按钮排列更密集、占用面积更小。
            buttonOptions: const QuillSimpleToolbarButtonOptions(
              base: QuillToolbarBaseButtonOptions(
                iconSize: 14,
                iconButtonFactor: 1.2,
              ),
            ),
            showFontFamily: false,
            showFontSize: false,
            showBoldButton: true,
            showItalicButton: true,
            showUnderLineButton: true,
            showStrikeThrough: false,
            showInlineCode: false,
            showColorButton: false,
            showBackgroundColorButton: false,
            showClearFormat: true,
            showAlignmentButtons: false,
            showHeaderStyle: true,
            showListNumbers: true,
            showListBullets: true,
            showListCheck: false,
            showCodeBlock: true,
            showQuote: true,
            showIndent: false,
            showLink: false,
            // 撤销/重做已提到常驻底行（不在此重复）。
            showUndo: false,
            showRedo: false,
            showDirection: false,
            showSearchButton: false,
            showSubscript: false,
            showSuperscript: false,
            showSmallButton: false,
            showLineHeightButton: false,
            customButtons: [
              QuillToolbarCustomButtonOptions(
                icon: const Icon(Icons.image_outlined, size: 20),
                tooltip: '插入图片',
                onPressed: _insertImage,
              ),
            ],
          ),
        ),
      _buildToolbarBaseRow(),
    ];
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.6),
          border: Border(
            top: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant,
              width: 0.5,
            ),
          ),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: children),
      ),
    );
  }

  /// 常驻底行：锤子（格式面板开关）+ 撤销/重做 + 笔记内搜索 + 字数。
  ///
  /// 撤销/重做监听 controller：hasUndo/hasRedo 为 false 时置灰
  /// （controller 是 ChangeNotifier，任何文档/历史变化都会通知重建）。
  Widget _buildToolbarBaseRow() {
    final scheme = Theme.of(context).colorScheme;
    final expanded = !_toolbarCollapsed;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 2, 12, 2),
      child: Row(
        children: [
          IconButton(
            tooltip: expanded ? '收起格式工具栏' : '展开格式工具栏',
            icon: _LucideHammerIcon(
              size: 21,
              color: expanded ? scheme.primary : scheme.onSurfaceVariant,
            ),
            // 直接对字段取反：expanded 是本次 build 的旧值快照，再取反
            // 会写回原值（展开/收起永远不生效）。
            onPressed: () =>
                setState(() => _toolbarCollapsed = !_toolbarCollapsed),
          ),
          // 撤销/重做：从格式面板提出来常驻（用户确认），直接点击。
          ListenableBuilder(
            listenable: _contentController,
            builder: (context, _) {
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: '撤销',
                    visualDensity: VisualDensity.compact,
                    iconSize: 20,
                    color: _contentController.hasUndo
                        ? scheme.onSurfaceVariant
                        : scheme.onSurfaceVariant.withValues(alpha: 0.3),
                    icon: const Icon(Icons.undo),
                    onPressed: _contentController.hasUndo
                        ? _contentController.undo
                        : null,
                  ),
                  IconButton(
                    tooltip: '重做',
                    visualDensity: VisualDensity.compact,
                    iconSize: 20,
                    color: _contentController.hasRedo
                        ? scheme.onSurfaceVariant
                        : scheme.onSurfaceVariant.withValues(alpha: 0.3),
                    icon: const Icon(Icons.redo),
                    onPressed: _contentController.hasRedo
                        ? _contentController.redo
                        : null,
                  ),
                ],
              );
            },
          ),
          IconButton(
            tooltip: '笔记内搜索',
            visualDensity: VisualDensity.compact,
            iconSize: 20,
            color: scheme.onSurfaceVariant,
            icon: const Icon(Icons.search),
            onPressed: _openNoteSearch,
          ),
          const Spacer(),
          _WordCountBar(count: _wordCount),
        ],
      ),
    );
  }

  /// 插入本地图片（task-29）：选图 → 压缩落盘（AttachmentsStore）→
  /// 光标处插入 image embed（delta `{"image":"attachments/<hash>.jpg"}`）。
  ///
  /// 用 file_picker 统一跨平台（macOS/Windows 文件选择、移动端相册/文件）；
  /// 失败/取消静默（用户可重试）。
  Future<void> _insertImage() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        withData: true,
      );
      final file = result?.files.single;
      final bytes =
          file?.bytes ??
          (file?.path == null ? null : await File(file!.path!).readAsBytes());
      if (bytes == null) return; // 用户取消
      final relative = await _attachments.saveImage(bytes);
      if (!mounted) return;
      // 光标处插入 block image embed（选中文本则替换选中区）。
      final index = _contentController.selection.baseOffset;
      final length = _contentController.selection.extentOffset - index;
      _contentController.replaceText(
        index,
        length,
        BlockEmbed.image(relative),
        null,
      );
    } catch (_) {
      // 选图/压缩/落盘失败：静默（不打断编辑）。
    }
  }
}

/// 标题输入框：无边框、大字样式（置于玻璃编辑器卡片内，见 _buildEditor）。
class _TitleField extends StatelessWidget {
  const _TitleField({
    required this.controller,
    required this.focusNode,
    required this.onChanged,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return TextField(
      controller: controller,
      focusNode: focusNode,
      onChanged: onChanged,
      style: theme.textTheme.titleLarge,
      decoration: const InputDecoration(
        hintText: '标题',
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        disabledBorder: InputBorder.none,
        errorBorder: InputBorder.none,
        focusedErrorBorder: InputBorder.none,
        isDense: true,
        contentPadding: EdgeInsets.symmetric(vertical: 12),
      ),
    );
  }
}

/// 本地插图 embed 渲染（task-29；task-30 附件就绪监听）：
/// 解析 delta `{"image":"attachments/x.jpg"}` 相对路径 → 绝对文件
/// （AttachmentsStore），用 Image.file 渲染；文件不存在（如对端未同步附件）
/// 渲染占位图标，不崩溃。
///
/// task-30（图片跨设备同步）：订阅 [AttachmentsStore.attachmentReady] 就绪
/// 事件流——附件经分片传输校验落盘成功后，自动重新解析并重建 Image.file
/// （占位 → 图片，无需手动刷新）。
///
/// 布局：块级图片，圆角 8，最长边约束视口宽度（等比），点击无操作。
class _LocalImageEmbedBuilder extends EmbedBuilder {
  const _LocalImageEmbedBuilder({
    this.onImageTap,
    this.onKeyReady,
    this.onKeyDispose,
    this.onSave,
    this.onShowMenu,
  });

  /// 图片右键/长按回调（编辑页 State 记录右键位置，供菜单追加「保存图片」）。
  final void Function(File file, Offset position)? onImageTap;

  /// 图片 GlobalKey 注册/注销回调（转发给编辑页 State）。
  final void Function(GlobalKey key, File file)? onKeyReady;
  final void Function(GlobalKey key)? onKeyDispose;

  /// 保存图片回调（编辑页 State 的 _saveToLocal）。
  final void Function(File file)? onSave;

  /// 长按弹层回调（编辑页 State 统一管理）。
  final void Function(File file, Offset position)? onShowMenu;

  static final AttachmentsStore _attachments = AttachmentsStore(
    directoryProvider: defaultAttachmentsDirectory,
  );

  @override
  String get key => BlockEmbed.imageType;

  @override
  Widget build(BuildContext context, EmbedContext embedContext) {
    final raw = embedContext.node.value.data;
    final relative = raw is String ? raw : '';
    return _AttachmentImage(
      relative: relative,
      onImageTap: onImageTap,
      onKeyReady: onKeyReady,
      onKeyDispose: onKeyDispose,
      onSave: onSave,
      onShowMenu: onShowMenu,
    );
  }
}

/// 附件图片（task-30）：解析相对路径 → Image.file；订阅附件就绪事件流，
/// 文件经跨设备同步到达后重建（占位 → 图片）。
class _AttachmentImage extends StatefulWidget {
  const _AttachmentImage({
    required this.relative,
    this.onImageTap,
    this.onKeyReady,
    this.onKeyDispose,
    this.onSave,
    this.onShowMenu,
  });

  /// delta embed 相对路径（`attachments/<hash>.jpg`）。
  final String relative;

  /// 图片右键/长按回调（编辑页 State 记录右键位置，contextMenuBuilder
  /// 追加「保存图片」菜单项——统一走 quill 官方右键菜单扩展点）。
  final void Function(File file, Offset position)? onImageTap;

  /// 图片渲染后注册 GlobalKey（右键命中判断用）。
  final void Function(GlobalKey key, File file)? onKeyReady;

  /// 图片销毁时注销。
  final void Function(GlobalKey key)? onKeyDispose;

  /// 保存图片回调（编辑页 State 的 _saveToLocal，长按弹层用）。
  final void Function(File file)? onSave;

  /// 长按弹层回调（编辑页 State 统一管理，保证全局唯一）。
  final void Function(File file, Offset position)? onShowMenu;

  @override
  State<_AttachmentImage> createState() => _AttachmentImageState();
}

class _AttachmentImageState extends State<_AttachmentImage> {
  StreamSubscription<String>? _readySub;
  Future<File?>? _fileFuture;

  /// 图片根节点 key：注册给编辑页 State 做实时右键命中判断。
  final GlobalKey _imageKey = GlobalKey();

  /// 本图 hash（`attachments/<16位hex>.<ext>` → 16 位 hex；无法提取返回 null）。
  String? get _hash {
    final match = RegExp(
      r'attachments/([a-f0-9]{16})\.[a-z0-9]+',
    ).firstMatch(widget.relative);
    return match?.group(1);
  }

  @override
  void initState() {
    super.initState();
    _fileFuture = _LocalImageEmbedBuilder._attachments.resolveFile(
      widget.relative,
    );
    // 注册 GlobalKey（文件就绪后）；右键命中判断实时取 key 矩形。
    _LocalImageEmbedBuilder._attachments.resolveFile(widget.relative).then((f) {
      if (!mounted || f == null) return;
      widget.onKeyReady?.call(_imageKey, f);
    });
    // 附件就绪（跨设备同步落盘成功）→ 重新解析文件并重建（占位 → 图片）。
    _readySub = AttachmentsStore.attachmentReady.listen((hash) {
      if (!mounted || hash != _hash) return;
      setState(() {
        _fileFuture = _LocalImageEmbedBuilder._attachments.resolveFile(
          widget.relative,
        );
      });
    });
  }

  @override
  void dispose() {
    _readySub?.cancel();
    widget.onKeyDispose?.call(_imageKey);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<File?>(
      future: _fileFuture,
      builder: (context, snapshot) {
        final file = snapshot.data;
        if (file == null) {
          // 附件不存在（未同步/被清理）：占位提示。
          return Container(
            height: 80,
            alignment: Alignment.center,
            margin: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.broken_image_outlined, size: 20),
                SizedBox(width: 8),
                Text('图片（本地文件不可用）'),
              ],
            ),
          );
        }
        return Padding(
          key: _imageKey,
          padding: const EdgeInsets.symmetric(vertical: 8),
          // Listener 监听右键（原始指针事件，立即触发标记）：
          // 菜单统一由 quill 的 contextMenuBuilder 显示（含「保存图片」项）。
          child: Listener(
            onPointerDown: (event) {
              if (event.buttons & kSecondaryMouseButton != 0) {
                widget.onImageTap?.call(file, event.position);
              }
            },
            child: GestureDetector(
              // 长按图片：弹「保存图片」菜单（quill 长按图片不触发文本菜单，
              // 移动端必须自己弹；桌面右键仍走 quill 的 contextMenuBuilder）。
              // 弹层由编辑页 State 统一管理（全局唯一，依次长按不叠加）。
              onLongPress: () {
                final box = context.findRenderObject() as RenderBox?;
                final anchor = box == null
                    ? Offset.zero
                    : (box.localToGlobal(Offset.zero) & box.size).bottomCenter;
                widget.onShowMenu?.call(file, anchor);
              },
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: ConstrainedBox(
                  // 宽撑满编辑区，高自适应（Image.file 等比缩放）。
                  constraints: const BoxConstraints(maxWidth: double.infinity),
                  child: Image.file(
                    file,
                    // 不支持的格式（如 HEIC）渲染失败：显示占位而非报错。
                    errorBuilder: (context, error, stack) => Container(
                      height: 80,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Text('此格式不支持预览（原图已保存）'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 编辑页底部字数统计（task-28）：标题+正文合计，中英文按字符计。
class _WordCountBar extends StatelessWidget {
  const _WordCountBar({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        '$count 字',
        textAlign: TextAlign.right,
        style: TextStyle(fontSize: 12, color: colorScheme.outline),
      ),
    );
  }
}

/// AppBar「仅本机保存」开关（复选框 + 文案，用户确认的文案与形式）。
///
/// 勾选 = 该笔记内容不再同步到其他设备（对端已有副本会被删除）；取消 =
/// 恢复同步。状态随笔记流同步（远端取消标记后本地开关同步翻转）。
class _LocalOnlyToggle extends StatelessWidget {
  const _LocalOnlyToggle({required this.value, required this.onChanged});

  final bool value;

  /// 目标值回调（true = 仅本机保存）。
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final color = value ? colorScheme.primary : colorScheme.onSurfaceVariant;
    return Tooltip(
      message: value ? '仅本机保存中：不同步到其他设备' : '仅本机保存：开启后不同步到其他设备',
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => onChanged(!value),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                value ? Icons.check_box : Icons.check_box_outline_blank,
                size: 18,
                color: color,
              ),
              const SizedBox(width: 4),
              Text(
                '仅本机保存',
                style: TextStyle(
                  fontSize: 13,
                  color: color,
                  fontWeight: value ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// AppBar 保存/同步状态指示（静默同步，用户确认）：
///
/// - 刷新图标（旋转）= 正在保存/同步（写库或入队中）；
/// - 对勾 = 保存完成 + 同步完成（单机时也表示已保存、后续会自动同步）；
/// - 错误图标 = 保存失败（需用户注意，保留文字）；
/// - 新建且无内容时不显示。
///
/// 纯图标、无文字（用户确认「已保存」去掉）——输入时余光可辨状态，
/// 不打断输入。
class _SaveStatusIndicator extends StatefulWidget {
  const _SaveStatusIndicator({required this.status});

  final _SaveStatus? status;

  @override
  State<_SaveStatusIndicator> createState() => _SaveStatusIndicatorState();
}

class _SaveStatusIndicatorState extends State<_SaveStatusIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin;

  @override
  void initState() {
    super.initState();
    // initState 显式创建（非惰性）：避免 widget 从未进入 saving 状态时，
    // dispose 首次访问 late 字段触发创建 → 此时 widget 已 deactivated →
    // 查 TickerMode ancestor 崩溃（与 _StatusDot 同模式）。
    _spin = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final Widget content = switch (widget.status) {
      null => const SizedBox.shrink(),
      // 保存中/同步中：旋转刷新图标（不转圈占位动画，观感更轻）。
      _SaveStatus.saving => RotationTransition(
        turns: _spin,
        child: Icon(
          Icons.refresh,
          size: 16,
          color: colorScheme.onSurfaceVariant,
        ),
      ),
      // 保存完成 + 同步完成（单机时也成立：已保存，后续自动同步）。
      _SaveStatus.saved => Icon(
        Icons.check_circle,
        size: 16,
        color: colorScheme.primary,
      ),
      _SaveStatus.error => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, size: 16, color: colorScheme.error),
          const SizedBox(width: 4),
          Text(
            '保存失败',
            style: theme.textTheme.labelMedium?.copyWith(
              color: colorScheme.error,
            ),
          ),
        ],
      ),
    };
    return Padding(
      padding: const EdgeInsets.only(left: 8, right: 4),
      child: Center(child: content),
    );
  }
}

/// 手绘 Lucide 标准「锤子」图标（lucide hammer，viewBox 24x24，stroke）。
///
/// 项目图标优先用 SVG/手绘（CLAUDE.md 规则）：不引入图标库，直接按
/// lucide 官方 hammer 的 path 用 CustomPainter 绘制（stroke 风格：
/// round cap/join、线宽 2/24 相对缩放，任意尺寸清晰）。
class _LucideHammerIcon extends StatelessWidget {
  const _LucideHammerIcon({this.size = 24, this.color});

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(size),
      painter: _LucideHammerPainter(
        color ?? Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}

class _LucideHammerPainter extends CustomPainter {
  _LucideHammerPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    // 24x24 坐标系，缩放到目标尺寸。
    canvas.save();
    canvas.scale(size.width / 24.0, size.height / 24.0);
    canvas.drawPath(_buildPath(), paint);
    canvas.restore();
  }

  /// 还原 lucide hammer.svg 的三段 path（M/m、L/l、H/h、V/v、A/a）。
  Path _buildPath() {
    final p = Path();
    // path1：锤头右上部
    p.moveTo(15, 12);
    p.relativeLineTo(-9.373, 9.373);
    p.relativeArcToPoint(
      const Offset(-3.001, -3),
      radius: const Radius.circular(1),
      clockwise: true,
    );
    p.lineTo(12, 9);
    // path2：手持短把
    p.moveTo(18, 15);
    p.relativeLineTo(4, -4);
    // path3：锤柄主体
    p.moveTo(21.5, 11.5);
    p.relativeLineTo(-1.914, -1.914);
    p.arcToPoint(
      const Offset(19, 8.172),
      radius: const Radius.circular(2),
      clockwise: true,
    );
    p.relativeLineTo(0, -0.344);
    p.relativeArcToPoint(
      const Offset(-0.586, -1.414),
      radius: const Radius.circular(2),
      clockwise: false,
    );
    p.relativeLineTo(-1.657, -1.657);
    p.arcToPoint(
      const Offset(12.516, 3),
      radius: const Radius.circular(6),
      clockwise: false,
    );
    p.lineTo(9, 3); // H9
    p.relativeLineTo(1.243, 1.243);
    p.arcToPoint(
      const Offset(12, 8.485),
      radius: const Radius.circular(6),
      clockwise: true,
    );
    p.lineTo(12, 10); // V10
    p.relativeLineTo(2, 2);
    p.relativeLineTo(1.172, 0); // h1.172
    p.relativeArcToPoint(
      const Offset(1.414, 0.586),
      radius: const Radius.circular(2),
      clockwise: true,
    );
    p.lineTo(18.5, 14.5);
    return p;
  }

  @override
  bool shouldRepaint(covariant _LucideHammerPainter old) => old.color != color;
}

/// 搜索关键词高亮画笔：把匹配矩形（已换算为全局坐标）涂上半透明色。
///
/// 矩形列表与颜色每次渐隐帧都由 AnimatedBuilder 重建传入（color 随
/// 动画值变化驱动重绘；矩形滚动变化由 entry.markNeedsBuild 驱动重建）。
class _SearchHighlightPainter extends CustomPainter {
  _SearchHighlightPainter(this.rects, this.color);

  final List<Rect> rects;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (color.a == 0) return;
    final paint = Paint()..color = color;
    for (final rect in rects) {
      if (rect.isEmpty) continue;
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(3)),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SearchHighlightPainter old) =>
      old.color != color ||
      old.rects.length != rects.length ||
      (rects.isNotEmpty && old.rects.first != rects.first);
}
