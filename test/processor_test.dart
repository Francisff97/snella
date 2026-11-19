import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:snella/src/processor.dart';

void main() {
  group('nomi', () {
    test('slugify toglie accenti e simboli', () {
      expect(slugify('Camera Doppia — Vista Lago!'), 'camera-doppia-vista-lago');
      expect(slugify('  Città di Todì  '), 'citta-di-todi');
      expect(slugify('IMG_4532'), 'img-4532');
      expect(slugify('***'), '');
    });

    test('baseNameFor usa la parola chiave o il nome originale', () {
      expect(baseNameFor('/x/IMG_4532.JPG', 'Agriturismo Todi'), 'agriturismo-todi');
      expect(baseNameFor('/x/IMG_4532.JPG', ''), 'img-4532');
      expect(baseNameFor('/x/___.jpg', ''), 'foto');
    });

    test('outputFileName', () {
      expect(
        outputFileName(base: 'a', index: 3, width: 1200, format: OutputFormat.webp, numbered: true),
        'a-03-1200.webp',
      );
      expect(outputFileName(base: 'a', index: 3, width: 800, format: OutputFormat.jpeg, numbered: false), 'a-800.jpg');
    });

    test('suggestAlt', () {
      expect(suggestAlt('/x/a.jpg', 'agriturismo todi camera', 2), 'Agriturismo todi camera, foto 2');
      expect(suggestAlt('/x/vista-lago.jpg', '', 1), 'Vista lago');
    });
  });

  group('larghezze', () {
    test('non ingrandisce mai', () {
      expect(targetWidths(4000, [1920, 1200, 800]), [1920, 1200, 800]);
      expect(targetWidths(1500, [1920, 1200, 800]), [1500, 1200, 800]);
      expect(targetWidths(600, [1920, 1200, 800]), [600]);
      expect(targetWidths(1200, [1200, 800, 1200]), [1200, 800]);
    });
  });

  group('elaborazione', () {
    late Directory tmp;
    late String source;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('snella_test');
      final photo = img.Image(width: 2400, height: 1600);
      for (final px in photo) {
        px
          ..r = (px.x * 255 / photo.width).round()
          ..g = (px.y * 255 / photo.height).round()
          ..b = 120;
      }
      photo.exif.imageIfd['Make'] = 'FotocameraDiProva';
      photo.exif.gpsIfd['GPSLatitude'] = img.IfdValueRational(42, 1);
      source = p.join(tmp.path, 'IMG_0001.JPG');
      await File(source).writeAsBytes(img.encodeJpg(photo, quality: 95));
    });

    tearDown(() => tmp.delete(recursive: true));

    for (final format in OutputFormat.values) {
      test('crea ${format.label} ridimensionati e senza EXIF', () async {
        final out = p.join(tmp.path, 'out');
        final result = await processImageFile(
          sourcePath: source,
          index: 1,
          numbered: false,
          settings: SnellaSettings(
            keyword: 'Casale Umbria',
            format: format,
            quality: 80,
            widths: const [1920, 800],
            outputDir: out,
          ),
        );

        expect(result.ok, isTrue, reason: result.error);
        expect(result.outputs.map((o) => o.name), [
          'casale-umbria-1920.${format.extension}',
          'casale-umbria-800.${format.extension}',
        ]);
        expect(result.outputs.first.height, 1280);
        expect(result.largestOutputBytes, lessThan(result.sourceBytes));

        final bytes = await File(result.outputs.last.path).readAsBytes();
        final reread = img.decodeImage(bytes)!;
        expect(reread.width, 800);
        expect(reread.exif.isEmpty, isTrue);
        if (format == OutputFormat.webp) {
          expect(String.fromCharCodes(bytes.sublist(8, 12)), 'WEBP');
        }

        final csv = buildCsv([result]);
        expect(csv.split('\n').length, 3);
        expect(csv, contains('Casale umbria, foto 1'));
        final html = buildSrcsetHtml([result]);
        expect(html, contains('casale-umbria-800.${format.extension} 800w'));
      });
    }

    test('file non leggibile', () async {
      final bad = p.join(tmp.path, 'rotta.jpg');
      await File(bad).writeAsString('non è una foto');
      final result = await processImageFile(
        sourcePath: bad,
        index: 1,
        numbered: false,
        settings: SnellaSettings(
          keyword: '',
          format: OutputFormat.webp,
          quality: 80,
          widths: const [800],
          outputDir: p.join(tmp.path, 'out'),
        ),
      );
      expect(result.ok, isFalse);
    });
  });

  test('formatBytes', () {
    expect(formatBytes(500), '500 B');
    expect(formatBytes(2048), '2 KB');
    expect(formatBytes(5 * 1024 * 1024 + 300 * 1024), '5,3 MB');
  });
}
