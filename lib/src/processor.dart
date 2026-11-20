import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:swipelab_webp/swipelab_webp.dart';

/// Formati di uscita supportati.
enum OutputFormat { webp, jpeg }

extension OutputFormatX on OutputFormat {
  String get extension => this == OutputFormat.webp ? 'webp' : 'jpg';
  String get label => this == OutputFormat.webp ? 'WebP' : 'JPEG';
}

/// Estensioni che Snella sa leggere.
const supportedInputExtensions = {'.jpg', '.jpeg', '.png', '.webp', '.tif', '.tiff', '.bmp', '.gif'};

bool isSupportedImage(String path) => supportedInputExtensions.contains(p.extension(path).toLowerCase());

/// Impostazioni di un lavoro. Solo dati semplici, così passa tra isolate.
class SnellaSettings {
  const SnellaSettings({
    required this.keyword,
    required this.format,
    required this.quality,
    required this.widths,
    required this.outputDir,
  });

  final String keyword;
  final OutputFormat format;
  final int quality;
  final List<int> widths;
  final String outputDir;
}

/// Un file generato.
class OutputFile {
  const OutputFile({
    required this.path,
    required this.width,
    required this.height,
    required this.bytes,
    this.isPoster = false,
  });

  final String path;
  final int width;
  final int height;
  final int bytes;

  /// L'immagine di copertina di un video.
  final bool isPoster;

  String get name => p.basename(path);
}

/// Il risultato per una singola foto di partenza.
class SourceResult {
  const SourceResult({
    required this.sourcePath,
    required this.sourceBytes,
    required this.index,
    required this.outputs,
    required this.alt,
    this.error,
    this.isVideo = false,
  });

  final String sourcePath;
  final int sourceBytes;
  final int index;
  final List<OutputFile> outputs;
  final String alt;
  final String? error;
  final bool isVideo;

  bool get ok => error == null;
  int get outputBytes => outputs.fold(0, (sum, o) => sum + o.bytes);

  /// Peso della versione più grande: è quella che conta per il risparmio.
  int get largestOutputBytes => outputs.isEmpty ? 0 : outputs.map((o) => o.bytes).reduce((a, b) => a > b ? a : b);
}

// ---------------------------------------------------------------------------
// Nomi e testi
// ---------------------------------------------------------------------------

const _accents = {
  'à': 'a',
  'á': 'a',
  'â': 'a',
  'ä': 'a',
  'ã': 'a',
  'å': 'a',
  'è': 'e',
  'é': 'e',
  'ê': 'e',
  'ë': 'e',
  'ì': 'i',
  'í': 'i',
  'î': 'i',
  'ï': 'i',
  'ò': 'o',
  'ó': 'o',
  'ô': 'o',
  'ö': 'o',
  'õ': 'o',
  'ù': 'u',
  'ú': 'u',
  'û': 'u',
  'ü': 'u',
  'ñ': 'n',
  'ç': 'c',
  'ß': 'ss',
  'æ': 'ae',
  'œ': 'oe',
  'ø': 'o',
};

/// "Camera Doppia — Vista Lago!" -> "camera-doppia-vista-lago"
String slugify(String input) {
  final lower = input.trim().toLowerCase();
  final buffer = StringBuffer();
  for (final rune in lower.runes) {
    final ch = String.fromCharCode(rune);
    buffer.write(_accents[ch] ?? ch);
  }
  return buffer
      .toString()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'-+'), '-')
      .replaceAll(RegExp(r'^-|-$'), '');
}

/// Base del nome file: parola chiave se c'è, altrimenti il nome originale.
String baseNameFor(String sourcePath, String keyword) {
  final fromKeyword = slugify(keyword);
  if (fromKeyword.isNotEmpty) return fromKeyword;
  final fromFile = slugify(p.basenameWithoutExtension(sourcePath));
  return fromFile.isEmpty ? 'foto' : fromFile;
}

/// Nome finale, es. agriturismo-todi-03-1200.webp
String outputFileName({
  required String base,
  required int index,
  required int width,
  required OutputFormat format,
  required bool numbered,
}) {
  final number = numbered ? '-${index.toString().padLeft(2, '0')}' : '';
  return '$base$number-$width.${format.extension}';
}

/// Alt di partenza, da rifinire a mano: "Agriturismo todi, foto 3".
String suggestAlt(String sourcePath, String keyword, int index) {
  final words = baseNameFor(sourcePath, keyword).split('-').where((w) => w.isNotEmpty);
  final phrase = words.join(' ');
  final sentence = phrase.isEmpty ? 'Foto' : phrase[0].toUpperCase() + phrase.substring(1);
  return keyword.trim().isEmpty ? sentence : '$sentence, foto $index';
}

/// Larghezze da generare per una foto larga [originalWidth]:
/// mai ingrandire, e almeno una versione a dimensione originale.
List<int> targetWidths(int originalWidth, List<int> requested) {
  final sorted = {...requested}.where((w) => w > 0).toList()..sort((a, b) => b - a);
  final result = sorted.where((w) => w <= originalWidth).toList();
  // Se la foto è più stretta della larghezza massima richiesta,
  // la sua larghezza diventa la versione più grande.
  final needsOriginal = result.isEmpty || sorted.first > originalWidth;
  if (needsOriginal && !result.contains(originalWidth)) {
    result.insert(0, originalWidth);
  }
  return result;
}

// ---------------------------------------------------------------------------
// Elaborazione
// ---------------------------------------------------------------------------

/// Prepara una foto in un isolate separato, così l'interfaccia resta fluida.
Future<SourceResult> processInBackground({
  required String sourcePath,
  required int index,
  required bool numbered,
  required SnellaSettings settings,
}) {
  return Isolate.run(
    () => processImageFile(sourcePath: sourcePath, index: index, numbered: numbered, settings: settings),
  );
}

/// Legge, raddrizza, ridimensiona, ripulisce dai metadati e salva una foto.
Future<SourceResult> processImageFile({
  required String sourcePath,
  required int index,
  required bool numbered,
  required SnellaSettings settings,
}) async {
  final alt = suggestAlt(sourcePath, settings.keyword, index);
  final file = File(sourcePath);
  int sourceBytes = 0;
  try {
    final bytes = await file.readAsBytes();
    sourceBytes = bytes.length;

    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      return SourceResult(
        sourcePath: sourcePath,
        sourceBytes: sourceBytes,
        index: index,
        outputs: const [],
        alt: alt,
        error: 'unreadable',
      );
    }

    // Applica la rotazione dello scatto e poi butta via tutti i metadati
    // (EXIF, GPS, modello di fotocamera).
    var image = img.bakeOrientation(decoded);
    image.exif = img.ExifData();
    image.iccProfile = null;
    image.textData = null;

    await Directory(settings.outputDir).create(recursive: true);
    final base = baseNameFor(sourcePath, settings.keyword);
    final outputs = <OutputFile>[];

    for (final width in targetWidths(image.width, settings.widths)) {
      final resized = width == image.width
          ? image
          : img.copyResize(image, width: width, interpolation: img.Interpolation.average);

      final encoded = encodeImage(resized, settings.format, settings.quality);
      final name = outputFileName(
        base: base,
        index: index,
        width: resized.width,
        format: settings.format,
        numbered: numbered,
      );
      final outPath = p.join(settings.outputDir, name);
      await File(outPath).writeAsBytes(encoded, flush: true);
      outputs.add(OutputFile(path: outPath, width: resized.width, height: resized.height, bytes: encoded.length));
    }

    return SourceResult(sourcePath: sourcePath, sourceBytes: sourceBytes, index: index, outputs: outputs, alt: alt);
  } catch (e) {
    return SourceResult(
      sourcePath: sourcePath,
      sourceBytes: sourceBytes,
      index: index,
      outputs: const [],
      alt: alt,
      error: e.toString(),
    );
  }
}

/// Codifica un'immagine già ridimensionata.
Uint8List encodeImage(img.Image image, OutputFormat format, int quality) {
  switch (format) {
    case OutputFormat.jpeg:
      // Il JPEG non ha trasparenza: appoggiamo la foto su fondo bianco.
      final flat = image.hasAlpha
          ? img.compositeImage(
              img.Image(width: image.width, height: image.height)..clear(img.ColorRgb8(255, 255, 255)),
              image,
            )
          : image;
      return img.encodeJpg(flat, quality: quality);
    case OutputFormat.webp:
      final rgba = image
          .convert(format: img.Format.uint8, numChannels: 4, alpha: 255)
          .getBytes(order: img.ChannelOrder.rgba);
      final out = WebPEncoder.encodeRgba(
        rgba: rgba,
        width: image.width,
        height: image.height,
        quality: quality.toDouble(),
      );
      if (out == null) throw StateError('webp-encode-failed');
      return out;
  }
}

// ---------------------------------------------------------------------------
// File di accompagnamento
// ---------------------------------------------------------------------------

String _csvCell(String value) {
  if (value.contains(RegExp('[",\n;]'))) {
    return '"${value.replaceAll('"', '""')}"';
  }
  return value;
}

/// CSV con nomi, misure, pesi e alt suggerito, da incollare nel CMS.
String buildCsv(List<SourceResult> results) {
  final rows = <List<String>>[
    ['file', 'larghezza', 'altezza', 'peso_kb', 'alt_suggerito', 'originale', 'peso_originale_kb'],
  ];
  for (final r in results.where((r) => r.ok)) {
    for (final o in r.outputs) {
      rows.add([
        o.name,
        '${o.width}',
        '${o.height}',
        (o.bytes / 1024).toStringAsFixed(1),
        r.alt,
        p.basename(r.sourcePath),
        (r.sourceBytes / 1024).toStringAsFixed(1),
      ]);
    }
  }
  return rows.map((row) => row.map(_csvCell).join(',')).join('\n');
}

String _htmlEscape(String s) =>
    s.replaceAll('&', '&amp;').replaceAll('"', '&quot;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

/// Un tag <img> con srcset per ogni foto, pronto da incollare.
String buildSrcsetHtml(List<SourceResult> results) {
  final buffer = StringBuffer()..writeln('<!-- Generato con Snella — francescoferri.me -->');
  for (final r in results.where((r) => r.ok && !r.isVideo && r.outputs.isNotEmpty)) {
    final sorted = [...r.outputs]..sort((a, b) => a.width - b.width);
    final largest = sorted.last;
    final srcset = sorted.map((o) => '${o.name} ${o.width}w').join(', ');
    buffer
      ..writeln('<img')
      ..writeln('  src="${largest.name}"')
      ..writeln('  srcset="$srcset"')
      ..writeln('  sizes="(max-width: ${largest.width}px) 100vw, ${largest.width}px"')
      ..writeln('  width="${largest.width}" height="${largest.height}"')
      ..writeln('  alt="${_htmlEscape(r.alt)}"')
      ..writeln('  loading="lazy" decoding="async">')
      ..writeln();
  }
  return buffer.toString();
}

/// "48,2 MB", "312 KB"
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(0)} KB';
  final mb = kb / 1024;
  return '${mb.toStringAsFixed(1).replaceAll('.', ',')} MB';
}
