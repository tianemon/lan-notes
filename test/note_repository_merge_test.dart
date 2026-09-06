// 仓库层 LWW/墓碑/防复活合并逻辑回归（评估健康性项：verify_sync 场景一
// 核心断言迁移为 test/，进入 flutter test 链路）。
//
// 覆盖（docs/技术架构.md 3.3 节 v3 修订，统一比较器）：
//   - 本地操作语义：create/update/软删/恢复 version 递增；清空写墓碑
//   - 墓碑拦截：version 更小或同 version 操作时间不更新的旧数据被拒绝
//   - 时间裁决：同 version 操作时间更新 → 复活（清空/软删两条路径）
//   - version 单调：采用远端时取 max(本地, 远端)，不 +1 不回退
//   - 仅本机保存：本地标记拒收远端内容；远端标记删除本机副本
//   - 防回声：merge* 入口不经过 changes 通道
//   - mergeRemoteDelete 防乱序：本地 version 更大时保留
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lan_notes/app/data/database.dart' show AppDatabase;
import 'package:lan_notes/app/data/note.dart';
import 'package:lan_notes/app/repository/note_repository.dart';

Note _note({
  required String id,
  String title = 't',
  int version = 0,
  int updatedAt = 100,
  int? deletedAt,
  bool localOnly = false,
}) {
  return Note(
    id: id,
    title: title,
    content: '',
    createdAt: 1,
    updatedAt: updatedAt,
    version: version,
    deletedAt: deletedAt,
    localOnly: localOnly,
  );
}

void main() {
  late AppDatabase db;
  late NoteRepository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = NoteRepository(db.noteDao);
  });

  tearDown(() async {
    await repo.dispose();
    await db.close();
  });

  test('本地操作：version 递增语义（创建/修改/软删/恢复）与清空写墓碑', () async {
    final n = await repo.createNote(title: 'x', content: '');
    expect(n.version, 0);
    expect((await repo.updateNote(id: n.id, title: 'x2', content: '')).version, 1);
    final trashed = await repo.softDeleteNote(n.id);
    expect(trashed.version, 2);
    expect(trashed.deletedAt, isNotNull);
    expect(
      (await repo.trashStream().first).any((x) => x.id == n.id),
      isTrue,
      reason: '软删除后回收站流可见',
    );
    expect((await repo.restoreNote(n.id)).version, 3);

    await repo.purgeNote(n.id);
    expect(await repo.getById(n.id), isNull);
    expect((await db.noteDao.getTombstone(n.id))?.version, 3);
  });

  test('墓碑拦截：清空后旧数据不复活（version 更小 / 同 version 时间更早）', () async {
    final n = await repo.createNote(title: 'x', content: '');
    await repo.updateNote(id: n.id, title: 'x2', content: ''); // version 1
    await repo.updateNote(id: n.id, title: 'x3', content: ''); // version 2
    final tombTime = DateTime.now().millisecondsSinceEpoch;
    await repo.purgeNote(n.id); // 墓碑 version=2，deletedAt ≈ tombTime

    // version 更小：拒绝。
    expect(
      await repo.mergeRemoteNote(
        _note(id: n.id, title: '旧备份', version: 1, updatedAt: tombTime + 1000),
      ),
      isFalse,
    );
    // version 相等但操作时间 ≤ 墓碑删除时间：拒绝（平局删除优先）。
    expect(
      await repo.mergeRemoteNote(
        _note(id: n.id, title: '同版旧数据', version: 2, updatedAt: tombTime),
      ),
      isFalse,
    );
    // version 相同但操作时间更新：时间裁决放行（离线修改复活）。
    expect(
      await repo.mergeRemoteNote(
        _note(id: n.id, title: '离线修改', version: 2, updatedAt: tombTime + 5000),
      ),
      isTrue,
    );
    expect((await repo.getById(n.id))?.title, '离线修改');
  });

  test('软删除时间裁决：同 version 对端软删时间更新 → 本地进回收站', () async {
    final n = await repo.createNote(title: 'x', content: '');
    final local = await repo.softDeleteNote(n.id);
    // 对端同 version、软删时间更新 → 对端胜。
    final remoteWins = await repo.mergeRemoteNote(
      _note(
        id: n.id,
        title: 'x',
        version: local.version,
        updatedAt: local.updatedAt,
        deletedAt: local.deletedAt! + 3000,
      ),
    );
    expect(remoteWins, isTrue);
    expect((await repo.getById(n.id))?.deletedAt, local.deletedAt! + 3000);
  });

  test('version 单调：远端胜出版本取 max(本地, 远端)，不 +1 不回退', () async {
    final n = await repo.createNote(title: 'x', content: '');
    await repo.updateNote(id: n.id, title: 'x2', content: ''); // version 1
    // 远端 version 5 胜出 → 本地 version 应为 5（不是 6）。
    await repo.mergeRemoteNote(_note(id: n.id, title: 'remote', version: 5));
    final merged = await repo.getById(n.id);
    expect(merged?.version, 5);
    // 更旧的远端（version 2）被拒绝。
    expect(
      await repo.mergeRemoteNote(_note(id: n.id, title: 'stale', version: 2)),
      isFalse,
    );
    expect((await repo.getById(n.id))?.version, 5);
  });

  test('仅本机保存：本地标记拒收远端内容；远端标记删除本机副本', () async {
    final n = await repo.createNote(title: 'x', content: '');
    await repo.updateNote(id: n.id, title: 'x2', content: '');
    await repo.setLocalOnly(n.id, true);
    expect(
      await repo.mergeRemoteNote(
        _note(id: n.id, title: '远端覆盖', version: 99),
      ),
      isFalse,
      reason: '本地仅本机保存：拒绝任何远端内容',
    );
    expect((await repo.getById(n.id))?.title, 'x2');

    // 本地未标记、远端标记：删除本机副本（不进回收站、不写墓碑）。
    final m = await repo.createNote(title: 'm', content: '');
    expect(
      await repo.mergeRemoteNote(
        _note(id: m.id, title: '', version: m.version, localOnly: true),
      ),
      isTrue,
    );
    expect(await repo.getById(m.id), isNull);
    expect(await db.noteDao.getTombstone(m.id), isNull);
  });

  test('防回声：merge* 入口不经过 changes 通道', () async {
    final events = <NoteChangeEvent>[];
    final sub = repo.changes.listen(events.add);
    final remote = _note(
      id: 'remote-1',
      title: 'r',
      version: 3,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await repo.mergeRemoteNote(remote);
    await repo.mergeRemoteDelete(id: 'remote-2', version: 1, deletedAt: 1000);
    await repo.mergeRemoteTombstone(id: 'remote-3', version: 2, deletedAt: 1000);
    await Future<void>.delayed(Duration.zero);
    expect(events, isEmpty, reason: '远端合并不得再触发推送（防回声约定）');
    await sub.cancel();
  });

  test('mergeRemoteDelete 防乱序：本地 version 更大时保留本地', () async {
    final n = await repo.createNote(title: 'x', content: '');
    final updated = await repo.updateNote(id: n.id, title: 'x2', content: '');
    // 旧删除消息（version 0 < 本地 1）：拒绝，本地保留。
    expect(
      await repo.mergeRemoteDelete(id: n.id, version: 0, deletedAt: 1),
      isFalse,
    );
    expect(await repo.getById(n.id), isNotNull);
    // 新删除消息（version ≥ 本地）：执行删除并写墓碑。
    expect(
      await repo.mergeRemoteDelete(
        id: n.id,
        version: updated.version,
        deletedAt: DateTime.now().millisecondsSinceEpoch,
      ),
      isTrue,
    );
    expect(await repo.getById(n.id), isNull);
    expect((await db.noteDao.getTombstone(n.id))?.version, updated.version);
  });
}
