@TestOn('vm')
library;

import 'dart:io';

import 'package:hive_ce/hive_ce.dart';
import 'package:hive_ce/src/hive_impl.dart';
import 'package:test/test.dart';

import '../tests/common.dart';

/// A failed [Box.compact] must not disable compaction for the rest of the time
/// the box is open.
///
/// `StorageBackendVm.compact` used to set its in-progress flag before doing
/// any work and clear it only after the temporary file was renamed into
/// place. A throw before that left the flag set, and every later `compact()`
/// returned without rewriting the file.
void main() {
  group('compaction retries after a failure', () {
    late HiveImpl hive;
    late Box<String> box;

    setUp(() async {
      final dir = await getTempDir();
      hive = HiveImpl()..init(dir.path);
      addTearDown(hive.close);
      box = await hive.openBox<String>('box');
      await box.put('kept', 'alive');
    });

    test('temporary file cannot be opened', () async {
      final bloated = await _bloat(box);
      final blocker = Directory(_compactPath(box));
      await blocker.create();
      addTearDown(() async {
        if (await blocker.exists()) {
          await blocker.delete(recursive: true);
        }
      });

      await expectLater(box.compact(), throwsA(isA<FileSystemException>()));

      // The directory is still in the way, so a real retry fails the same
      // way. A stuck in-progress flag returns success and never opens it.
      await expectLater(box.compact(), throwsA(isA<FileSystemException>()));

      await blocker.delete(recursive: true);
      await _expectRetryShrinks(box, bloated);
    });

    test('box file ends before a live frame', () async {
      final bloated = await _bloat(box);
      final boxFile = File(_filePath(box));
      final original = await boxFile.readAsBytes();
      await _truncate(boxFile);

      await expectLater(
        box.compact(),
        throwsHiveError(['unexpected eof']),
      );

      // The file is still truncated, so a real retry throws again.
      await expectLater(
        box.compact(),
        throwsHiveError(['unexpected eof']),
      );

      await boxFile.writeAsBytes(original);
      await _expectRetryShrinks(box, bloated);
    });
  });
}

Future<int> _bloat(Box<String> box) async {
  final value = 'x' * 4000;
  for (var i = 0; i < 30; i++) {
    await box.put('tmp$i', value);
  }
  for (var i = 0; i < 30; i++) {
    await box.delete('tmp$i');
  }
  return File(_filePath(box)).length();
}

Future<void> _truncate(File file) async {
  final raf = await file.open(mode: FileMode.writeOnly);
  await raf.truncate(0);
  await raf.close();
}

String _filePath(Box<String> box) => expectNotNull(box.path);

String _compactPath(Box<String> box) {
  final path = _filePath(box);
  return '${path.substring(0, path.length - 5)}.hivec';
}

Future<void> _expectRetryShrinks(Box<String> box, int bloated) async {
  await box.put('after-failure', 'still-open');
  expect(box.get('kept'), 'alive');

  await box.compact();

  expect(box.get('kept'), 'alive');
  expect(box.get('after-failure'), 'still-open');
  expect(
    await File(_filePath(box)).length(),
    lessThan(bloated ~/ 2),
    reason: 'Compaction did not rewrite the box after the earlier failure.',
  );
}
