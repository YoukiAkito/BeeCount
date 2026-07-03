// QA 回归测试:交易标记(excludeFromStats/excludeFromBudget)在
// WebDAV/Supabase 文件同步路径的完整传递 + 估值账户 ChangeTracker 修复。
//
// 覆盖本次 Bug 修复的 6 个文件:
//   1. transactions_json.dart — 导出/导入 exclude 字段 + 版本号 v7
//   2. data_import_service.dart — ImportTransaction.exclude + insert companion
//   3. sync_diff_service.dart — _compareTx exclude 差异 + update payload
//   4. transaction_repository.dart — TransactionUpdateBySyncIdData.exclude
//   5. local_transaction_repository.dart — updateTransactionBySyncId /
//      updateTransactionsBatchBySyncId 的 Value.absent() 语义
//   6. local_repository.dart — updateAccountValuation ChangeTracker 调用
//
// 注意:现有 test/sync/transaction_exclude_flags_apply_test.dart 已覆盖
// BeeCount Cloud 实时同步路径(entity_serializer + sync_engine_apply 的 D6
// 缺键保留语义)。本文件补齐 WebDAV/Supabase 文件同步路径的覆盖缺口。

import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:beecount/cloud/sync/change_tracker.dart';
import 'package:beecount/cloud/sync_diff_service.dart';
import 'package:beecount/cloud/transactions_json.dart';
import 'package:beecount/data/db.dart';
import 'package:beecount/data/repositories/local/local_repository.dart';
import 'package:beecount/data/repositories/transaction_repository.dart'
    show TransactionUpdateBySyncIdData;
import 'package:beecount/services/data_import_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BeeDatabase db;
  late ChangeTracker changeTracker;
  late LocalRepository repo;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = BeeDatabase.forTesting(NativeDatabase.memory());
    changeTracker = ChangeTracker(db);
    repo = LocalRepository(db, changeTracker: changeTracker);
  });

  tearDown(() async => db.close());

  Future<int> seedLedger({String name = '测试账本'}) {
    return db.into(db.ledgers).insert(
          LedgersCompanion.insert(
            name: name,
            monthStartDay: const Value(1),
            syncId: const Value('ledger-sync-1'),
          ),
        );
  }

  Future<int> seedAccount({
    String name = '现金',
    String type = 'cash',
    String syncId = 'acc-sync-1',
    double initialBalance = 0.0,
  }) {
    return db.into(db.accounts).insert(
          AccountsCompanion.insert(
            name: name,
            type: Value(type),
            currency: const Value('CNY'),
            initialBalance: Value(initialBalance),
            syncId: Value(syncId),
          ),
        );
  }

  // ================================================================
  // 1. transactions_json.dart — 导出/导入 exclude 字段 + 版本号 v7
  // ================================================================

  group('transactions_json 导出/导入 exclude 字段', () {
    test('导出 JSON 包含 excludeFromStats/excludeFromBudget 且版本号为 7', () async {
      final lid = await seedLedger();
      await repo.addTransaction(
        ledgerId: lid,
        type: 'expense',
        amount: 100,
        happenedAt: DateTime(2026, 6, 18),
        excludeFromStats: true,
        excludeFromBudget: false,
      );
      await repo.addTransaction(
        ledgerId: lid,
        type: 'income',
        amount: 200,
        happenedAt: DateTime(2026, 6, 19),
        excludeFromStats: false,
        excludeFromBudget: true,
      );

      final jsonStr = await exportTransactionsJson(db, lid);
      final data = jsonDecode(jsonStr) as Map<String, dynamic>;

      expect(data['version'], 7, reason: '版本号应升级到 7');

      final items = data['items'] as List;
      expect(items, hasLength(2));

      final expenseItem = items.firstWhere((i) => i['type'] == 'expense');
      expect(expenseItem['excludeFromStats'], true);
      expect(expenseItem['excludeFromBudget'], false);

      final incomeItem = items.firstWhere((i) => i['type'] == 'income');
      expect(incomeItem['excludeFromStats'], false);
      expect(incomeItem['excludeFromBudget'], true);
    });

    test('导入 v7 JSON → ImportTransaction 正确携带 exclude 字段', () async {
      final lid = await seedLedger();
      await repo.addTransaction(
        ledgerId: lid,
        type: 'expense',
        amount: 50,
        happenedAt: DateTime(2026, 6, 18),
        excludeFromStats: true,
        excludeFromBudget: true,
        syncId: 'tx-roundtrip-1',
      );

      final jsonStr = await exportTransactionsJson(db, lid);
      final importData = parseJsonToImportData(jsonStr);

      expect(importData.transactions, hasLength(1));
      final tx = importData.transactions.first;
      expect(tx.excludeFromStats, true);
      expect(tx.excludeFromBudget, true);
      expect(tx.syncId, 'tx-roundtrip-1');
    });

    test('导入旧版 v6 JSON(无 exclude 字段)→ exclude 解析为 null → 导入默认 false',
        () async {
      // 构造一个 v6 格式的 JSON(没有 excludeFromStats/excludeFromBudget 键)
      final v6Json = jsonEncode({
        'version': 6,
        'exportedAt': '2026-06-18T00:00:00Z',
        'ledgerId': 1,
        'ledgerName': '旧版账本',
        'currency': 'CNY',
        'count': 1,
        'accounts': [],
        'categories': [],
        'tags': [],
        'items': [
          {
            'type': 'expense',
            'amount': 99.0,
            'categoryName': null,
            'categoryKind': null,
            'happenedAt': '2026-06-18T00:00:00Z',
            'note': '旧版数据',
            'syncId': 'tx-v6-1',
          }
        ],
      });

      final importData = parseJsonToImportData(v6Json);

      expect(importData.transactions, hasLength(1));
      // 旧版 JSON 无 exclude 键 → 解析为 null
      expect(importData.transactions.first.excludeFromStats, isNull);
      expect(importData.transactions.first.excludeFromBudget, isNull);
    });

    test('导入 v6 JSON 交易 → 插入后 excludeFromStats/Budget 默认为 false', () async {
      final lid = await seedLedger();
      final v6Json = jsonEncode({
        'version': 6,
        'exportedAt': '2026-06-18T00:00:00Z',
        'ledgerId': lid,
        'ledgerName': '旧版账本',
        'currency': 'CNY',
        'count': 1,
        'accounts': [],
        'categories': [],
        'tags': [],
        'items': [
          {
            'type': 'expense',
            'amount': 99.0,
            'categoryName': null,
            'categoryKind': null,
            'happenedAt': '2026-06-18T00:00:00Z',
            'note': '旧版数据',
            'syncId': 'tx-v6-insert-1',
          }
        ],
      });

      await importTransactionsJson(repo, lid, v6Json, recordChanges: false);

      final tx = await repo.getTransactionBySyncId('tx-v6-insert-1');
      expect(tx, isNotNull);
      // null → data_import_service 用 ?? false → 数据库默认 false
      expect(tx!.excludeFromStats, false,
          reason: '旧版 JSON 无 exclude 键 → 导入后应默认 false');
      expect(tx.excludeFromBudget, false,
          reason: '旧版 JSON 无 exclude 键 → 导入后应默认 false');
    });
  });

  // ================================================================
  // 2. local_transaction_repository — Value.absent() 语义
  // ================================================================

  group('updateTransactionsBatchBySyncId exclude Value.absent 语义', () {
    test('exclude=null → Value.absent → 不覆盖现有 true 值', () async {
      final lid = await seedLedger();
      const syncId = 'tx-batch-absent-1';
      await repo.addTransaction(
        ledgerId: lid,
        type: 'expense',
        amount: 100,
        happenedAt: DateTime(2026, 6, 18),
        excludeFromStats: true,
        excludeFromBudget: true,
        syncId: syncId,
      );

      // 批量更新:改 amount,但 exclude 传 null(模拟缺键)
      await repo.updateTransactionsBatchBySyncId([
        TransactionUpdateBySyncIdData(
          syncId: syncId,
          type: 'expense',
          amount: 250,
          happenedAt: DateTime(2026, 6, 18),
          // excludeFromStats / excludeFromBudget 不传 → null
        ),
      ]);

      final tx = await repo.getTransactionBySyncId(syncId);
      expect(tx, isNotNull);
      expect(tx!.amount, 250, reason: 'amount 应被更新');
      expect(tx.excludeFromStats, true,
          reason: 'null → Value.absent → 不应覆盖现有 true');
      expect(tx.excludeFromBudget, true,
          reason: 'null → Value.absent → 不应覆盖现有 true');
    });

    test('exclude 显式传 false → 覆盖现有 true', () async {
      final lid = await seedLedger();
      const syncId = 'tx-batch-overwrite-1';
      await repo.addTransaction(
        ledgerId: lid,
        type: 'expense',
        amount: 100,
        happenedAt: DateTime(2026, 6, 18),
        excludeFromStats: true,
        excludeFromBudget: true,
        syncId: syncId,
      );

      await repo.updateTransactionsBatchBySyncId([
        TransactionUpdateBySyncIdData(
          syncId: syncId,
          type: 'expense',
          amount: 100,
          happenedAt: DateTime(2026, 6, 18),
          excludeFromStats: false,
          excludeFromBudget: false,
        ),
      ]);

      final tx = await repo.getTransactionBySyncId(syncId);
      expect(tx, isNotNull);
      expect(tx!.excludeFromStats, false, reason: '显式 false 应覆盖 true');
      expect(tx.excludeFromBudget, false, reason: '显式 false 应覆盖 true');
    });

    test('updateTransactionBySyncId 单条:exclude=null → 保留现有值', () async {
      final lid = await seedLedger();
      const syncId = 'tx-single-absent-1';
      await repo.addTransaction(
        ledgerId: lid,
        type: 'expense',
        amount: 100,
        happenedAt: DateTime(2026, 6, 18),
        excludeFromStats: true,
        excludeFromBudget: false,
        syncId: syncId,
      );

      await repo.updateTransactionBySyncId(
        syncId: syncId,
        type: 'expense',
        amount: 300,
        happenedAt: DateTime(2026, 6, 18),
        // excludeFromStats / excludeFromBudget 不传 → null
      );

      final tx = await repo.getTransactionBySyncId(syncId);
      expect(tx, isNotNull);
      expect(tx!.amount, 300);
      expect(tx.excludeFromStats, true,
          reason: 'null → Value.absent → 保留 true');
      expect(tx.excludeFromBudget, false,
          reason: 'null → Value.absent → 保留 false');
    });
  });

  // ================================================================
  // 3. sync_diff_service — _compareTx exclude 差异检测
  // ================================================================

  group('sync_diff_service exclude 差异检测', () {
    test('本地 excludeFromStats=true vs 云端 false → 检测到 modified', () async {
      final lid = await seedLedger();
      const syncId = 'tx-diff-1';
      await repo.addTransaction(
        ledgerId: lid,
        type: 'expense',
        amount: 100,
        happenedAt: DateTime(2026, 6, 18),
        excludeFromStats: true,
        excludeFromBudget: false,
        syncId: syncId,
      );

      final preview = await syncDiffService.computeDiff(
        repo: repo,
        ledgerId: lid,
        cloudTransactions: [
          ImportTransaction(
            type: 'expense',
            amount: 100,
            happenedAt: DateTime(2026, 6, 18),
            syncId: syncId,
            excludeFromStats: false,
            excludeFromBudget: false,
          ),
        ],
      );

      expect(preview, isNotNull);
      expect(preview!.modifiedCount, 1,
          reason: 'excludeFromStats 不同应检测到 modified');
      final change = preview.changes.first;
      expect(change.diffDetails.any((d) => d.contains('不计入收支')), isTrue);
    });

    test('本地与云端 exclude 完全一致 → 不检测到 modified', () async {
      final lid = await seedLedger();
      const syncId = 'tx-diff-2';
      await repo.addTransaction(
        ledgerId: lid,
        type: 'expense',
        amount: 100,
        happenedAt: DateTime(2026, 6, 18),
        excludeFromStats: true,
        excludeFromBudget: true,
        syncId: syncId,
      );

      final preview = await syncDiffService.computeDiff(
        repo: repo,
        ledgerId: lid,
        cloudTransactions: [
          ImportTransaction(
            type: 'expense',
            amount: 100,
            happenedAt: DateTime(2026, 6, 18),
            syncId: syncId,
            excludeFromStats: true,
            excludeFromBudget: true,
          ),
        ],
      );

      expect(preview, isNotNull);
      expect(preview!.modifiedCount, 0,
          reason: 'exclude 完全一致不应检测到 modified');
    });

    test('applySyncChanges 传递 exclude 字段到 batch update', () async {
      final lid = await seedLedger();
      const syncId = 'tx-apply-1';
      await repo.addTransaction(
        ledgerId: lid,
        type: 'expense',
        amount: 100,
        happenedAt: DateTime(2026, 6, 18),
        excludeFromStats: false,
        excludeFromBudget: false,
        syncId: syncId,
      );

      final result = await syncDiffService.applySyncChanges(
        repo: repo,
        ledgerId: lid,
        selectedChanges: [
          SyncChange(
            type: SyncChangeType.modified,
            cloudTransaction: ImportTransaction(
              type: 'expense',
              amount: 200,
              happenedAt: DateTime(2026, 6, 18),
              syncId: syncId,
              excludeFromStats: true,
              excludeFromBudget: true,
            ),
          ),
        ],
        importData: const ImportData(),
      );

      expect(result.modifiedCount, 1);
      final tx = await repo.getTransactionBySyncId(syncId);
      expect(tx, isNotNull);
      expect(tx!.amount, 200, reason: 'amount 应被更新');
      expect(tx.excludeFromStats, true,
          reason: 'applySyncChanges 应传递 excludeFromStats 到 batch update');
      expect(tx.excludeFromBudget, true,
          reason: 'applySyncChanges 应传递 excludeFromBudget 到 batch update');
    });
  });

  // ================================================================
  // 4. local_repository — updateAccountValuation ChangeTracker 修复
  // ================================================================

  group('updateAccountValuation ChangeTracker', () {
    test('更新估值 → 记录 account:update change 到 ChangeTracker', () async {
      final accountId = await seedAccount(
        name: '估值账户',
        type: 'investment',
        syncId: 'acc-valuation-1',
        initialBalance: 1000.0,
      );

      await repo.updateAccountValuation(accountId, 1500.0);

      // 验证 initialBalance 已更新
      final account = await repo.getAccount(accountId);
      expect(account.initialBalance, 1500.0);

      // 验证 ChangeTracker 记录了 user-global change(ledgerId=0)
      final changes = await changeTracker.getUnpushedChangesForLedger(0);
      final accChanges = changes
          .where((c) =>
              c.entityType == 'account' &&
              c.entitySyncId == 'acc-valuation-1' &&
              c.action == 'update')
          .toList();
      expect(accChanges, hasLength(1),
          reason: 'updateAccountValuation 应记录 account:update change');
    });

    test('changeTracker=null 时 → 只更新不记录、不抛错', () async {
      final repoNoTracker = LocalRepository(db);
      final accountId = await seedAccount(
        name: '无追踪器账户',
        type: 'investment',
        syncId: 'acc-no-tracker-1',
        initialBalance: 500.0,
      );

      await repoNoTracker.updateAccountValuation(accountId, 800.0);

      final account = await repoNoTracker.getAccount(accountId);
      expect(account.initialBalance, 800.0, reason: '估值应已更新');

      // ChangeTracker 没有被注入,不应有任何 change
      final changes = await changeTracker.getUnpushedChangesForLedger(0);
      expect(changes.where((c) => c.entitySyncId == 'acc-no-tracker-1'), isEmpty,
          reason: 'changeTracker=null 时不应记录任何 change');
    });

    test('账户无 syncId 时 → 更新但不记录 change', () async {
      final accountId = await db.into(db.accounts).insert(
            AccountsCompanion.insert(
              name: '无syncId账户',
              type: const Value('investment'),
              currency: const Value('CNY'),
              // syncId 不设 → null
            ),
          );

      await repo.updateAccountValuation(accountId, 2000.0);

      final account = await repo.getAccount(accountId);
      expect(account.initialBalance, 2000.0);

      // syncId 为 null → 不应记录 change
      final changes = await changeTracker.getUnpushedChangesForLedger(0);
      final accChanges = changes
          .where((c) => c.entityType == 'account' && c.action == 'update')
          .toList();
      expect(accChanges, isEmpty,
          reason: '账户无 syncId 时不应记录 change');
    });

    test('与 updateAccount 模式一致:都走 recordUserGlobalChange', () async {
      final accountId = await seedAccount(
        name: '对比账户',
        type: 'cash',
        syncId: 'acc-compare-1',
        initialBalance: 100.0,
      );

      // 先用 updateAccount 改名(会记 change)
      await repo.updateAccount(accountId, name: '改名后');
      final changesAfterUpdate = await changeTracker.getUnpushedChangesForLedger(0);
      final updateChanges = changesAfterUpdate
          .where((c) => c.entitySyncId == 'acc-compare-1')
          .toList();
      // markPushed 清掉,避免干扰
      await changeTracker.markPushed(updateChanges.map((c) => c.id).toList());

      // 再用 updateAccountValuation 改估值
      await repo.updateAccountValuation(accountId, 999.0);
      final changesAfterValuation =
          await changeTracker.getUnpushedChangesForLedger(0);
      final valuationChanges = changesAfterValuation
          .where((c) => c.entitySyncId == 'acc-compare-1')
          .toList();

      expect(valuationChanges, hasLength(1));
      // 两个方法都应产生相同结构的 change:
      // entityType=account, action=update, ledgerId=0(user-global)
      expect(valuationChanges.first.entityType, 'account');
      expect(valuationChanges.first.action, 'update');
    });
  });

  // ================================================================
  // 5. data_import_service — ImportTransaction exclude → companion
  // ================================================================

  group('data_import_service exclude 传递', () {
    test('ImportTransaction.excludeFromStats=true → 插入后保留 true', () async {
      final lid = await seedLedger();
      await dataImportService.importData(
        repo,
        lid,
        ImportData(
          transactions: [
            ImportTransaction(
              type: 'expense',
              amount: 100,
              happenedAt: DateTime(2026, 6, 18),
              syncId: 'tx-import-exclude-1',
              excludeFromStats: true,
              excludeFromBudget: false,
            ),
          ],
        ),
        recordChanges: false,
      );

      final tx = await repo.getTransactionBySyncId('tx-import-exclude-1');
      expect(tx, isNotNull);
      expect(tx!.excludeFromStats, true);
      expect(tx.excludeFromBudget, false);
    });

    test('ImportTransaction.exclude=null → 插入后默认 false', () async {
      final lid = await seedLedger();
      await dataImportService.importData(
        repo,
        lid,
        ImportData(
          transactions: [
            ImportTransaction(
              type: 'expense',
              amount: 50,
              happenedAt: DateTime(2026, 6, 18),
              syncId: 'tx-import-null-exclude-1',
              // excludeFromStats / excludeFromBudget 不传 → null
            ),
          ],
        ),
        recordChanges: false,
      );

      final tx = await repo.getTransactionBySyncId('tx-import-null-exclude-1');
      expect(tx, isNotNull);
      expect(tx!.excludeFromStats, false,
          reason: 'null → ?? false → 数据库默认 false');
      expect(tx.excludeFromBudget, false);
    });
  });
}
