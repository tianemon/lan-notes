import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';

import '../../repository/search_history.dart';
import 'glass_style.dart';
import 'search_history_list.dart';

// ============================================================
// 笔记内搜索（编辑页工具栏搜索按钮 → 浮层小窗）
// ============================================================

/// 笔记内搜索的一条匹配。
class EditorSearchMatch {
  const EditorSearchMatch({
    required this.start,
    required this.end,
    required this.plainText,
  });

  /// 匹配在文档纯文本中的起止 offset（quill 文档坐标，与纯文本 index
  /// 一一对应，图片 embed 占 1 字符）。
  final int start;
  final int end;

  /// 搜索时的全文纯文本（片段截取用）。
  final String plainText;
}

/// 打开「笔记内搜索」浮层（与当前窗口等比缩放的小窗，玻璃风格）。
///
/// 输入即搜（200ms 防抖，大小写不敏感）；点击结果（或回车跳第一处）→
/// 关闭浮层并回调 [onJump]——浮层是 modal barrier，搜索期间正文不可编辑，
/// 匹配 offset 在跳转时必然有效。滚动定位与关键词高亮渐隐由编辑页实现。
///
/// [history] 提供时显示搜索历史（空关键词时占结果区；跳转时记入当前
/// 关键词），与首页搜索框共用同一个 store 但作用域隔离
/// （[SearchHistoryScope.note]）。
Future<void> showEditorSearchPanel(
  BuildContext context, {
  required QuillController controller,
  required ValueChanged<EditorSearchMatch> onJump,
  SearchHistoryStore? history,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierColor: Colors.black.withValues(alpha: 0.18),
    builder: (_) => _SearchPanelDialog(
      controller: controller,
      onJump: onJump,
      history: history,
    ),
  );
}

class _SearchPanelDialog extends StatefulWidget {
  const _SearchPanelDialog({
    required this.controller,
    required this.onJump,
    this.history,
  });

  final QuillController controller;
  final ValueChanged<EditorSearchMatch> onJump;

  /// 搜索历史存储（null = 不显示历史；由编辑页从 provider 注入）。
  final SearchHistoryStore? history;

  @override
  State<_SearchPanelDialog> createState() => _SearchPanelDialogState();
}

class _SearchPanelDialogState extends State<_SearchPanelDialog> {
  final TextEditingController _queryController = TextEditingController();
  final FocusNode _queryFocus = FocusNode();
  Timer? _debounce;

  /// 当前匹配列表（空关键词 = 空列表）。
  List<EditorSearchMatch> _matches = const [];

  /// 搜索历史快照（最新的在前）：store 的缓存是异步加载的，这里在浮层
  /// 内持一份副本，增删改后立刻 setState 刷新 UI。
  List<String> _history = const [];

  /// 匹配数量上限：极端文档（如整篇重复同一词）防止列表无限增长。
  static const int _maxMatches = 200;

  /// 搜索框固定高度：外层 SizedBox 占位与 decoration 约束同值，输入内容
  /// （清空按钮出现）时不再改变高度。
  ///
  /// 取值贴合文字本身：正文 bodyMedium(14) 行高约 20px + 上下内边距
  /// 各 8px = 36px，字在框内占比过半，不再显得空旷。
  static const double _searchFieldHeight = 36;

  /// 搜索框统一无描边：显式覆盖主题的 enabled/focusedBorder
  /// （聚焦 1.5px、非聚焦 1.0px，描边外沿绘制看着像框「变高」）。
  static const OutlineInputBorder _fieldBorder = OutlineInputBorder(
    borderRadius: BorderRadius.all(Radius.circular(12)),
    borderSide: BorderSide.none,
  );

  @override
  void initState() {
    super.initState();
    _queryFocus.addListener(() {
      if (mounted) setState(() {});
    });
    unawaited(_loadHistory());
  }

  Future<void> _loadHistory() async {
    final store = widget.history;
    if (store == null) return;
    await store.ensureLoaded();
    if (!mounted) return;
    setState(() => _history = store.entries(SearchHistoryScope.note));
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _queryController.dispose();
    _queryFocus.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 200), _runSearch);
  }

  /// 执行搜索：全文纯文本上找全部匹配（大小写不敏感）。
  ///
  /// quill 纯文本与文档 offset 一一对应；图片占位符 \uFFFC 等长替换为
  /// 「□」展示（不改变 index，跳转定位不受影响）。
  void _runSearch() {
    final query = _queryController.text.trim();
    if (query.isEmpty) {
      setState(() => _matches = const []);
      return;
    }
    final text = widget.controller.document
        .toPlainText()
        .replaceAll('\uFFFC', '□')
        .toLowerCase();
    final needle = query.toLowerCase();
    final matches = <EditorSearchMatch>[];
    var i = text.indexOf(needle);
    while (i != -1 && matches.length < _maxMatches) {
      matches.add(
        EditorSearchMatch(start: i, end: i + needle.length, plainText: text),
      );
      i = text.indexOf(needle, i + (needle.isEmpty ? 1 : needle.length));
    }
    setState(() => _matches = matches);
  }

  /// 跳转到匹配处：记入搜索历史 → 关闭浮层 → 回调编辑页（滚动 + 高亮）。
  ///
  /// 历史只在真正跳转时记录（用户确认）：避免把打错的中间态记进去。
  /// 先 pop 后写库——持久化失败不影响跳转本身。
  void _jump(EditorSearchMatch match) {
    final keyword = _queryController.text.trim();
    if (keyword.isNotEmpty) {
      unawaited(widget.history?.add(SearchHistoryScope.note, keyword));
    }
    Navigator.of(context).pop();
    widget.onJump(match);
  }

  /// 点历史项：填入搜索框并立即执行搜索（不关闭浮层，直接看结果）。
  void _pickHistory(String keyword) {
    _queryController.text = keyword;
    _queryController.selection = TextSelection.collapsed(
      offset: keyword.length,
    );
    _runSearch();
    _queryFocus.requestFocus();
  }

  /// 删除单条历史。
  void _removeHistory(String keyword) async {
    await widget.history?.remove(SearchHistoryScope.note, keyword);
    if (!mounted) return;
    setState(() => _history = List.of(_history)..remove(keyword));
  }

  /// 清空全部历史。
  void _clearHistory() async {
    await widget.history?.clear(SearchHistoryScope.note);
    if (!mounted) return;
    setState(() => _history = const []);
  }

  /// 匹配处的上下文片段：前后各取若干字符（换行转空格），关键词高亮。
  List<TextSpan> _buildSnippetSpans(EditorSearchMatch match, TextStyle base) {
    const contextChars = 24;
    final text = match.plainText;
    var from = (match.start - contextChars).clamp(0, text.length);
    var to = (match.end + contextChars).clamp(0, text.length);
    // 片段边界不切代理对（emoji 等 4 字节字符）：from 落在低位代理
    // （后半）→ 回退包含整字符；to 前一码元是高位代理（前半）→ 前进补全。
    while (from > 0 &&
        from < text.length &&
        text.codeUnitAt(from) >= 0xDC00 &&
        text.codeUnitAt(from) <= 0xDFFF) {
      from--;
    }
    while (to > from &&
        to < text.length &&
        text.codeUnitAt(to - 1) >= 0xD800 &&
        text.codeUnitAt(to - 1) <= 0xDBFF) {
      to++;
    }
    final prefix = text.substring(from, match.start).replaceAll('\n', ' ');
    final keyword = text.substring(match.start, match.end);
    final suffix = text.substring(match.end, to).replaceAll('\n', ' ');
    final scheme = Theme.of(context).colorScheme;
    return [
      TextSpan(
        text: (from > 0 ? '…' : '') + prefix,
        style: base.copyWith(color: scheme.onSurfaceVariant),
      ),
      TextSpan(
        text: keyword,
        style: base.copyWith(
          color: scheme.primary,
          fontWeight: FontWeight.w700,
        ),
      ),
      TextSpan(
        text: suffix + (to < text.length ? '…' : ''),
        style: base.copyWith(color: scheme.onSurfaceVariant),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    // 与当前窗口等比缩放的小窗：宽 = 窗口宽 60%，高按同比例推导
    // （宽高比恒等于窗口宽高比）；高度超出屏幕才额外封顶。
    final ratio = mq.size.height / mq.size.width;
    final width = (mq.size.width * 0.6).clamp(300.0, 640.0);
    final height = (width * ratio).clamp(320.0, mq.size.height * 0.85);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final scheme = Theme.of(context).colorScheme;
    final hasQuery = _queryController.text.trim().isNotEmpty;

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.all(16),
      child: glassWrap(
        child: Container(
          width: width,
          height: height,
          decoration: styledDecoration(isDark: isDark),
          // 面板自身零内边距：左右内边距只给搜索框区（下方 Padding），
          // 历史/结果列表撑满面板——历史行 hover 距面板边缘 8px（行内
          // 自带），与首页浮层一致；此前容器左右 16px 让编辑页 hover
          // 缩进 24px，看起来比首页「悬空」一截。底部仍无内边距：
          // 「全部清除」按钮贴面板底边（与首页浮层一致）；匹配结果
          // 列表自带 bottom 8 保持留白。
          padding: EdgeInsets.zero,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // 搜索框：圆角填充底 + 放大镜图标 + 一键清空。
                    //
                    // 外层 SizedBox 钉死高度：内部任何状态变化（清空按钮出现、
                    // 提示文字换成输入文字、聚焦描边粗细）都不再引起布局跳变。
                    SizedBox(
                      height: _searchFieldHeight,
                      child: TextField(
                        controller: _queryController,
                        focusNode: _queryFocus,
                        autofocus: true,
                        onChanged: _onQueryChanged,
                        onSubmitted: (_) {
                          if (_matches.isNotEmpty) _jump(_matches.first);
                        },
                        textInputAction: TextInputAction.search,
                        style: Theme.of(context).textTheme.bodyMedium,
                        decoration: InputDecoration(
                          isDense: true,
                          // 双保险：外部 SizedBox 固定占位高度，decoration 自身
                          // 也固定为同值——空态 40px，输入后出现「清空」
                          // IconButton（默认 48px 最小触控区）把框撑到 48px。
                          constraints: const BoxConstraints(
                            minHeight: _searchFieldHeight,
                            maxHeight: _searchFieldHeight,
                          ),
                          hintText: '在当前笔记中搜索',
                          // 提示文字与输入文字同字号：M3 默认 hint 用 bodyLarge
                          // （16），输入用 bodyMedium（14），不显式指定会有一高一矮。
                          hintStyle: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                          prefixIcon: const Icon(Icons.search, size: 20),
                          prefixIconConstraints: const BoxConstraints.tightFor(
                            width: 36,
                            height: _searchFieldHeight,
                          ),
                          // 固定后缀槽位尺寸：「清空」按钮出现/消失不改变框内布局。
                          suffixIconConstraints: const BoxConstraints.tightFor(
                            width: 36,
                            height: _searchFieldHeight,
                          ),
                          suffixIcon: hasQuery
                              ? IconButton(
                                  visualDensity: VisualDensity.compact,
                                  iconSize: 18,
                                  // IconButton 默认最小触控区 48px，在 36px 高的框里
                                  // 会溢出，显式压到与框同高（padding 归零）。
                                  constraints: const BoxConstraints.tightFor(
                                    width: 36,
                                    height: _searchFieldHeight,
                                  ),
                                  padding: EdgeInsets.zero,
                                  icon: const Icon(Icons.close),
                                  onPressed: () {
                                    _queryController.clear();
                                    _runSearch();
                                    _queryFocus.requestFocus();
                                  },
                                )
                              : null,
                          filled: true,
                          fillColor: scheme.surfaceContainerHighest.withValues(
                            alpha: isDark ? 0.4 : 0.6,
                          ),
                          // 上下 8px：正文行高 ~20 + 16 = 框高 36，文字垂直居中。
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          // 显式覆盖 inputDecorationTheme 的 enabled/focusedBorder：
                          // 主题聚焦描边 1.5px、非聚焦 1.0px，描边外沿绘制会让人
                          // 觉得框「变厚/变高」，这里统一无描边（只显示光标）。
                          border: _fieldBorder,
                          enabledBorder: _fieldBorder,
                          focusedBorder: _fieldBorder,
                          disabledBorder: _fieldBorder,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    // 匹配数（仅搜索时渲染）。空关键词整行不渲染：此前
                    // Text('') 仍占 labelSmall 行高（16px），把下方历史
                    // 列表顶下去，「搜索框→首条历史」间距被撑到 26px。
                    if (hasQuery)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Text(
                          '${_matches.length} 处匹配',
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(child: _buildResults()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildResults() {
    final theme = Theme.of(context);
    final hasQuery = _queryController.text.trim().isNotEmpty;
    if (!hasQuery) {
      // 空关键词：有历史就展示历史（可单条删除 / 全部清除），
      // 否则退回输入提示。
      if (_history.isNotEmpty) return _buildHistory();
      return _buildHint('输入关键词搜索当前笔记');
    }
    if (_matches.isEmpty) {
      return _buildHint('未找到匹配内容');
    }
    return ListView.builder(
      padding: const EdgeInsets.only(top: 2, bottom: 8),
      itemCount: _matches.length,
      itemBuilder: (context, index) {
        final match = _matches[index];
        return Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => _jump(match),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        children: _buildSnippetSpans(
                          match,
                          theme.textTheme.bodyMedium!,
                        ),
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  // 匹配序号：视觉锚点，也暗示「第几处」。
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      '${index + 1}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 搜索历史面板：占满结果区（父级 Expanded 提供有界高度）。
  ///
  /// 无底部内边距：「全部清除」按钮贴面板底边（与首页浮层一致，用户
  /// 要求两侧统一）。
  ///
  /// 顶部 6px + 搜索框下方的 SizedBox(8) = 「搜索框→首条历史」间距
  /// 14px（原 26px：8 + 空态匹配数行占位 16 + 顶部 2；用户先在 20→12
  /// 比例 ×0.6 下取 16px，再微调收窄到 14px），同时保证首行 hover
  /// 不顶到搜索框。
  ///
  /// 首行**不**加顶部圆角（roundFirstItem: false）：编辑页面板顶部是
  /// 搜索框，首行不接触面板圆角，矩形 hover 即可——首页浮层首行贴顶
  /// 才需要圆角适配（见 SearchHistoryList.roundFirstItem）。
  Widget _buildHistory() {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: SearchHistoryList(
        entries: _history,
        onPick: _pickHistory,
        onRemove: _removeHistory,
        onClearAll: _clearHistory,
        roundFirstItem: false,
      ),
    );
  }

  Widget _buildHint(String text) {
    return Center(
      child: Text(
        text,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
