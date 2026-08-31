import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lan_notes/app/data/database.dart';
import 'package:lan_notes/app/repository/folder_repository.dart';
import 'package:lan_notes/app/repository/note_repository.dart';
import 'package:lan_notes/app/repository/providers.dart';
import 'package:lan_notes/app/repository/search_history.dart';
import 'package:lan_notes/app/theme.dart';
import 'package:lan_notes/app/ui/home_page.dart';
import 'package:lan_notes/app/ui/widgets/search_history_list.dart';

/// 搜索历史回归：
/// 1. [SearchHistoryStore] 行为（去重提最前、上限淘汰、删除/清除、
///    两个作用域互不相通、跨实例持久化、损坏值容错）；
/// 2. 首页搜索框聚焦且无输入时浮出历史（可单条删除 / 全部清除）。
void main() {
  late AppDatabase db;
  late SearchHistoryStore store;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    store = SearchHistoryStore(db.deviceDao);
  });

  tearDown(() async {
    await db.close();
  });

  group('SearchHistoryStore', () {
    test('重复的关键词提到最前，不产生第二条', () async {
      await store.add(SearchHistoryScope.home, '苹果');
      await store.add(SearchHistoryScope.home, '香蕉');
      await store.add(SearchHistoryScope.home, '苹果');

      expect(store.entries(SearchHistoryScope.home), [
        '苹果',
        '香蕉',
      ], reason: '再次搜索已有词应提到最前且只有一条');
    });

    test('超过 50 条淘汰最旧的', () async {
      for (var i = 0; i < 55; i++) {
        await store.add(SearchHistoryScope.home, 'k$i');
      }
      final entries = store.entries(SearchHistoryScope.home);
      expect(entries.length, SearchHistoryStore.maxEntries);
      // 最新的在最前（k54），最旧的 5 条（k0..k4）被淘汰。
      expect(entries.first, 'k54');
      expect(entries.last, 'k5');
    });

    test('两个作用域互不相通', () async {
      await store.add(SearchHistoryScope.home, '首页词');
      await store.add(SearchHistoryScope.note, '笔记词');

      expect(store.entries(SearchHistoryScope.home), ['首页词']);
      expect(store.entries(SearchHistoryScope.note), ['笔记词']);
    });

    test('删除单条 / 全部清除', () async {
      await store.add(SearchHistoryScope.home, '甲');
      await store.add(SearchHistoryScope.home, '乙');

      await store.remove(SearchHistoryScope.home, '甲');
      expect(store.entries(SearchHistoryScope.home), ['乙']);

      await store.clear(SearchHistoryScope.home);
      expect(store.entries(SearchHistoryScope.home), isEmpty);
    });

    test('持久化：新建 store 实例后历史仍在', () async {
      await store.add(SearchHistoryScope.note, '持久化词');

      final reloaded = SearchHistoryStore(db.deviceDao);
      await reloaded.ensureLoaded();
      expect(reloaded.entries(SearchHistoryScope.note), ['持久化词']);
    });

    test('持久化值损坏时按空历史处理（不抛异常）', () async {
      await db.deviceDao.setSetting('search_history_home', 'not-json');

      final reloaded = SearchHistoryStore(db.deviceDao);
      await reloaded.ensureLoaded();
      expect(reloaded.entries(SearchHistoryScope.home), isEmpty);
    });
  });

  group('首页搜索框历史浮层', () {
    late NoteRepository noteRepo;
    late FolderRepository folderRepo;

    setUp(() {
      noteRepo = NoteRepository(db.noteDao);
      folderRepo = FolderRepository(db.folderDao, noteRepo);
    });

    /// 卸载 widget 树释放 provider 对 db 的引用，并 pump 足够时长让
    /// drift stream 取消时创建的 0 延迟 Timer 执行完。
    Future<void> disposeTree(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 300));
    }

    Future<void> pumpHome(WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            noteRepositoryProvider.overrideWithValue(noteRepo),
            folderRepositoryProvider.overrideWithValue(folderRepo),
          ],
          child: const MaterialApp(home: HomePage()),
        ),
      );
      // 消化笔记流加载 + 历史异步加载。
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('聚焦空搜索框浮出历史，可单条删除与全部清除', (tester) async {
      await store.add(SearchHistoryScope.home, '关键词甲');
      await store.add(SearchHistoryScope.home, '关键词乙');
      await pumpHome(tester);

      // 未聚焦时不显示历史。
      expect(find.text('关键词甲'), findsNothing);

      await tester.tap(find.byType(TextField));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('关键词甲'), findsOneWidget, reason: '聚焦后应浮出历史');
      expect(find.text('关键词乙'), findsOneWidget);
      expect(find.text('全部清除'), findsOneWidget);

      // 单条删除：只删掉所点的那条（最新的排最前，first = 关键词乙）。
      await tester.tap(find.byTooltip('删除这条历史').first);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('关键词乙'), findsNothing);
      expect(find.text('关键词甲'), findsOneWidget);

      // 全部清除：浮层收起（历史为空不再浮出）。
      await tester.tap(find.text('全部清除'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('关键词甲'), findsNothing);
      expect(find.text('全部清除'), findsNothing);

      // 持久化层也已清空（另起 store 实例从库里读：UI 用的是 provider
      // 注入的实例，其内存缓存与这里无关）。
      final reloaded = SearchHistoryStore(db.deviceDao);
      await reloaded.ensureLoaded();
      expect(reloaded.entries(SearchHistoryScope.home), isEmpty);

      await disposeTree(tester);
    });

    testWidgets('点击历史项填入搜索框并收起浮层', (tester) async {
      await store.add(SearchHistoryScope.home, '关键词甲');
      await pumpHome(tester);

      await tester.tap(find.byType(TextField));
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.text('关键词甲'));
      await tester.pump(const Duration(milliseconds: 300));

      final field = tester.widget<TextField>(find.byType(TextField).first);
      expect(field.controller!.text, '关键词甲');
      expect(find.text('全部清除'), findsNothing, reason: '输入非空后浮层应收起');

      await disposeTree(tester);
    });

    testWidgets('首页不显示笔记内搜索的历史（作用域隔离）', (tester) async {
      await store.add(SearchHistoryScope.note, '笔记内词');
      await pumpHome(tester);

      await tester.tap(find.byType(TextField));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('笔记内词'), findsNothing);
      expect(find.text('全部清除'), findsNothing);

      await disposeTree(tester);
    });

    testWidgets('输入停顿约 1 秒后自动记录历史（不按回车也记）', (tester) async {
      await pumpHome(tester);

      await tester.tap(find.byType(TextField));
      await tester.pump(const Duration(milliseconds: 300));
      // 输入即过滤、不按回车：停顿 1 秒触发防抖记录。
      await tester.enterText(find.byType(TextField), '自动记录词');
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 300));

      // UI 用的是 provider 的 store 实例（内存缓存与测试的 store 不同步），
      // 从数据库层验证：防抖记录确实写进了持久化。
      final reloaded = SearchHistoryStore(db.deviceDao);
      await reloaded.ensureLoaded();
      expect(reloaded.entries(SearchHistoryScope.home), ['自动记录词']);

      await disposeTree(tester);
    });

    testWidgets('聚焦早于历史加载完成时，加载后浮层也应补上（竞态）', (tester) async {
      await store.add(SearchHistoryScope.home, '竞态词');
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            noteRepositoryProvider.overrideWithValue(noteRepo),
            folderRepositoryProvider.overrideWithValue(folderRepo),
          ],
          child: const MaterialApp(home: HomePage()),
        ),
      );
      // 只推一帧就立刻聚焦：此刻历史可能还没从 db 加载完（此前 bug 是
      // 聚焦时历史为空→不建浮层，加载完成后也没有再次触发展开逻辑）。
      await tester.pump();
      await tester.tap(find.byType(TextField));
      await tester.pump(const Duration(milliseconds: 100));
      // 等历史异步加载完成 + 浮层补建。
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('竞态词'), findsOneWidget, reason: '加载完成后应补出浮层');

      await disposeTree(tester);
    });
  });

  group('SearchHistoryList 组件', () {
    // macOS 桌面默认 VisualDensity.compact 会把按钮 padding 上下各减 8px：
    // 若不显式指定 standard，vertical 6 的 padding 会被完全抵消（按钮与
    // 文字等高 16px）。此用例模拟桌面密度，防止该回归再次出现。
    testWidgets('桌面密度下「全部清除」按钮仍有明显厚度', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
            visualDensity: VisualDensity.compact,
          ),
          home: Scaffold(
            body: SearchHistoryList(
              entries: const ['历史一'],
              onPick: (_) {},
              onRemove: (_) {},
              onClearAll: () {},
            ),
          ),
        ),
      );

      final button = find.ancestor(
        of: find.text('全部清除'),
        matching: find.byType(TextButton),
      );
      final height = tester.getSize(button).height;
      // 期望 28px（内容 16 + 上下各 6）；density 吃掉 padding 时只有 16px。
      expect(height, greaterThanOrEqualTo(26),
          reason: '桌面密度下按钮 padding 不应被 VisualDensity.compact 抵消，'
              'hover 背景应明显比文字厚');
    });

    // 深色模式下 M3 默认 hover 只有白 8%，几乎看不见；且首行 hover 若
    // 用直角矩形会顶到浮层圆角露出直角。两者都在共用组件里统一处理，
    // 此处锁定行为防止回归。
    testWidgets('深色主题：历史行 hover 增强、首行 hover 顶部圆角匹配浮层', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            brightness: Brightness.dark,
            colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.blue,
              brightness: Brightness.dark,
            ),
          ),
          home: Scaffold(
            body: SearchHistoryList(
              entries: const ['历史一', '历史二'],
              onPick: (_) {},
              onRemove: (_) {},
              onClearAll: () {},
            ),
          ),
        ),
      );

      // 行 InkWell（限定在 ListView 内，排除 IconButton/TextButton 的）。
      final rowInks = find.descendant(
        of: find.byType(ListView),
        matching: find.byType(InkWell),
      );
      final first = tester.widget<InkWell>(rowInks.first);
      final second = tester.widget<InkWell>(rowInks.at(1));

      // hover 增强：深色为白 12%（默认 8% 太浅）。
      expect(first.hoverColor, Colors.white.withValues(alpha: 0.12),
          reason: '深色模式 hover 应增强到白 12%');

      // 首行顶部圆角匹配浮层（kAppRadius），其余行无圆角。
      expect(
        first.borderRadius,
        const BorderRadius.vertical(top: Radius.circular(kAppRadius)),
        reason: '首行 hover 顶部应与浮层圆角一致，避免直角溢出',
      );
      expect(second.borderRadius, isNull, reason: '非首行不需要圆角');

      // 每行自带透明 Material 画布：hover/splash ink 画在玻璃面板半透明
      // 背景**之上**（画在外层 Material 上会被背景罩住，深色白 12% 叠在
      // 白 10% 背景之下几乎看不见——「全部清除」按钮因内部自带 Material
      // 而明显，历史行需同款结构）。断言行 InkWell 的最近 Material 祖先
      // 在行内（ListView 内）且透明。
      final firstMaterial = find
          .ancestor(of: rowInks.first, matching: find.byType(Material))
          .first;
      expect(
        find
            .descendant(of: find.byType(ListView), matching: firstMaterial)
            .evaluate()
            .isNotEmpty,
        isTrue,
        reason: '行 InkWell 的 ink 画布应在行内（面板背景之上）',
      );
      expect(tester.widget<Material>(firstMaterial).type, MaterialType.transparency,
          reason: '行 Material 应透明（只提供画布，不遮挡背景）');
    });

    // 首页浮层首行贴顶才需要圆角；编辑页顶部是搜索框、首行不接触面板
    // 圆角，传 roundFirstItem: false 后应恢复矩形 hover——该一致的一致，
    // 该单独适配的单独，参数化由调用方决定。
    testWidgets('roundFirstItem: false 时首行 hover 无顶部圆角（编辑页场景）', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SearchHistoryList(
              entries: const ['历史一', '历史二'],
              onPick: (_) {},
              onRemove: (_) {},
              onClearAll: () {},
              roundFirstItem: false,
            ),
          ),
        ),
      );

      final rowInks = find.descendant(
        of: find.byType(ListView),
        matching: find.byType(InkWell),
      );
      final first = tester.widget<InkWell>(rowInks.first);
      final second = tester.widget<InkWell>(rowInks.at(1));
      expect(first.borderRadius, isNull,
          reason: '列表上方有其他内容（编辑页顶部是搜索框）时，'
              '首行 hover 不需要顶部圆角');
      expect(second.borderRadius, isNull);
    });
  });
}
