import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/domain/domain.dart';
import '../native/capture_video_spec.dart';
import '../native/native_capture_service.dart';
import '../openai/analysis_models.dart';

bool isSupportedVideoMetadataScope({
  required Object? schemaVersion,
  required Object? captureScope,
}) =>
    (schemaVersion == 2 && captureScope == 'all-displays') ||
    ((schemaVersion == 3 || schemaVersion == 4) &&
        captureScope == activeWindowDisplayCaptureScope);

class ChunkEvidence {
  const ChunkEvidence({
    required this.keyFrames,
    required this.windowContexts,
    required this.resourceSamples,
  });

  final List<AnalysisKeyFrame> keyFrames;
  final List<WindowContextSegment> windowContexts;
  final List<WindowResourceSample> resourceSamples;
}

final class WindowResourceSample {
  const WindowResourceSample({
    required this.timestampMs,
    required this.offsetSeconds,
    required this.processId,
    required this.processName,
    required this.friendlyAppName,
    required this.executablePath,
    required this.cpuUsagePercent,
    required this.memoryCommitBytes,
  });

  final int timestampMs;
  final double offsetSeconds;
  final int processId;
  final String processName;
  final String friendlyAppName;
  final String? executablePath;
  final double? cpuUsagePercent;
  final int? memoryCommitBytes;
}

class ChunkEvidenceReader {
  const ChunkEvidenceReader({this.nativeService});

  final NativeCaptureService? nativeService;

  Future<ChunkEvidence> read(CaptureChunk chunk) async {
    final directory = p.normalize(p.absolute(chunk.framesDirectory));
    final metadataPath = p.normalize(p.absolute(chunk.metadataPath));
    if (!p.isWithin(directory, metadataPath)) {
      throw const FormatException('切片元数据不在证据目录内');
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(await File(metadataPath).readAsString());
    } on Object catch (error) {
      throw FormatException('无法读取切片元数据：$error');
    }
    if (decoded is! Map) {
      throw const FormatException('切片元数据根节点必须是对象');
    }
    final json = Map<String, Object?>.from(decoded);
    if (json['startTimeMs'] != chunk.startedAtMs ||
        json['endTimeMs'] != chunk.endedAtMs) {
      throw const FormatException('切片元数据时间范围与数据库不一致');
    }
    final durationMs = chunk.endedAtMs - chunk.startedAtMs;
    final windows = _readWindowEvidence(json, durationMs);

    if (chunk.videoPath != null) {
      return _readVideoEvidence(
        chunk: chunk,
        json: json,
        directory: directory,
        durationMs: durationMs,
        windows: windows,
      );
    }
    return _readLegacyJpegEvidence(
      chunk: chunk,
      json: json,
      directory: directory,
      durationMs: durationMs,
      windows: windows,
    );
  }

  Future<ChunkEvidence> _readVideoEvidence({
    required CaptureChunk chunk,
    required Map<String, Object?> json,
    required String directory,
    required int durationMs,
    required _WindowEvidence windows,
  }) async {
    if (!isSupportedVideoMetadataScope(
      schemaVersion: json['schemaVersion'],
      captureScope: json['captureScope'],
    )) {
      throw const FormatException('MP4 切片元数据版本或采集范围无效');
    }
    final rawVideo = json['video'];
    if (rawVideo is! Map) {
      throw const FormatException('MP4 切片缺少 video 元数据');
    }
    final video = Map<String, Object?>.from(rawVideo);
    final normalizedVideoPath = p.normalize(p.absolute(chunk.videoPath!));
    final normalizedMetadataPath = p.normalize(p.absolute(chunk.metadataPath));
    final flatMetadataPair =
        p.basename(normalizedMetadataPath).toLowerCase() != 'metadata.json';
    if (!p.isWithin(directory, normalizedVideoPath) ||
        p.extension(normalizedVideoPath).toLowerCase() != '.mp4' ||
        !p.basename(normalizedVideoPath).toLowerCase().startsWith('chunk_') ||
        (flatMetadataPair &&
            p.basenameWithoutExtension(normalizedVideoPath).toLowerCase() !=
                p
                    .basenameWithoutExtension(normalizedMetadataPath)
                    .toLowerCase())) {
      throw const FormatException('MP4 路径不在切片目录内');
    }
    final metadataVideoPath = video['path'];
    if (metadataVideoPath is! String ||
        p.normalize(p.absolute(metadataVideoPath)) != normalizedVideoPath ||
        video['frameCount'] != chunk.frameCount ||
        video['codec'] != 'h264' ||
        video['container'] != 'mp4') {
      throw const FormatException('MP4 元数据与数据库不一致');
    }
    if (json['schemaVersion'] == 3 || json['schemaVersion'] == 4) {
      _validateActiveDisplayMetadata(json, video, durationMs);
    }
    if (!await File(normalizedVideoPath).exists()) {
      throw FormatException('MP4 切片不存在：$normalizedVideoPath');
    }
    final platform = nativeService;
    if (platform == null) {
      throw StateError('MP4 证据读取需要原生抽帧服务');
    }
    final frames = await platform.extractVideoFrames(
      videoPath: normalizedVideoPath,
      captureRoot: directory,
      expectedFrameCount: chunk.frameCount,
    );
    if (frames.any((frame) => frame.offsetMs > durationMs)) {
      throw const FormatException('原生抽帧偏移超出切片范围');
    }
    return ChunkEvidence(
      keyFrames: List<AnalysisKeyFrame>.unmodifiable(
        frames.map(
          (frame) => AnalysisKeyFrame.memory(
            offsetSeconds: frame.offsetMs / 1000,
            jpegBytes: frame.jpegBytes,
          ),
        ),
      ),
      windowContexts: List<WindowContextSegment>.unmodifiable(windows.contexts),
      resourceSamples: List<WindowResourceSample>.unmodifiable(
        windows.resourceSamples,
      ),
    );
  }

  void _validateActiveDisplayMetadata(
    Map<String, Object?> json,
    Map<String, Object?> video,
    int durationMs,
  ) {
    final schemaVersion = json['schemaVersion'];
    final chunkStartTimeMs = json['startTimeMs'];
    final chunkEndTimeMs = json['endTimeMs'];
    if (chunkStartTimeMs is! int ||
        chunkEndTimeMs is! int ||
        chunkEndTimeMs <= chunkStartTimeMs ||
        chunkEndTimeMs - chunkStartTimeMs != durationMs ||
        durationMs < 1 ||
        durationMs > 60000) {
      throw FormatException('schema $schemaVersion 切片时长无效');
    }
    final declaredDurationMs = json['durationMs'];
    if ((schemaVersion == 4 && declaredDurationMs is! int) ||
        (declaredDurationMs != null && declaredDurationMs != durationMs)) {
      throw FormatException('schema $schemaVersion durationMs 与时间范围不一致');
    }
    final frameCount = video['frameCount'];
    if (frameCount is! int ||
        frameCount < 1 ||
        video['width'] != captureVideoWidth ||
        video['height'] != captureVideoHeight) {
      throw FormatException('schema $schemaVersion 视频规格无效');
    }
    if (schemaVersion == 3) {
      final fps = video['fps'];
      if (fps is! num ||
          fps.toDouble() != captureFramesPerSecond.toDouble() ||
          frameCount > (durationMs + 999) ~/ 1000) {
        throw const FormatException('schema 3 视频规格无效');
      }
    } else {
      final captureIntervalSeconds = json['captureIntervalSeconds'];
      if (captureIntervalSeconds is! int ||
          !const <int>{1, 10, 20, 30}.contains(captureIntervalSeconds) ||
          json['durationMs'] != durationMs ||
          video['frameRateNumerator'] != 1 ||
          video['frameRateDenominator'] != captureIntervalSeconds ||
          video['frameDurationTicks'] != captureIntervalSeconds * 10000000 ||
          frameCount >
              calculateMaximumChunkFrameCount(
                durationMs: durationMs,
                captureIntervalSeconds: captureIntervalSeconds,
              )) {
        throw const FormatException('schema 4 视频规格无效');
      }
    }

    final rawDisplays = json['displays'];
    final rawBounds = json['virtualDesktop'];
    if (rawDisplays is! List || rawDisplays.isEmpty || rawBounds is! Map) {
      throw const FormatException('schema 3 必须描述至少一个源显示器');
    }
    final virtualBounds = _metadataBounds(
      Map<String, Object?>.from(rawBounds),
      'schema 3 首源边界无效',
    );
    final displays = <Map<String, Object?>>[];
    final displayIds = <String>{};
    final displaySources =
        <({String id, int left, int top, int width, int height})>{};
    for (final rawDisplay in rawDisplays) {
      if (rawDisplay is! Map) {
        throw const FormatException('schema 3 源显示器元数据无效');
      }
      final display = Map<String, Object?>.from(rawDisplay);
      final bounds = _metadataBounds(display, 'schema 3 源显示器尺寸无效');
      final rawId = display['id'];
      if (rawDisplays.length > 1 &&
          (rawId is! String || rawId.trim().isEmpty)) {
        throw const FormatException('schema 3 多源显示器必须包含 id');
      }
      if (rawId is String && rawId.trim().isNotEmpty) {
        final id = rawId.trim();
        displayIds.add(id);
        if (!displaySources.add((
          id: id,
          left: bounds.left,
          top: bounds.top,
          width: bounds.width,
          height: bounds.height,
        ))) {
          throw const FormatException('schema 3 displays 不得包含重复源');
        }
      }
      displays.add(display);
    }

    final rawSourceChanges = json['sourceChanges'];
    if (rawSourceChanges != null && rawSourceChanges is! List) {
      throw const FormatException('schema 3 sourceChanges 必须是数组');
    }
    final sourceChanges = rawSourceChanges is List
        ? List<Object?>.from(rawSourceChanges)
        : const <Object?>[];
    if (sourceChanges.isEmpty) {
      if (displays.length != 1) {
        throw const FormatException('schema 3 多源显示器必须包含 sourceChanges');
      }
      final displayBounds = _metadataBounds(
        displays.single,
        'schema 3 源显示器尺寸无效',
      );
      if (virtualBounds != displayBounds) {
        throw const FormatException('schema 3 单源显示器边界不一致');
      }
      return;
    }

    if (displaySources.length != displays.length) {
      throw const FormatException('schema 3 sourceChanges 需要稳定的显示器 id');
    }
    final startTimeMs = json['startTimeMs'];
    if (startTimeMs is! int) {
      throw const FormatException('schema 3 startTimeMs 必须是整数');
    }
    final changedDisplaySources =
        <({String id, int left, int top, int width, int height})>{};
    var previousOffset = -1;
    for (var index = 0; index < sourceChanges.length; index++) {
      final rawChange = sourceChanges[index];
      if (rawChange is! Map) {
        throw const FormatException('schema 3 source change 元数据无效');
      }
      final change = Map<String, Object?>.from(rawChange);
      final timestampMs = change['timestampMs'];
      final offsetMs = change['offsetMs'];
      final displayId = change['displayId'];
      if (timestampMs is! int ||
          offsetMs is! int ||
          offsetMs < 0 ||
          offsetMs > durationMs ||
          offsetMs <= previousOffset ||
          timestampMs != startTimeMs + offsetMs) {
        throw const FormatException('schema 3 source change 时间无效');
      }
      if (displayId is! String || !displayIds.contains(displayId.trim())) {
        throw const FormatException('schema 3 source change 引用了未知显示器');
      }
      final changeBounds = _metadataBounds(
        change,
        'schema 3 source change 边界无效',
      );
      final source = (
        id: displayId.trim(),
        left: changeBounds.left,
        top: changeBounds.top,
        width: changeBounds.width,
        height: changeBounds.height,
      );
      if (!displaySources.contains(source)) {
        throw const FormatException('schema 3 source change 边界未出现在 displays');
      }
      if (index == 0 && changeBounds != virtualBounds) {
        throw const FormatException('schema 3 virtualDesktop 必须对应首源');
      }
      previousOffset = offsetMs;
      changedDisplaySources.add(source);
    }
    if (!changedDisplaySources.containsAll(displaySources)) {
      throw const FormatException('schema 3 displays 包含未实际采集的显示器');
    }
  }

  ({int left, int top, int width, int height}) _metadataBounds(
    Map<String, Object?> value,
    String errorMessage,
  ) {
    final left = value['left'];
    final top = value['top'];
    final width = value['width'];
    final height = value['height'];
    if (left is! int ||
        top is! int ||
        width is! int ||
        height is! int ||
        width <= 0 ||
        height <= 0) {
      throw FormatException(errorMessage);
    }
    return (left: left, top: top, width: width, height: height);
  }

  Future<ChunkEvidence> _readLegacyJpegEvidence({
    required CaptureChunk chunk,
    required Map<String, Object?> json,
    required String directory,
    required int durationMs,
    required _WindowEvidence windows,
  }) async {
    if (json['schemaVersion'] != 1) {
      throw const FormatException('旧 JPEG 切片元数据版本无效');
    }
    final rawFrames = json['keyframes'];
    if (rawFrames is! List || rawFrames.isEmpty) {
      throw const FormatException('旧 JPEG 切片没有关键帧');
    }
    final frames = <({int offsetMs, String path})>[];
    for (final raw in rawFrames) {
      if (raw is! Map) {
        throw const FormatException('关键帧记录必须是对象');
      }
      final item = Map<String, Object?>.from(raw);
      final offset = item['offsetMs'];
      final path = item['path'];
      if (offset is! int || offset < 0 || offset > durationMs) {
        throw const FormatException('关键帧偏移超出切片范围');
      }
      if (path is! String || path.trim().isEmpty) {
        throw const FormatException('关键帧路径无效');
      }
      final normalized = p.normalize(p.absolute(path));
      if (!p.isWithin(directory, normalized) ||
          !const <String>{
            '.jpg',
            '.jpeg',
          }.contains(p.extension(normalized).toLowerCase())) {
        throw const FormatException('关键帧路径不在切片目录内');
      }
      if (!await File(normalized).exists()) {
        throw FormatException('关键帧不存在：$normalized');
      }
      frames.add((offsetMs: offset, path: normalized));
    }
    frames.sort((left, right) => left.offsetMs.compareTo(right.offsetMs));
    for (var index = 1; index < frames.length; index++) {
      if (frames[index].offsetMs <= frames[index - 1].offsetMs) {
        throw const FormatException('关键帧偏移必须严格递增');
      }
    }
    if (frames.length != chunk.frameCount) {
      throw const FormatException('旧 JPEG 关键帧数量与数据库不一致');
    }
    return ChunkEvidence(
      keyFrames: List<AnalysisKeyFrame>.unmodifiable(
        frames.map(
          (frame) => AnalysisKeyFrame.file(
            offsetSeconds: frame.offsetMs / 1000,
            path: frame.path,
          ),
        ),
      ),
      windowContexts: List<WindowContextSegment>.unmodifiable(windows.contexts),
      resourceSamples: List<WindowResourceSample>.unmodifiable(
        windows.resourceSamples,
      ),
    );
  }

  _WindowEvidence _readWindowEvidence(
    Map<String, Object?> json,
    int durationMs,
  ) {
    final startTimeMs = json['startTimeMs'];
    if (startTimeMs is! int || startTimeMs < 0) {
      throw const FormatException('窗口记录缺少有效的切片开始时间');
    }
    final records =
        <
          ({
            int timestampMs,
            int offsetMs,
            int processId,
            String process,
            String app,
            String title,
            String? executablePath,
            double? cpuUsagePercent,
            int? memoryCommitBytes,
          })
        >[];
    final rawWindows = json['windowRecords'];
    if (rawWindows is List) {
      for (final raw in rawWindows) {
        if (raw is! Map) {
          throw const FormatException('窗口记录必须是对象');
        }
        final item = Map<String, Object?>.from(raw);
        final offset = item['offsetMs'];
        final process = item['processName'];
        final app = item['appName'];
        final title = item['windowTitle'];
        if (offset is! int || offset < 0 || offset > durationMs) {
          throw const FormatException('窗口记录偏移超出切片范围');
        }
        if (process is! String || app is! String || title is! String) {
          throw const FormatException('窗口记录字段类型无效');
        }
        final expectedTimestampMs = startTimeMs + offset;
        final rawTimestampMs = item['timestampMs'] ?? item['timestamp_ms'];
        final timestampMs = rawTimestampMs ?? expectedTimestampMs;
        final rawProcessId = item['processId'] ?? item['process_id'] ?? 0;
        if (timestampMs is! int || timestampMs != expectedTimestampMs) {
          throw const FormatException('窗口记录 timestampMs 与 offsetMs 不一致');
        }
        if (rawProcessId is! int || rawProcessId < 0) {
          throw const FormatException('窗口记录 processId 必须是非负整数');
        }
        records.add((
          timestampMs: timestampMs,
          offsetMs: offset,
          processId: rawProcessId,
          process: process.trim(),
          app: app.trim().isEmpty ? process.trim() : app.trim(),
          title: title.trim(),
          executablePath: _trustedExecutablePath(item['processPath']),
          cpuUsagePercent: _metadataCpuUsage(
            item.containsKey('cpuUsagePercent')
                ? item['cpuUsagePercent']
                : item['cpu_usage_percent'],
          ),
          memoryCommitBytes: _metadataMemoryCommit(
            item.containsKey('memoryCommitBytes')
                ? item['memoryCommitBytes']
                : item['memory_commit_bytes'],
          ),
        ));
      }
    }
    records.sort((left, right) => left.offsetMs.compareTo(right.offsetMs));
    final resourceSamples = records
        .where((record) => record.app.isNotEmpty)
        .map(
          (record) => WindowResourceSample(
            timestampMs: record.timestampMs,
            offsetSeconds: record.offsetMs / 1000,
            processId: record.processId,
            processName: record.process,
            friendlyAppName: record.app,
            executablePath: record.executablePath,
            cpuUsagePercent: record.cpuUsagePercent,
            memoryCommitBytes: record.memoryCommitBytes,
          ),
        )
        .toList(growable: false);
    final contexts = <WindowContextSegment>[];
    var index = 0;
    while (index < records.length) {
      final record = records[index];
      var nextIndex = index + 1;
      while (nextIndex < records.length) {
        final next = records[nextIndex];
        if (next.process != record.process ||
            next.app != record.app ||
            next.title != record.title ||
            next.executablePath != record.executablePath) {
          break;
        }
        nextIndex++;
      }
      final endOffset = nextIndex < records.length
          ? records[nextIndex].offsetMs
          : durationMs;
      if (endOffset <= record.offsetMs || record.app.isEmpty) {
        index = nextIndex;
        continue;
      }
      contexts.add(
        WindowContextSegment(
          startSeconds: record.offsetMs / 1000,
          endSeconds: endOffset / 1000,
          processName: record.process,
          friendlyAppName: record.app,
          windowTitle: record.title,
          executablePath: record.executablePath,
        ),
      );
      index = nextIndex;
    }
    return _WindowEvidence(
      contexts: contexts,
      resourceSamples: resourceSamples,
    );
  }

  double? _metadataCpuUsage(Object? value) {
    if (value == null) return null;
    if (value is! num || !value.isFinite || value < 0 || value > 100) {
      throw const FormatException('窗口 CPU 使用率必须是 0 到 100 的有限数字或 null');
    }
    return value.toDouble();
  }

  int? _metadataMemoryCommit(Object? value) {
    if (value == null) return null;
    if (value is! int || value < 0) {
      throw const FormatException('窗口内存提交必须是非负整数或 null');
    }
    return value;
  }

  String? _trustedExecutablePath(Object? value) {
    if (value is! String || value.trim().isEmpty) return null;
    final candidate = value.trim();
    if (!p.isAbsolute(candidate) ||
        !const <String>{
          '.exe',
          '.com',
        }.contains(p.extension(candidate).toLowerCase())) {
      return null;
    }
    try {
      final resolved = File(candidate).resolveSymbolicLinksSync();
      if (!p.isAbsolute(resolved) ||
          FileSystemEntity.typeSync(resolved, followLinks: true) !=
              FileSystemEntityType.file) {
        return null;
      }
      return p.normalize(resolved);
    } on FileSystemException {
      return null;
    }
  }
}

final class _WindowEvidence {
  const _WindowEvidence({
    required this.contexts,
    required this.resourceSamples,
  });

  final List<WindowContextSegment> contexts;
  final List<WindowResourceSample> resourceSamples;
}

class EvidenceStore {
  const EvidenceStore({this.nativeService});

  final NativeCaptureService? nativeService;

  Future<EvidenceDeletionResult> deleteEvidenceGroup({
    required CaptureChunk chunk,
    required String allowedCaptureRoot,
  }) async {
    try {
      final group = await _artifactGroup(
        chunk: chunk,
        allowedCaptureRoot: allowedCaptureRoot,
      );
      if (group == null) {
        return const EvidenceDeletionResult.invalid('证据路径或配对关系未通过校验');
      }

      final platform = nativeService;
      if (platform != null) {
        final deleted = await platform.deleteChunkArtifacts(
          captureRoot: group.root,
          directoryPath: group.directory,
          metadataPath: group.metadataPath,
          videoPath: group.videoPath,
          framePaths: group.framePaths,
        );
        return deleted
            ? const EvidenceDeletionResult.deleted()
            : const EvidenceDeletionResult.failed('原生删除服务拒绝了证据组');
      }

      for (final path in group.artifactPaths) {
        final type = await FileSystemEntity.type(path, followLinks: false);
        if (type == FileSystemEntityType.notFound) {
          continue;
        }
        if (type != FileSystemEntityType.file) {
          return EvidenceDeletionResult.invalid('证据不是常规文件：$path');
        }
        await File(path).delete();
      }
      if (!group.flatLayout) {
        final directory = Directory(group.directory);
        if (await directory.exists() && await directory.list().isEmpty) {
          await directory.delete();
        }
      }
      return const EvidenceDeletionResult.deleted();
    } on FileSystemException catch (error) {
      return EvidenceDeletionResult.failed(error.message);
    } on FormatException catch (error) {
      return EvidenceDeletionResult.invalid(error.message);
    } on Object catch (error) {
      return EvidenceDeletionResult.failed(error.toString());
    }
  }

  Future<_EvidenceArtifactGroup?> _artifactGroup({
    required CaptureChunk chunk,
    required String allowedCaptureRoot,
  }) async {
    final root = p.normalize(p.absolute(allowedCaptureRoot));
    final rootDirectory = Directory(root);
    if (!await rootDirectory.exists()) {
      return null;
    }
    final resolvedRoot = p.normalize(
      await rootDirectory.resolveSymbolicLinks(),
    );
    final directory = p.normalize(p.absolute(chunk.framesDirectory));
    final flatLayout = p.equals(root, directory);
    if (!flatLayout && !p.isWithin(root, directory)) {
      return null;
    }
    if (!await _existingDirectoryIsWithin(directory, resolvedRoot)) {
      return null;
    }

    final metadataPath = p.normalize(p.absolute(chunk.metadataPath));
    if (!_artifactIsWithin(
          path: metadataPath,
          root: root,
          directory: directory,
          flatLayout: flatLayout,
        ) ||
        p.extension(metadataPath).toLowerCase() != '.json') {
      return null;
    }

    final videoValue = chunk.videoPath;
    if (videoValue != null) {
      final videoPath = p.normalize(p.absolute(videoValue));
      if (!_artifactIsWithin(
            path: videoPath,
            root: root,
            directory: directory,
            flatLayout: flatLayout,
          ) ||
          p.extension(videoPath).toLowerCase() != '.mp4' ||
          !p.basename(videoPath).toLowerCase().startsWith('chunk_')) {
        return null;
      }
      if (flatLayout &&
          p.basenameWithoutExtension(videoPath).toLowerCase() !=
              p.basenameWithoutExtension(metadataPath).toLowerCase()) {
        return null;
      }
      if (!await _existingFileIsWithin(videoPath, resolvedRoot) ||
          !await _existingFileIsWithin(metadataPath, resolvedRoot)) {
        return null;
      }
      return _EvidenceArtifactGroup(
        root: root,
        directory: directory,
        metadataPath: metadataPath,
        videoPath: videoPath,
        framePaths: const <String>[],
        flatLayout: flatLayout,
      );
    }

    if (flatLayout) {
      return null;
    }
    final metadataFile = File(metadataPath);
    if (!await metadataFile.exists()) {
      if (!await Directory(directory).exists()) {
        return _EvidenceArtifactGroup(
          root: root,
          directory: directory,
          metadataPath: metadataPath,
          framePaths: const <String>[],
          flatLayout: false,
        );
      }
      return null;
    }
    if (!await _existingFileIsWithin(metadataPath, resolvedRoot)) {
      return null;
    }
    final decoded = jsonDecode(await metadataFile.readAsString());
    if (decoded is! Map || decoded['schemaVersion'] != 1) {
      return null;
    }
    final rawFrames = decoded['keyframes'];
    if (rawFrames is! List) {
      return null;
    }
    final framePaths = <String>[];
    for (final rawFrame in rawFrames) {
      if (rawFrame is! Map || rawFrame['path'] is! String) {
        return null;
      }
      final framePath = p.normalize(p.absolute(rawFrame['path']! as String));
      final extension = p.extension(framePath).toLowerCase();
      if (!_artifactIsWithin(
            path: framePath,
            root: root,
            directory: directory,
            flatLayout: false,
          ) ||
          (extension != '.jpg' && extension != '.jpeg') ||
          !await _existingFileIsWithin(framePath, resolvedRoot)) {
        return null;
      }
      framePaths.add(framePath);
    }
    return _EvidenceArtifactGroup(
      root: root,
      directory: directory,
      metadataPath: metadataPath,
      framePaths: List<String>.unmodifiable(framePaths),
      flatLayout: false,
    );
  }

  bool _artifactIsWithin({
    required String path,
    required String root,
    required String directory,
    required bool flatLayout,
  }) {
    if (!p.isWithin(root, path) || !p.isWithin(directory, path)) {
      return false;
    }
    return !flatLayout || p.equals(p.dirname(path), root);
  }

  Future<bool> _existingDirectoryIsWithin(
    String directory,
    String resolvedRoot,
  ) async {
    final entity = Directory(directory);
    if (!await entity.exists()) {
      return true;
    }
    final resolved = p.normalize(await entity.resolveSymbolicLinks());
    return p.equals(resolvedRoot, resolved) ||
        p.isWithin(resolvedRoot, resolved);
  }

  Future<bool> _existingFileIsWithin(String path, String resolvedRoot) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      return true;
    }
    if (type != FileSystemEntityType.file) {
      return false;
    }
    final resolved = p.normalize(await File(path).resolveSymbolicLinks());
    return p.isWithin(resolvedRoot, resolved);
  }

  Future<int> sizeOf(String directoryPath) async {
    final directory = Directory(directoryPath);
    if (!await directory.exists()) {
      return 0;
    }
    var total = 0;
    await for (final entity in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is File) {
        try {
          total += await entity.length();
        } on FileSystemException {
          // A concurrently finalized or deleted file is omitted from the snapshot.
        }
      }
    }
    return total;
  }
}

final class EvidenceDeletionResult {
  const EvidenceDeletionResult.deleted()
    : deleted = true,
      invalidPath = false,
      message = null;

  const EvidenceDeletionResult.invalid(this.message)
    : deleted = false,
      invalidPath = true;

  const EvidenceDeletionResult.failed(this.message)
    : deleted = false,
      invalidPath = false;

  final bool deleted;
  final bool invalidPath;
  final String? message;
}

final class _EvidenceArtifactGroup {
  const _EvidenceArtifactGroup({
    required this.root,
    required this.directory,
    required this.metadataPath,
    this.videoPath,
    required this.framePaths,
    required this.flatLayout,
  });

  final String root;
  final String directory;
  final String metadataPath;
  final String? videoPath;
  final List<String> framePaths;
  final bool flatLayout;

  List<String> get artifactPaths {
    final paths = <String>[metadataPath, ...framePaths];
    final video = videoPath;
    if (video != null) {
      paths.insert(0, video);
    }
    return paths;
  }
}
