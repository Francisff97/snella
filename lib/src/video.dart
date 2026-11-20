import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'processor.dart';

/// Estensioni video che Snella sa leggere.
const supportedVideoExtensions = {'.mp4', '.mov', '.m4v', '.webm', '.mkv', '.avi'};

bool isSupportedVideo(String path) => supportedVideoExtensions.contains(p.extension(path).toLowerCase());

bool isSupportedMedia(String path) => isSupportedImage(path) || isSupportedVideo(path);

/// Formati video di uscita.
enum VideoFormat { mp4, webm }

extension VideoFormatX on VideoFormat {
  String get extension => this == VideoFormat.mp4 ? 'mp4' : 'webm';
  String get label => this == VideoFormat.mp4 ? 'MP4' : 'WebM';
  String get mime => this == VideoFormat.mp4 ? 'video/mp4' : 'video/webm';
}

/// Impostazioni dei video.
class VideoSettings {
  const VideoSettings({
    required this.formats,
    required this.widths,
    required this.quality,
    required this.mute,
    required this.maxSeconds,
    required this.poster,
  });

  final Set<VideoFormat> formats;
  final List<int> widths;

  /// Stessa scala delle foto (40–100), convertita in CRF.
  final int quality;
  final bool mute;

  /// 0 = video intero.
  final int maxSeconds;
  final bool poster;
}

/// Quello che ffmpeg dice di un video.
class VideoInfo {
  const VideoInfo({
    required this.width,
    required this.height,
    required this.duration,
    required this.fps,
    required this.hasAudio,
  });

  final int width;
  final int height;
  final Duration duration;
  final double fps;
  final bool hasAudio;
}

// ---------------------------------------------------------------------------
// ffmpeg
// ---------------------------------------------------------------------------

String? _ffmpegCache;

/// Cerca ffmpeg: prima quello incluso nell'app, poi quello installato nel sistema.
Future<String?> findFfmpeg() async {
  if (_ffmpegCache != null) return _ffmpegCache;
  final name = Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg';
  final exeDir = p.dirname(Platform.resolvedExecutable);
  final candidates = [
    p.join(exeDir, name), // Windows: accanto a snella.exe. Mac: Snella.app/Contents/MacOS
    p.normalize(p.join(exeDir, '..', 'Resources', name)),
    if (!Platform.isWindows) ...['/opt/homebrew/bin/ffmpeg', '/usr/local/bin/ffmpeg', '/usr/bin/ffmpeg'],
  ];
  for (final c in candidates) {
    if (File(c).existsSync()) {
      if (Platform.isMacOS) {
        // Lo zip scaricato porta con sé la quarantena: la togliamo al binario incluso.
        await Process.run('xattr', ['-d', 'com.apple.quarantine', c]).catchError((_) => ProcessResult(0, 0, '', ''));
      }
      return _ffmpegCache = c;
    }
  }
  try {
    final r = await Process.run(Platform.isWindows ? 'where' : 'which', ['ffmpeg']);
    if (r.exitCode == 0) {
      final first = (r.stdout as String)
          .split(RegExp(r'\r?\n'))
          .firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
      if (first.isNotEmpty) return _ffmpegCache = first.trim();
    }
  } catch (_) {}
  return null;
}

/// Legge dimensioni, durata, fps e audio dall'output di `ffmpeg -i`.
VideoInfo? parseFfmpegInfo(String stderr) {
  final videoLine = RegExp(r'Stream #\d+:\d+.*?: Video: (.*)').firstMatch(stderr)?.group(1);
  if (videoLine == null) return null;
  final size = RegExp(r'(\d{2,5})x(\d{2,5})').firstMatch(videoLine);
  if (size == null) return null;
  var width = int.parse(size.group(1)!);
  var height = int.parse(size.group(2)!);

  // I video del telefono in verticale sono salvati in orizzontale con una rotazione.
  final rotation =
      RegExp(r'rotation of (-?[\d.]+) degrees').firstMatch(stderr) ??
      RegExp(r'rotate\s*:\s*(-?\d+)').firstMatch(stderr);
  if (rotation != null) {
    final deg = double.parse(rotation.group(1)!).round().abs() % 180;
    if (deg == 90) {
      final t = width;
      width = height;
      height = t;
    }
  }

  final fpsMatch = RegExp(r'([\d.]+) fps').firstMatch(videoLine);
  final fps = fpsMatch == null ? 0.0 : double.tryParse(fpsMatch.group(1)!) ?? 0.0;

  var duration = Duration.zero;
  final d = RegExp(r'Duration: (\d+):(\d+):(\d+)\.(\d+)').firstMatch(stderr);
  if (d != null) {
    final frac = d.group(4)!.padRight(3, '0').substring(0, 3);
    duration = Duration(
      hours: int.parse(d.group(1)!),
      minutes: int.parse(d.group(2)!),
      seconds: int.parse(d.group(3)!),
      milliseconds: int.parse(frac),
    );
  }

  return VideoInfo(
    width: width,
    height: height,
    duration: duration,
    fps: fps,
    hasAudio: RegExp(r'Stream #\d+:\d+.*?: Audio:').hasMatch(stderr),
  );
}

Future<VideoInfo?> probeVideo(String ffmpeg, String path) async {
  final r = await Process.run(ffmpeg, ['-hide_banner', '-i', path]);
  return parseFfmpegInfo('${r.stderr}');
}

/// Qualità 40–100 → CRF. 80 dà CRF 26 in H.264, il punto giusto per un video di sfondo.
int crfFor(VideoFormat format, int quality) {
  final x264 = (40 - quality * 0.175).round().clamp(18, 34);
  return format == VideoFormat.mp4 ? x264 : (x264 + 8).clamp(24, 45);
}

/// Argomenti di ffmpeg per una versione del video.
List<String> buildVideoArgs({
  required String input,
  required String output,
  required VideoFormat format,
  required int width,
  required int quality,
  required bool mute,
  required int maxSeconds,
  required bool capFps,
}) {
  final evenWidth = width - width % 2;
  final filters = ['scale=$evenWidth:-2:flags=lanczos', if (capFps) 'fps=30'];
  final crf = crfFor(format, quality);
  return [
    '-hide_banner',
    '-y',
    '-i',
    input,
    if (maxSeconds > 0) ...['-t', '$maxSeconds'],
    '-map',
    '0:v:0',
    if (!mute) ...['-map', '0:a:0?'],
    '-map_metadata',
    '-1',
    '-vf',
    filters.join(','),
    if (format == VideoFormat.mp4) ...[
      '-c:v',
      'libx264',
      '-preset',
      'slow',
      '-crf',
      '$crf',
      '-profile:v',
      'high',
      '-pix_fmt',
      'yuv420p',
      '-movflags',
      '+faststart',
    ] else ...[
      '-c:v',
      'libvpx-vp9',
      '-crf',
      '$crf',
      '-b:v',
      '0',
      '-row-mt',
      '1',
      '-deadline',
      'good',
      '-cpu-used',
      '2',
      '-pix_fmt',
      'yuv420p',
    ],
    if (mute)
      '-an'
    else if (format == VideoFormat.mp4) ...[
      '-c:a',
      'aac',
      '-b:a',
      '128k',
    ] else ...[
      '-c:a',
      'libopus',
      '-b:a',
      '96k',
    ],
    '-progress',
    'pipe:1',
    '-nostats',
    output,
  ];
}

/// Nome dei video, es. agriturismo-todi-video-1920.mp4
String videoFileName({
  required String base,
  required int index,
  required int width,
  required String ext,
  required bool numbered,
  String kind = 'video',
}) {
  final number = numbered ? '-${index.toString().padLeft(2, '0')}' : '';
  return '$base-$kind$number-$width.$ext';
}

/// Fotogramma per l'anteprima nella griglia. Restituisce il percorso o null.
Future<String?> extractThumb(String ffmpeg, String video, String outPath, {double at = 1}) async {
  final r = await Process.run(ffmpeg, [
    '-hide_banner',
    '-y',
    '-ss',
    '$at',
    '-i',
    video,
    '-frames:v',
    '1',
    '-vf',
    'scale=480:-2',
    outPath,
  ]);
  if (r.exitCode == 0 && File(outPath).existsSync()) return outPath;
  if (at > 0) return extractThumb(ffmpeg, video, outPath, at: 0);
  return null;
}

/// Prepara un video: le versioni richieste e il poster.
/// [onProgress] riceve un valore da 0 a 1.
Future<SourceResult> processVideoFile({
  required String ffmpeg,
  required String sourcePath,
  required int index,
  required bool numbered,
  required String keyword,
  required String outputDir,
  required VideoSettings settings,
  required OutputFormat posterFormat,
  required int posterQuality,
  void Function(double)? onProgress,
}) async {
  // L'alt suggerito per le foto dice "foto 3": per un video diciamo "video 3".
  final alt = suggestAlt(
    sourcePath,
    keyword,
    index,
  ).replaceFirstMapped(RegExp(r', foto (\d+)$'), (m) => ', video ${m[1]}');
  int sourceBytes = 0;
  try {
    sourceBytes = await File(sourcePath).length();
    final info = await probeVideo(ffmpeg, sourcePath);
    if (info == null) {
      return SourceResult(
        sourcePath: sourcePath,
        sourceBytes: sourceBytes,
        index: index,
        outputs: const [],
        alt: alt,
        error: 'unreadable',
        isVideo: true,
      );
    }

    await Directory(outputDir).create(recursive: true);
    final base = baseNameFor(sourcePath, keyword);
    final widths = targetWidths(info.width, settings.widths);
    final formats = VideoFormat.values.where(settings.formats.contains).toList();
    final total = widths.length * formats.length;
    final seconds = settings.maxSeconds > 0 && info.duration.inMilliseconds > settings.maxSeconds * 1000
        ? settings.maxSeconds * 1000
        : info.duration.inMilliseconds;
    final outputs = <OutputFile>[];
    var step = 0;

    for (final width in widths) {
      final height = (info.height * width / info.width / 2).round() * 2;
      for (final format in formats) {
        final name = videoFileName(
          base: base,
          index: index,
          width: width - width % 2,
          ext: format.extension,
          numbered: numbered,
        );
        final outPath = p.join(outputDir, name);
        final args = buildVideoArgs(
          input: sourcePath,
          output: outPath,
          format: format,
          width: width,
          quality: settings.quality,
          mute: settings.mute || !info.hasAudio,
          maxSeconds: settings.maxSeconds,
          capFps: info.fps > 31,
        );
        final process = await Process.start(ffmpeg, args);
        final errors = StringBuffer();
        process.stderr.transform(utf8.decoder).listen(errors.write);
        await process.stdout.transform(utf8.decoder).transform(const LineSplitter()).forEach((line) {
          if (line.startsWith('out_time_us=') && seconds > 0) {
            final us = int.tryParse(line.substring(12)) ?? 0;
            final part = (us / 1000 / seconds).clamp(0.0, 1.0);
            onProgress?.call((step + part) / total);
          }
        });
        final code = await process.exitCode;
        if (code != 0) {
          final last = errors.toString().split('\n').lastWhere((l) => l.trim().isNotEmpty, orElse: () => '');
          throw ProcessException(ffmpeg, args, last, code);
        }
        step++;
        onProgress?.call(step / total);
        outputs.add(
          OutputFile(path: outPath, width: width - width % 2, height: height, bytes: await File(outPath).length()),
        );
      }
    }

    if (settings.poster && widths.isNotEmpty) {
      final tmp = p.join(Directory.systemTemp.path, 'snella-poster-${DateTime.now().microsecondsSinceEpoch}.png');
      final at = info.duration.inMilliseconds > 2000 ? 1.0 : 0.0;
      final frame = await Process.run(ffmpeg, [
        '-hide_banner',
        '-y',
        '-ss',
        '$at',
        '-i',
        sourcePath,
        '-frames:v',
        '1',
        tmp,
      ]);
      if (frame.exitCode == 0 && File(tmp).existsSync()) {
        final poster = await processInBackground(
          sourcePath: tmp,
          index: index,
          numbered: numbered,
          settings: SnellaSettings(
            keyword: '',
            format: posterFormat,
            quality: posterQuality,
            widths: [widths.first],
            outputDir: outputDir,
          ),
        );
        if (poster.ok && poster.outputs.isNotEmpty) {
          final o = poster.outputs.first;
          final finalName = videoFileName(
            base: base,
            index: index,
            width: o.width,
            ext: posterFormat.extension,
            numbered: numbered,
            kind: 'poster',
          );
          final finalPath = p.join(outputDir, finalName);
          await File(o.path).rename(finalPath);
          outputs.add(OutputFile(path: finalPath, width: o.width, height: o.height, bytes: o.bytes, isPoster: true));
        }
        try {
          await File(tmp).delete();
        } catch (_) {}
      }
    }

    return SourceResult(
      sourcePath: sourcePath,
      sourceBytes: sourceBytes,
      index: index,
      outputs: outputs,
      alt: alt,
      isVideo: true,
    );
  } catch (e) {
    return SourceResult(
      sourcePath: sourcePath,
      sourceBytes: sourceBytes,
      index: index,
      outputs: const [],
      alt: alt,
      error: e.toString(),
      isVideo: true,
    );
  }
}

String _attr(String s) => s.replaceAll('&', '&amp;').replaceAll('"', '&quot;');

/// Un tag <video> per ogni video: versioni più piccole per i telefoni, poster e lazy.
String buildVideoHtml(List<SourceResult> results, {required bool mute}) {
  final buffer = StringBuffer();
  for (final r in results.where((r) => r.ok && r.isVideo)) {
    final videos = r.outputs.where((o) => !o.isPoster).toList();
    if (videos.isEmpty) continue;
    final poster = r.outputs.where((o) => o.isPoster).firstOrNull;
    final widths = videos.map((o) => o.width).toSet().toList()..sort();
    final largest = videos.where((o) => o.width == widths.last).first;
    final attrs = mute ? 'autoplay muted loop playsinline' : 'controls playsinline';
    buffer
      ..writeln('<video')
      ..writeln('  $attrs preload="metadata"')
      ..writeln('  width="${largest.width}" height="${largest.height}"')
      ..writeln(
        poster == null
            ? '  aria-label="${_attr(r.alt)}">'
            : '  poster="${poster.name}"\n  aria-label="${_attr(r.alt)}">',
      );
    for (final w in widths) {
      final media = w == widths.last ? '' : ' media="(max-width: ${w}px)"';
      // WebM prima: più leggero dove è supportato. MP4 vale per tutti gli altri.
      for (final o in videos.where((o) => o.width == w && o.path.endsWith('.webm'))) {
        buffer.writeln('  <source src="${o.name}" type="video/webm"$media>');
      }
      for (final o in videos.where((o) => o.width == w && o.path.endsWith('.mp4'))) {
        buffer.writeln('  <source src="${o.name}" type="video/mp4"$media>');
      }
    }
    buffer
      ..writeln('</video>')
      ..writeln();
  }
  return buffer.toString();
}

/// "0:12", "1:05:30"
String formatDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
}

/// "4K", "1080p": il lato corto, così vale anche per i video in verticale.
String resolutionLabel(VideoInfo info) {
  final short = info.width < info.height ? info.width : info.height;
  if (short >= 2160) return '4K';
  return '${short}p';
}
