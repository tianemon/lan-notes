import 'dart:convert';

import '../data/device_dao.dart';

/// 搜索历史作用域：两个搜索框各存一份，互不相通（用户确认）。
enum SearchHistoryScope {
  /// 编辑页「笔记内搜索」浮层。
  note,

  /// 首页笔记列表搜索框。
  home,
}

/// 搜索历史存储（全局：不随笔记走，跨启动保留）。
///
/// 复用 DeviceSettings 键值表（同 [AppSettingsStore]，不引入
/// shared_preferences 依赖）：每个作用域一个键，值为 JSON 字符串数组，
/// 最近用过的排在最前，超过 [maxEntries] 淘汰最旧的一条。
///
/// 内存缓存提供同步读取，[ensureLoaded] 从数据库加载（幂等，模式同
/// [AppSettingsStore.ensureLoaded]）；未加载完成时 [entries] 返回空列表。
class SearchHistoryStore {
  SearchHistoryStore(this._dao);

  final DeviceDao _dao;

  /// 每个作用域最多保留的条数（用户确认 50 条）。
  static const int maxEntries = 50;

  final Map<SearchHistoryScope, List<String>> _cache = {};
  Future<void>? _loading;

  static String _keyOf(SearchHistoryScope scope) => switch (scope) {
    SearchHistoryScope.note => 'search_history_note',
    SearchHistoryScope.home => 'search_history_home',
  };

  /// 某作用域的历史（最新的在前；未加载返回空列表）。
  List<String> entries(SearchHistoryScope scope) =>
      List.unmodifiable(_cache[scope] ?? const <String>[]);

  /// 从数据库加载全部作用域并缓存（幂等；返回的 Future 缓存复用）。
  Future<void> ensureLoaded() => _loading ??= _load();

  Future<void> _load() async {
    for (final scope in SearchHistoryScope.values) {
      _cache[scope] = _decode(await _dao.getSetting(_keyOf(scope)));
    }
  }

  /// 解析持久化的 JSON 数组；非法/损坏值一律当空历史（不阻塞搜索）。
  static List<String> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return <String>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <String>[];
      return decoded.whereType<String>().toList();
    } on FormatException {
      return <String>[];
    }
  }

  /// 记入一条（已存在则提到最前；超上限淘汰最旧）。
  Future<void> add(SearchHistoryScope scope, String keyword) async {
    final trimmed = keyword.trim();
    if (trimmed.isEmpty) return;
    await ensureLoaded();
    final list = _cache.putIfAbsent(scope, () => <String>[]);
    list
      ..remove(trimmed)
      ..insert(0, trimmed);
    if (list.length > maxEntries) {
      list.removeRange(maxEntries, list.length);
    }
    await _persist(scope);
  }

  /// 删除一条（不存在时无操作、不写库）。
  Future<void> remove(SearchHistoryScope scope, String keyword) async {
    final list = _cache[scope];
    if (list == null || !list.remove(keyword)) return;
    await _persist(scope);
  }

  /// 清空某作用域的全部历史（已为空时无操作、不写库）。
  Future<void> clear(SearchHistoryScope scope) async {
    if ((_cache[scope] ?? const <String>[]).isEmpty) return;
    _cache[scope] = <String>[];
    await _persist(scope);
  }

  Future<void> _persist(SearchHistoryScope scope) =>
      _dao.setSetting(_keyOf(scope), jsonEncode(_cache[scope] ?? const []));
}
