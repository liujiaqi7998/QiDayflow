// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import '../../core/domain/domain.dart';
import 'chunk_evidence.dart';

final class CacheRotationResult {
  const CacheRotationResult({
    required this.initialBytes,
    required this.finalBytes,
    required this.limitBytes,
    required this.purgedChunkIds,
    required this.skippedChunkIds,
    required this.messages,
  });

  final int initialBytes;
  final int finalBytes;
  final int limitBytes;
  final List<int> purgedChunkIds;
  final List<int> skippedChunkIds;
  final List<String> messages;

  bool get limitReached => initialBytes >= limitBytes;
  bool get unableToReachLimit => finalBytes >= limitBytes;
}

final class CompletedVideoClearResult {
  const CompletedVideoClearResult({
    required this.initialBytes,
    required this.finalBytes,
    required this.deletedChunkIds,
    required this.skippedChunkIds,
    required this.messages,
  });

  final int initialBytes;
  final int finalBytes;
  final List<int> deletedChunkIds;
  final List<int> skippedChunkIds;
  final List<String> messages;
}

final class CacheRotationService {
  CacheRotationService({
    required CaptureRepository captureRepository,
    required EvidenceStore evidenceStore,
    Clock clock = const SystemClock(),
  }) : _captureRepository = captureRepository,
       _evidenceStore = evidenceStore,
       _clock = clock;

  final CaptureRepository _captureRepository;
  final EvidenceStore _evidenceStore;
  final Clock _clock;
  Future<void> _tail = Future<void>.value();

  Future<CacheRotationResult> rotate({
    required String captureDirectory,
    required int limitBytes,
  }) {
    if (limitBytes <= 0) {
      throw ArgumentError.value(limitBytes, 'limitBytes', 'must be positive');
    }
    final operation = _tail.then(
      (_) =>
          _rotate(captureDirectory: captureDirectory, limitBytes: limitBytes),
    );
    _tail = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return operation;
  }

  Future<CompletedVideoClearResult> clearCompletedVideos({
    required String captureDirectory,
  }) {
    final operation = _tail.then(
      (_) => _clearCompletedVideos(captureDirectory: captureDirectory),
    );
    _tail = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return operation;
  }

  Future<CompletedVideoClearResult> _clearCompletedVideos({
    required String captureDirectory,
  }) async {
    final initialBytes = await _evidenceStore.sizeOf(captureDirectory);
    final deletedIds = <int>[];
    final skippedIds = <int>[];
    final messages = <String>[];
    final candidates =
        (await _captureRepository.listChunks(
            statuses: const <ProcessingStatus>{ProcessingStatus.completed},
            evidencePurged: false,
            limit: 1000000,
          )).where((chunk) => chunk.videoPath != null).toList()
          ..sort(_oldestEvidenceFirst);

    for (final chunk in candidates) {
      final chunkId = chunk.id;
      if (chunkId == null) {
        messages.add('跳过没有数据库 ID 的已分析视频切片');
        continue;
      }
      final deletion = await _evidenceStore.deleteEvidenceGroup(
        chunk: chunk,
        allowedCaptureRoot: captureDirectory,
      );
      if (!deletion.deleted) {
        skippedIds.add(chunkId);
        messages.add('切片 $chunkId：${deletion.message ?? '视频和 JSON 删除失败'}');
        continue;
      }
      final marked = await _captureRepository.markChunkEvidencePurged(
        chunkId,
        purgedAtMs: _clock.nowUtcEpochMs(),
      );
      if (!marked) {
        skippedIds.add(chunkId);
        messages.add('切片 $chunkId：文件已删除，但数据库清理标记写入失败，可重试修复');
      } else {
        deletedIds.add(chunkId);
      }
    }

    return CompletedVideoClearResult(
      initialBytes: initialBytes,
      finalBytes: await _evidenceStore.sizeOf(captureDirectory),
      deletedChunkIds: List<int>.unmodifiable(deletedIds),
      skippedChunkIds: List<int>.unmodifiable(skippedIds),
      messages: List<String>.unmodifiable(messages),
    );
  }

  Future<CacheRotationResult> _rotate({
    required String captureDirectory,
    required int limitBytes,
  }) async {
    final initialBytes = await _evidenceStore.sizeOf(captureDirectory);
    var currentBytes = initialBytes;
    final purgedIds = <int>[];
    final skippedIds = <int>[];
    final messages = <String>[];

    if (currentBytes >= limitBytes) {
      final candidates = await _captureRepository.listChunks(
        statuses: const <ProcessingStatus>{ProcessingStatus.completed},
        evidencePurged: false,
        limit: 1000000,
      );
      candidates.sort(_oldestEvidenceFirst);

      for (final chunk in candidates) {
        if (currentBytes < limitBytes) {
          break;
        }
        final chunkId = chunk.id;
        if (chunkId == null) {
          messages.add('跳过没有数据库 ID 的已分析切片');
          continue;
        }
        final deletion = await _evidenceStore.deleteEvidenceGroup(
          chunk: chunk,
          allowedCaptureRoot: captureDirectory,
        );
        if (!deletion.deleted) {
          skippedIds.add(chunkId);
          messages.add('切片 $chunkId：${deletion.message ?? '证据删除失败'}');
          continue;
        }
        final marked = await _captureRepository.markChunkEvidencePurged(
          chunkId,
          purgedAtMs: _clock.nowUtcEpochMs(),
        );
        if (!marked) {
          skippedIds.add(chunkId);
          messages.add('切片 $chunkId：证据已删除，但数据库清理标记写入失败');
        } else {
          purgedIds.add(chunkId);
        }
        currentBytes = await _evidenceStore.sizeOf(captureDirectory);
      }
    }

    if (currentBytes >= limitBytes) {
      messages.add('未分析或分析失败的证据受保护，缓存暂时无法降到设置上限以下');
    }
    return CacheRotationResult(
      initialBytes: initialBytes,
      finalBytes: currentBytes,
      limitBytes: limitBytes,
      purgedChunkIds: List<int>.unmodifiable(purgedIds),
      skippedChunkIds: List<int>.unmodifiable(skippedIds),
      messages: List<String>.unmodifiable(messages),
    );
  }

  static int _oldestEvidenceFirst(CaptureChunk left, CaptureChunk right) {
    var comparison = left.endedAtMs.compareTo(right.endedAtMs);
    if (comparison != 0) {
      return comparison;
    }
    comparison = (left.completedAtMs ?? left.createdAtMs).compareTo(
      right.completedAtMs ?? right.createdAtMs,
    );
    if (comparison != 0) {
      return comparison;
    }
    return left.createdAtMs.compareTo(right.createdAtMs);
  }
}
