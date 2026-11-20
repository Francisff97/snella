import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:snella/src/processor.dart';
import 'package:snella/src/video.dart';

const _ffmpegOutput = '''
Input #0, mov,mp4,m4a,3gp,3g2,mj2, from 'IMG_0042.MOV':
  Duration: 00:00:12.48, start: 0.000000, bitrate: 15873 kb/s
  Stream #0:0[0x1](und): Video: hevc (Main) (hvc1 / 0x31637668), yuv420p(tv, bt709), 1920x1080, 15700 kb/s, 59.94 fps, 59.94 tbr, 600 tbn (default)
      Side data:
        displaymatrix: rotation of -90.00 degrees
  Stream #0:1[0x2](und): Audio: aac (LC) (mp4a / 0x6134706D), 44100 Hz, stereo, fltp, 160 kb/s (default)
''';

void main() {
  test('riconosce i video', () {
    expect(isSupportedVideo('/x/IMG_0042.MOV'), isTrue);
    expect(isSupportedVideo('/x/foto.jpg'), isFalse);
    expect(isSupportedMedia('/x/foto.jpg'), isTrue);
  });

  test('legge le informazioni di ffmpeg, rotazione compresa', () {
    final info = parseFfmpegInfo(_ffmpegOutput)!;
    expect(info.width, 1080);
    expect(info.height, 1920);
    expect(info.duration, const Duration(seconds: 12, milliseconds: 480));
    expect(info.fps, closeTo(59.94, 0.01));
    expect(info.hasAudio, isTrue);
    expect(parseFfmpegInfo('niente'), isNull);
  });

  test('qualità → CRF', () {
    expect(crfFor(VideoFormat.mp4, 80), 26);
    expect(crfFor(VideoFormat.webm, 80), 34);
    expect(crfFor(VideoFormat.mp4, 100), 23);
    expect(crfFor(VideoFormat.mp4, 40), 33);
  });

  test('argomenti ffmpeg', () {
    final args = buildVideoArgs(
      input: 'in.mov',
      output: 'out.mp4',
      format: VideoFormat.mp4,
      width: 1281,
      quality: 80,
      mute: true,
      maxSeconds: 10,
      capFps: true,
    );
    expect(args, containsAllInOrder(['-i', 'in.mov', '-t', '10']));
    expect(args, contains('scale=1280:-2:flags=lanczos,fps=30'));
    expect(args, containsAllInOrder(['-c:v', 'libx264']));
    expect(args, contains('-an'));
    expect(args, contains('+faststart'));
    expect(args.last, 'out.mp4');
  });

  test('nomi dei video', () {
    expect(
      videoFileName(base: 'agriturismo-todi', index: 2, width: 1920, ext: 'mp4', numbered: true),
      'agriturismo-todi-video-02-1920.mp4',
    );
    expect(
      videoFileName(base: 'a', index: 1, width: 1280, ext: 'webp', numbered: false, kind: 'poster'),
      'a-poster-1280.webp',
    );
  });

  test('snippet <video> con versioni e poster', () {
    final html = buildVideoHtml([
      SourceResult(
        sourcePath: '/x/v.mov',
        sourceBytes: 100,
        index: 1,
        alt: 'Piscina al tramonto',
        isVideo: true,
        outputs: const [
          OutputFile(path: '/o/a-video-1920.mp4', width: 1920, height: 1080, bytes: 1),
          OutputFile(path: '/o/a-video-1280.mp4', width: 1280, height: 720, bytes: 1),
          OutputFile(path: '/o/a-video-1280.webm', width: 1280, height: 720, bytes: 1),
          OutputFile(path: '/o/a-poster-1920.webp', width: 1920, height: 1080, bytes: 1, isPoster: true),
        ],
      ),
    ], mute: true);
    expect(html, contains('autoplay muted loop playsinline'));
    expect(html, contains('poster="a-poster-1920.webp"'));
    expect(
      html.indexOf('a-video-1280.webm" type="video/webm" media="(max-width: 1280px)"'),
      lessThan(html.indexOf('a-video-1280.mp4')),
    );
    expect(html, contains('<source src="a-video-1920.mp4" type="video/mp4">'));
  });

  test('formatDuration', () {
    expect(formatDuration(const Duration(seconds: 12)), '0:12');
    expect(formatDuration(const Duration(hours: 1, minutes: 5, seconds: 3)), '1:05:03');
  });

  final ffmpeg = [
    '/usr/local/bin/ffmpeg',
    '/usr/bin/ffmpeg',
    '/opt/homebrew/bin/ffmpeg',
  ].where((f) => File(f).existsSync());
  test(
    'prepara davvero un video',
    () async {
      final tmp = await Directory.systemTemp.createTemp('snella-video-test');
      final src = p.join(tmp.path, 'IMG_0042.mov');
      await Process.run(ffmpeg.first, [
        '-y',
        '-f',
        'lavfi',
        '-i',
        'testsrc2=size=1920x1080:rate=60:duration=3',
        '-f',
        'lavfi',
        '-i',
        'sine=frequency=440:duration=3',
        '-c:v',
        'libx264',
        '-crf',
        '12',
        '-c:a',
        'aac',
        '-shortest',
        src,
      ]);
      final out = p.join(tmp.path, 'web');
      final r = await processVideoFile(
        ffmpeg: ffmpeg.first,
        sourcePath: src,
        index: 1,
        numbered: false,
        keyword: 'Piscina Todi',
        outputDir: out,
        settings: const VideoSettings(
          formats: {VideoFormat.mp4, VideoFormat.webm},
          widths: [1280, 2560],
          quality: 80,
          mute: true,
          maxSeconds: 2,
          poster: true,
        ),
        posterFormat: OutputFormat.webp,
        posterQuality: 80,
      );
      expect(r.error, isNull);
      final names = r.outputs.map((o) => o.name).toList()..sort();
      expect(names, [
        'piscina-todi-poster-1920.webp',
        'piscina-todi-video-1280.mp4',
        'piscina-todi-video-1280.webm',
        'piscina-todi-video-1920.mp4',
        'piscina-todi-video-1920.webm',
      ]);
      final info = (await probeVideo(ffmpeg.first, p.join(out, 'piscina-todi-video-1280.mp4')))!;
      expect(info.width, 1280);
      expect(info.hasAudio, isFalse);
      expect(info.fps, lessThanOrEqualTo(30));
      expect(info.duration.inMilliseconds, lessThanOrEqualTo(2100));
      await tmp.delete(recursive: true);
    },
    skip: ffmpeg.isEmpty ? 'ffmpeg non installato' : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
