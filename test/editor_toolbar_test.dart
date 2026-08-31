import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lan_notes/app/data/database.dart';
import 'package:lan_notes/app/repository/note_repository.dart';
import 'package:lan_notes/app/repository/providers.dart';
import 'package:lan_notes/app/repository/search_history.dart';
import 'package:lan_notes/app/theme.dart';
import 'package:lan_notes/app/ui/editor_page.dart';

/// 编辑页底部工具栏回归：
/// 1. 锤子按钮可展开格式工具栏；
/// 2. 笔记内搜索可连续跳转多次（高亮 AnimationController 多次创建，
///    SingleTickerProviderStateMixin 会在第二次抛断言）。
void main() {
  late AppDatabase db;
  late NoteRepository noteRepo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    noteRepo = NoteRepository(db.noteDao);
  });

  tearDown(() async {
    await db.close();
  });

  /// 卸载 widget 树释放 provider 对 db 的引用，并 pump 足够时长让
  /// drift stream 取消时创建的 0 延迟 Timer 执行完。
  Future<void> disposeTree(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<String> pumpEditor(
    WidgetTester tester, {
    String content = '正文',
    ThemeData? theme,
  }) async {
    final note = await noteRepo.createNote(title: '笔记一', content: content);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          noteRepositoryProvider.overrideWithValue(noteRepo),
        ],
        child: MaterialApp(
          // 与正式 App 同款主题（真实应用的 inputDecorationTheme 会通过
          // applyDefaults 填进搜索框的 enabled/focusedBorder，影响高度）。
          theme: theme,
          // quill 工具栏按钮需要 FlutterQuillLocalizations（正式 App 已注册）。
          localizationsDelegates:
              FlutterQuillLocalizations.localizationsDelegates,
          home: EditorPage(id: note.id),
        ),
      ),
    );
    // 消化笔记流加载 + 入场动画（不用 pumpAndSettle：Quill 光标闪烁
    // 是常驻重复动画，settle 永远等不到稳定）。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    return note.id;
  }

  testWidgets('锤子按钮展开/收起格式工具栏', (tester) async {
    await pumpEditor(tester);

    // 默认收起：无格式工具栏。
    expect(find.byType(QuillSimpleToolbar), findsNothing);

    await tester.tap(find.byTooltip('展开格式工具栏'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    expect(find.byType(QuillSimpleToolbar), findsOneWidget);

    await tester.tap(find.byTooltip('收起格式工具栏'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(QuillSimpleToolbar), findsNothing);

    await disposeTree(tester);
  });

  testWidgets('笔记内搜索连续跳转两次均高亮（不抛 ticker 断言）', (tester) async {
    await pumpEditor(tester, content: '苹果 香蕉 苹果 橙子 苹果');

    // 高亮浮层 = Overlay 中用 _SearchHighlightPainter 的 CustomPaint
    // （类型私有，按 runtimeType 字符串识别）。
    int highlightCount() => tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .where(
          (w) => w.painter.runtimeType.toString() == '_SearchHighlightPainter',
        )
        .length;

    Future<void> jumpToFirstMatch() async {
      await tester.tap(find.byTooltip('笔记内搜索'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.enterText(find.byType(TextField).last, '苹果');
      // 防抖 200ms + 结果列表构建。
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('3 处匹配'), findsOneWidget);
      // 点第一条结果 → 关闭浮层 + 跳转高亮（限定在 Dialog 内，避免命中
      // 正文里的同名 RichText）。
      // 结果项 = Dialog 内 ListView 里的 InkWell（Dialog 里还有一个清空
      // 按钮的 InkWell，按树序在前，需限定到 ListView 内）。
      final resultsList = find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(ListView),
      );
      final firstResult = find
          .descendant(of: resultsList, matching: find.byType(InkWell))
          .first;
      await tester.tap(firstResult);
      await tester.pump(const Duration(milliseconds: 400));
    }

    await jumpToFirstMatch();
    expect(tester.takeException(), isNull, reason: '首次跳转不应抛异常');
    expect(highlightCount(), 1, reason: '首次跳转应插入 1 个高亮浮层');

    await jumpToFirstMatch();
    expect(tester.takeException(), isNull, reason: '第二次跳转不应抛异常');
    expect(highlightCount(), 1, reason: '第二次跳转应插入 1 个高亮浮层');

    // 高亮 2.8s 后自动移除（保持 2s + 渐隐 0.8s）。
    await tester.pump(const Duration(milliseconds: 3000));
    expect(highlightCount(), 0, reason: '高亮到期应自动移除');

    await disposeTree(tester);
  });

  testWidgets('高亮未消失前重开搜索弹窗，应先移除高亮（避免透出）', (tester) async {
    await pumpEditor(tester, content: '苹果 香蕉 苹果 橙子 苹果');

    // 高亮浮层 = Overlay 中用 _SearchHighlightPainter 的 CustomPaint。
    int highlightCount() => tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .where(
          (w) => w.painter.runtimeType.toString() == '_SearchHighlightPainter',
        )
        .length;

    // 搜索并跳转一次 → 产生高亮。
    await tester.tap(find.byTooltip('笔记内搜索'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.enterText(find.byType(TextField).last, '苹果');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 100));
    final resultsList = find.descendant(
      of: find.byType(Dialog),
      matching: find.byType(ListView),
    );
    await tester.tap(
      find.descendant(of: resultsList, matching: find.byType(InkWell)).first,
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(highlightCount(), 1, reason: '跳转后应已有高亮');

    // 高亮仍在（未到 2.8s）时重开搜索弹窗：应先把旧高亮移除，否则它
    // 会垫在弹窗的半透明 barrier 下面透出来。
    await tester.tap(find.byTooltip('笔记内搜索'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 100));
    expect(highlightCount(), 0, reason: '打开搜索弹窗应移除未消失的高亮');

    await disposeTree(tester);
  });

  testWidgets('搜索框高度不随输入内容变化（真实亮色主题）', (tester) async {
    await pumpEditor(tester, content: '苹果', theme: buildLightTheme());

    await tester.tap(find.byTooltip('笔记内搜索'));
    await tester.pump(const Duration(milliseconds: 400));

    final fieldFinder = find
        .descendant(of: find.byType(Dialog), matching: find.byType(TextField))
        .first;

    double fieldHeight() => tester.getSize(fieldFinder).height;

    double decoratorHeight() => tester
        .getSize(
          find.descendant(
            of: find.byType(Dialog),
            matching: find.byType(InputDecorator),
          ),
        )
        .height;

    final emptyField = fieldHeight();
    final emptyDecorator = decoratorHeight();

    await tester.enterText(fieldFinder, '苹果');
    // 防抖 200ms + 清空按钮出现。
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 100));
    final typedField = fieldHeight();
    final typedDecorator = decoratorHeight();

    // 清空后（清空按钮消失）高度不变。
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump(const Duration(milliseconds: 300));
    final clearedField = fieldHeight();
    final clearedDecorator = decoratorHeight();
    debugPrint(
      'field height: empty=$emptyField typed=$typedField cleared=$clearedField; '
      'decorator: empty=$emptyDecorator typed=$typedDecorator '
      'cleared=$clearedDecorator',
    );

    // 三态（空 / 有内容 / 清空后）高度完全一致。
    expect(typedField, emptyField);
    expect(typedDecorator, emptyDecorator);
    expect(clearedField, emptyField);
    expect(clearedDecorator, emptyDecorator);

    await disposeTree(tester);
  });

  testWidgets('搜索框高度不随输入内容变化（真实暗色主题）', (tester) async {
    await pumpEditor(tester, content: '苹果', theme: buildDarkTheme());

    await tester.tap(find.byTooltip('笔记内搜索'));
    await tester.pump(const Duration(milliseconds: 400));

    final fieldFinder = find
        .descendant(of: find.byType(Dialog), matching: find.byType(TextField))
        .first;

    double fieldHeight() => tester.getSize(fieldFinder).height;

    final emptyField = fieldHeight();

    await tester.enterText(fieldFinder, '苹果');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 100));
    final typedField = fieldHeight();
    debugPrint('dark field height: empty=$emptyField typed=$typedField');

    expect(typedField, emptyField);

    await disposeTree(tester);
  });

  testWidgets('macOS 窗口尺寸下搜索框高度不随输入内容变化', (tester) async {
    // 真实桌面环境：macOS 平台 + 1440×900 窗口（VisualDensity / 触控区
    // 尺寸在桌面平台可能有差异）。
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 2.0;

    await pumpEditor(tester, content: '苹果', theme: buildLightTheme());

    await tester.tap(find.byTooltip('笔记内搜索'));
    await tester.pump(const Duration(milliseconds: 400));

    final fieldFinder = find
        .descendant(of: find.byType(Dialog), matching: find.byType(TextField))
        .first;
    double fieldHeight() => tester.getSize(fieldFinder).height;

    final emptyField = fieldHeight();

    await tester.enterText(fieldFinder, '苹果');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 100));
    final typedField = fieldHeight();
    debugPrint('macOS field height: empty=$emptyField typed=$typedField');

    expect(typedField, emptyField);

    await disposeTree(tester);

    // 平台覆盖必须在用例体内复位（框架在 tearDown 前校验 debug 变量）。
    debugDefaultTargetPlatformOverride = null;
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  testWidgets('笔记内搜索：历史可跳转 / 单条删除 / 全部清除', (tester) async {
    // 笔记正文：苹果 3 处、香蕉 1 处（历史项「香蕉」跳转后应为 1 处匹配）。
    await pumpEditor(tester, content: '苹果 香蕉 苹果 橙子 苹果');

    /// 打开浮层（并等历史异步加载完成）。
    ///
    /// 历史是从数据库异步加载的：db 查询在 pump 末尾的微任务里完成，
    /// setState 会落在最后一帧之后，必须再推一帧才会重建出历史面板。
    Future<void> openPanel() async {
      await tester.tap(find.byTooltip('笔记内搜索'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 100));
    }

    /// 清空输入（Dialog 内搜索框的 suffixIcon），回到空态。
    Future<void> clearInput() async {
      await tester.tap(
        find
            .descendant(
              of: find.byType(Dialog),
              matching: find.byIcon(Icons.close),
            )
            .first,
      );
      await tester.pump(const Duration(milliseconds: 400));
    }

    /// 点第一条匹配结果跳转（Dialog 关闭）。
    Future<void> jumpFirst() async {
      final resultsList = find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(ListView),
      );
      await tester.tap(
        find.descendant(of: resultsList, matching: find.byType(InkWell)).first,
      );
      await tester.pump(const Duration(milliseconds: 400));
    }

    Future<void> search(String keyword) async {
      await tester.enterText(find.byType(TextField).last, keyword);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 100));
    }

    // 1. 无历史时显示输入提示。
    await openPanel();
    expect(find.text('输入关键词搜索当前笔记'), findsOneWidget);

    // 2. 搜索并跳转 → 关键词记入历史（只在跳转时记，不是输入时记）。
    await search('香蕉');
    expect(find.text('1 处匹配'), findsOneWidget);
    await jumpFirst();

    await openPanel();
    expect(find.text('香蕉'), findsOneWidget, reason: '跳转过的关键词应出现在历史里');
    expect(find.text('全部清除'), findsOneWidget);

    // 3. 点历史项 = 填入并立即搜索。
    await tester.tap(find.text('香蕉'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('1 处匹配'), findsOneWidget);

    // 4. 单条删除 → 历史清空，退回输入提示。
    await clearInput();
    await tester.tap(find.byTooltip('删除这条历史').first);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('香蕉'), findsNothing);
    expect(find.text('输入关键词搜索当前笔记'), findsOneWidget);

    // 5. 再跳一次 → 用「全部清除」清空历史。
    await search('橙子');
    await jumpFirst();
    await openPanel();
    expect(find.text('橙子'), findsOneWidget, reason: '历史应记入新关键词');
    await tester.tap(find.text('全部清除'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('橙子'), findsNothing);
    expect(find.text('输入关键词搜索当前笔记'), findsOneWidget);

    await disposeTree(tester);
  });

  testWidgets('编辑页「全部清除」按钮贴面板底边（与首页浮层一致）', (tester) async {
    // 直接写库一条笔记作用域历史：编辑页搜索面板从同一个 db 读取。
    final store = SearchHistoryStore(db.deviceDao);
    await store.add(SearchHistoryScope.note, '贴底词');
    await pumpEditor(tester, content: '苹果');

    await tester.tap(find.byTooltip('笔记内搜索'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('贴底词'), findsOneWidget, reason: '历史应出现在面板里');

    // 玻璃面板本体 = glassWrap 的 ClipRRect（BackdropFilter 的最近祖先）。
    final panelRect = tester.getRect(
      find
          .ancestor(
            of: find.byType(BackdropFilter),
            matching: find.byType(ClipRRect),
          )
          .first,
    );
    final buttonRect = tester.getRect(
      find.ancestor(
        of: find.text('全部清除'),
        matching: find.byType(TextButton),
      ),
    );

    // 按钮底边应贴面板底边（此前容器底部 8 + 面板 8 的 padding 让它
    // 悬空 16px，与首页浮层不一致）。
    expect(panelRect.bottom - buttonRect.bottom, lessThan(1.0),
        reason: '「全部清除」按钮应贴编辑页面板底边');

    await disposeTree(tester);
  });

  testWidgets('编辑页历史行 hover 撑满面板（与首页一致），首行无圆角', (tester) async {
    final store = SearchHistoryStore(db.deviceDao);
    await store.add(SearchHistoryScope.note, '撑满词');
    await pumpEditor(tester, content: '苹果');

    await tester.tap(find.byTooltip('笔记内搜索'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('撑满词'), findsOneWidget, reason: '历史应出现在面板里');

    // 玻璃面板本体 = glassWrap 的 ClipRRect。
    final panelRect = tester.getRect(
      find
          .ancestor(
            of: find.byType(BackdropFilter),
            matching: find.byType(ClipRRect),
          )
          .first,
    );

    // 历史行 InkWell（限定在 Dialog 内 ListView 中，排除搜索框/按钮的）。
    final historyInk = find.descendant(
      of: find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(ListView),
      ),
      matching: find.byType(InkWell),
    );
    final rowRect = tester.getRect(historyInk.first);

    // 「搜索框→首条历史」间距：空态匹配数行条件渲染后不再占 16px 行高，
    // SizedBox(8) + 历史面板 top(6) = 14px（原 26px：先按 20→12 比例 ×0.6
    // 取 16px，用户再微调收窄到 14px）；搜索框位置由面板顶部 padding
    // 决定，改动不应动它。
    final fieldRect = tester.getRect(find.byType(TextField).last);
    final gap = rowRect.top - fieldRect.bottom;
    expect(gap, closeTo(14, 2),
        reason: '首条历史距搜索框应约 14px（原 26px，用户拍板）');

    // hover 高亮矩形 = InkWell 整行，应撑满面板宽度。此前容器左右 16px
    // padding 让它缩进 16px，比首页浮层「悬空」一截；改后相对面板仅
    // 内缩 0.5px（探针实测：首页浮层与编辑页同为 0.5px，是玻璃面板的
    // 固有偏移，两边一致）。断言 <2px 容差：锁住「不再有 16px 缩进」
    // 这条回归，同时容纳面板固有的半像素内缩。
    final leftGap = (rowRect.left - panelRect.left).abs();
    final rightGap = (panelRect.right - rowRect.right).abs();
    expect(leftGap, lessThan(2.0), reason: '历史行 hover 应贴面板左缘，与首页浮层一致');
    expect(rightGap, lessThan(2.0), reason: '历史行 hover 应贴面板右缘，与首页浮层一致');

    // 首行 hover 无顶部圆角：编辑页面板顶部是搜索框，首行不接触圆角。
    final firstInk = tester.widget<InkWell>(historyInk.first);
    expect(firstInk.borderRadius, isNull,
        reason: '编辑页首行不接触面板圆角，hover 应为矩形（首页贴顶才需要圆角）');

    await disposeTree(tester);
  });
}
