import 'dart:io';
import 'dart:math' as math;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import 'brand.dart';
import 'processor.dart';
import 'strings.dart';
import 'video.dart';
import 'widgets.dart';

const _presetWidths = [2560, 1920, 1600, 1200, 800, 480];
const _videoPresetWidths = [1920, 1280, 960, 720];
const _durations = [0, 10, 15, 30];

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final s = S.current;

  final _files = <String>[];
  final _keyword = TextEditingController();
  final _customWidth = TextEditingController();

  OutputFormat _format = OutputFormat.webp;
  int _quality = 80;
  final _widths = <int>{1920, 1200, 800};
  final _extraWidths = <int>[];
  String? _outputDir;
  bool _csv = true;
  bool _srcset = true;

  final _videoFormats = <VideoFormat>{VideoFormat.mp4};
  final _videoWidths = <int>{1920, 1280};
  bool _mute = true;
  bool _poster = true;
  int _maxSeconds = 0;
  final _thumbs = <String, String>{};
  final _videoInfo = <String, VideoInfo>{};
  int _videoRunning = 0;
  int _videoTotal = 0;
  double _videoProgress = 0;

  bool _dragging = false;
  bool _running = false;
  int _done = 0;
  List<SourceResult>? _results;
  String? _lastOutputDir;

  @override
  void dispose() {
    _keyword.dispose();
    _customWidth.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // File
  // -------------------------------------------------------------------------

  Future<void> _addPaths(Iterable<String> paths) async {
    final found = <String>[];
    for (final path in paths) {
      final type = await FileSystemEntity.type(path);
      if (type == FileSystemEntityType.directory) {
        await for (final entity in Directory(path).list(recursive: true, followLinks: false)) {
          if (entity is File && isSupportedMedia(entity.path)) found.add(entity.path);
        }
      } else if (type == FileSystemEntityType.file && isSupportedMedia(path)) {
        found.add(path);
      }
    }
    found.sort();
    setState(() {
      if (_results != null) {
        _results = null;
        _files.clear();
      }
      for (final f in found) {
        if (!_files.contains(f)) _files.add(f);
      }
    });
    _loadVideoPreviews(found.where(isSupportedVideo));
  }

  /// Per i video: un fotogramma per la griglia e la durata.
  Future<void> _loadVideoPreviews(Iterable<String> videos) async {
    final list = videos.where((v) => !_thumbs.containsKey(v)).toList();
    if (list.isEmpty) return;
    final ffmpeg = await findFfmpeg();
    if (ffmpeg == null) return;
    final tmp = await Directory.systemTemp.createTemp('snella-thumbs');
    for (final v in list) {
      final info = await probeVideo(ffmpeg, v);
      final thumb = await extractThumb(
        ffmpeg,
        v,
        p.join(tmp.path, '${_thumbs.length}-${p.basenameWithoutExtension(v)}.jpg'),
      );
      if (!mounted) return;
      setState(() {
        if (info != null) _videoInfo[v] = info;
        if (thumb != null) _thumbs[v] = thumb;
      });
    }
  }

  bool get _hasVideos => _files.any(isSupportedVideo);

  Future<void> _pickFiles() async {
    const group = XTypeGroup(
      label: 'Foto e video',
      extensions: [
        'jpg',
        'jpeg',
        'png',
        'webp',
        'tif',
        'tiff',
        'bmp',
        'gif',
        'mp4',
        'mov',
        'm4v',
        'webm',
        'mkv',
        'avi',
      ],
      uniformTypeIdentifiers: ['public.image', 'public.movie'],
    );
    final picked = await openFiles(acceptedTypeGroups: [group]);
    if (picked.isNotEmpty) await _addPaths(picked.map((f) => f.path));
  }

  Future<void> _pickOutputDir() async {
    final dir = await getDirectoryPath(confirmButtonText: s.t('Usa questa cartella', 'Use this folder'));
    if (dir != null) setState(() => _outputDir = dir);
  }

  void _addCustomWidth() {
    final value = int.tryParse(_customWidth.text.trim());
    if (value == null || value < 16 || value > 10000) return;
    setState(() {
      if (!_presetWidths.contains(value) && !_extraWidths.contains(value)) _extraWidths.add(value);
      _widths.add(value);
      _customWidth.clear();
    });
  }

  // -------------------------------------------------------------------------
  // Elaborazione
  // -------------------------------------------------------------------------

  Future<void> _run() async {
    if (_files.isEmpty || _running) return;
    final images = _files.where(isSupportedImage).toList();
    final videos = _files.where(isSupportedVideo).toList();
    if (images.isNotEmpty && _widths.isEmpty) return;
    if (videos.isNotEmpty && (_videoWidths.isEmpty || _videoFormats.isEmpty)) return;

    final outDir = _outputDir ?? p.join(p.dirname(_files.first), 'snella-web');
    final settings = SnellaSettings(
      keyword: _keyword.text,
      format: _format,
      quality: _quality,
      widths: _widths.toList(),
      outputDir: outDir,
    );

    // Numeri progressivi solo se più file finirebbero con lo stesso nome.
    bool needsNumbers(List<String> list) {
      final bases = list.map((f) => baseNameFor(f, settings.keyword)).toList();
      return bases.toSet().length != bases.length;
    }

    final numberedImages = needsNumbers(images);
    final numberedVideos = needsNumbers(videos);

    setState(() {
      _running = true;
      _done = 0;
      _videoRunning = 0;
      _videoTotal = videos.length;
      _videoProgress = 0;
    });

    // Foto: in parallelo, ognuna nel suo isolate.
    final results = List<SourceResult?>.filled(images.length, null);
    var next = 0;
    final workers = math.max(1, math.min(3, Platform.numberOfProcessors - 1));

    Future<void> worker() async {
      while (true) {
        final i = next++;
        if (i >= images.length) return;
        results[i] = await processInBackground(
          sourcePath: images[i],
          index: i + 1,
          numbered: numberedImages,
          settings: settings,
        );
        if (mounted) setState(() => _done++);
      }
    }

    await Future.wait(List.generate(workers, (_) => worker()));
    final done = results.whereType<SourceResult>().toList();

    // Video: uno alla volta, ffmpeg usa già tutti i core.
    if (videos.isNotEmpty) {
      final ffmpeg = await findFfmpeg();
      final videoSettings = VideoSettings(
        formats: {..._videoFormats},
        widths: _videoWidths.toList(),
        quality: _quality,
        mute: _mute,
        maxSeconds: _maxSeconds,
        poster: _poster,
      );
      for (var i = 0; i < videos.length; i++) {
        if (mounted) {
          setState(() {
            _videoRunning = i + 1;
            _videoProgress = 0;
          });
        }
        if (ffmpeg == null) {
          done.add(
            SourceResult(
              sourcePath: videos[i],
              sourceBytes: 0,
              index: i + 1,
              outputs: const [],
              alt: '',
              error: 'no-ffmpeg',
              isVideo: true,
            ),
          );
        } else {
          done.add(
            await processVideoFile(
              ffmpeg: ffmpeg,
              sourcePath: videos[i],
              index: i + 1,
              numbered: numberedVideos,
              keyword: settings.keyword,
              outputDir: outDir,
              settings: videoSettings,
              posterFormat: _format,
              posterQuality: _quality,
              onProgress: (v) {
                if (mounted) setState(() => _videoProgress = v);
              },
            ),
          );
        }
        if (mounted) setState(() => _done++);
      }
    }

    try {
      await Directory(outDir).create(recursive: true);
      if (_csv && done.any((r) => r.ok)) {
        await File(p.join(outDir, 'snella-alt.csv')).writeAsString(buildCsv(done));
      }
      if (_srcset && done.any((r) => r.ok)) {
        await File(p.join(outDir, 'snella-srcset.html'))
            .writeAsString(buildSrcsetHtml(done) + buildVideoHtml(done, mute: _mute));
      }
    } catch (_) {
      // I file sono già salvati: se gli extra non si scrivono, pazienza.
    }

    if (!mounted) return;
    setState(() {
      _running = false;
      _results = done;
      _lastOutputDir = outDir;
    });
  }

  String get _workingLabel {
    if (_videoRunning > 0) {
      return s.workingVideo(_videoRunning, _videoTotal, (_videoProgress * 100).round());
    }
    return s.working(_done, _files.length);
  }

  void _reset() => setState(() {
    _results = null;
    _files.clear();
    _done = 0;
  });

  Future<void> _openFolder() async {
    final dir = _lastOutputDir;
    if (dir == null) return;
    await launchUrl(Uri.directory(dir));
  }

  // -------------------------------------------------------------------------
  // UI
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyO, meta: true): _pickFiles,
          const SingleActivator(LogicalKeyboardKey.keyO, control: true): _pickFiles,
          const SingleActivator(LogicalKeyboardKey.enter, meta: true): _run,
          const SingleActivator(LogicalKeyboardKey.enter, control: true): _run,
        },
        child: Focus(
          autofocus: true,
          child: Column(
            children: [
              _TopBar(onAbout: _showAbout),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 350),
                        child: _results == null
                            ? _buildDropArea()
                            : _ResultsView(
                                key: const ValueKey('results'),
                                results: _results!,
                                onOpenFolder: _openFolder,
                                onReset: _reset,
                              ),
                      ),
                    ),
                    Container(width: 1, color: FD.lineSoft),
                    SizedBox(width: 360, child: _buildSettings()),
                  ],
                ),
              ),
              const _Footer(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDropArea() {
    return DropTarget(
      key: const ValueKey('drop'),
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (details) {
        setState(() => _dragging = false);
        _addPaths(details.files.map((f) => f.path));
      },
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          decoration: BoxDecoration(
            color: _dragging ? FD.accent.withValues(alpha: 0.06) : Colors.transparent,
            border: Border.all(color: _dragging ? FD.accent : FD.line, width: _dragging ? 1.5 : 1),
          ),
          child: _files.isEmpty ? _emptyDrop() : _fileGrid(),
        ),
      ),
    );
  }

  Widget _emptyDrop() {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: _pickFiles,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.all(48),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Text('00 — ${s.t('INIZIA', 'START')}', style: FD.monoStyle(size: 10, color: FD.accent)),
              const SizedBox(height: 20),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  (_dragging ? s.dropActive : s.dropTitle).toUpperCase(),
                  style: FD.displayStyle(88, color: _dragging ? FD.accent : FD.text),
                ),
              ),
              const SizedBox(height: 24),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Text(s.dropHint, style: const TextStyle(fontSize: 15, height: 1.5, color: FD.muted)),
              ),
              const SizedBox(height: 32),
              Row(
                children: [
                  FDButton(label: s.chooseFiles, onPressed: _pickFiles),
                  const SizedBox(width: 16),
                  Text(
                    Platform.isMacOS ? '⌘O' : 'Ctrl+O',
                    style: FD.monoStyle(size: 10, color: FD.muted.withValues(alpha: 0.6)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _fileGrid() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 20, 16),
          child: Row(
            children: [
              Text(
                s.items(_files.where(isSupportedImage).length, _files.where(isSupportedVideo).length).toUpperCase(),
                style: FD.displayStyle(28),
              ),
              const Spacer(),
              if (_running)
                Text(_workingLabel.toUpperCase(), style: FD.monoStyle(color: FD.accent))
              else ...[
                FDTextLink(label: '+ ${s.chooseFiles}', onTap: _pickFiles),
                const SizedBox(width: 20),
                FDTextLink(label: s.clear, onTap: () => setState(_files.clear)),
              ],
            ],
          ),
        ),
        if (_running)
          LinearProgressIndicator(
            value: _files.isEmpty ? null : (_done + (_videoRunning > 0 ? _videoProgress : 0)) / _files.length,
            minHeight: 1,
            backgroundColor: FD.lineSoft,
            color: FD.accent,
          )
        else
          Container(height: 1, color: FD.lineSoft),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(20),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 180,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 0.82,
            ),
            itemCount: _files.length,
            itemBuilder: (context, i) => _Thumb(
              path: _files[i],
              preview: _thumbs[_files[i]],
              info: _videoInfo[_files[i]],
              onRemove: _running ? null : () => setState(() => _files.removeAt(i)),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSettings() {
    final allWidths = [..._presetWidths, ..._extraWidths]..sort((a, b) => b - a);
    final outLabel = _outputDir ?? s.outputDefault;
    final hasImages = _files.any(isSupportedImage);
    final canRun =
        _files.isNotEmpty &&
        (!hasImages || _widths.isNotEmpty) &&
        (!_hasVideos || (_videoWidths.isNotEmpty && _videoFormats.isNotEmpty)) &&
        !_running &&
        _results == null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(28, 28, 28, 12),
            children: [
              Text(s.settings.toUpperCase(), style: FD.displayStyle(28)),
              const SizedBox(height: 28),

              SectionLabel('01', s.keyword),
              TextField(
                controller: _keyword,
                enabled: !_running,
                style: const TextStyle(fontSize: 14, color: FD.text),
                decoration: InputDecoration(
                  hintText: s.keywordHint,
                  hintStyle: TextStyle(fontSize: 13, color: FD.muted.withValues(alpha: 0.6)),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 12),
                  enabledBorder: const UnderlineInputBorder(borderSide: BorderSide(color: FD.line)),
                  focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: FD.accent)),
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 8),
              ValueListenableBuilder(
                valueListenable: _keyword,
                builder: (context, value, _) {
                  final slug = slugify(value.text);
                  final example = slug.isEmpty
                      ? s.keywordHelp
                      : '→ $slug-01-${_widths.isEmpty ? 1200 : _widths.reduce(math.max)}.${_format.extension}';
                  return Text(
                    example,
                    style: slug.isEmpty
                        ? const TextStyle(fontSize: 12, height: 1.4, color: FD.muted)
                        : FD.monoStyle(size: 10.5, color: FD.accent).copyWith(letterSpacing: 0.5),
                  );
                },
              ),
              const SizedBox(height: 32),

              SectionLabel('02', s.format),
              Row(
                children: [
                  for (final f in OutputFormat.values) ...[
                    FDChip(
                      label: f.label,
                      selected: _format == f,
                      onTap: () => setState(() {
                        _format = f;
                        _quality = f == OutputFormat.webp ? 80 : 82;
                      }),
                    ),
                    const SizedBox(width: 8),
                  ],
                ],
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Text(s.quality.toUpperCase(), style: FD.monoStyle(size: 10)),
                  const Spacer(),
                  Text(
                    '$_quality',
                    style: FD.monoStyle(size: 12, color: FD.text, weight: FontWeight.w700),
                  ),
                ],
              ),
              Slider(
                value: _quality.toDouble(),
                min: 40,
                max: 100,
                divisions: 60,
                onChanged: _running ? null : (v) => setState(() => _quality = v.round()),
              ),
              const SizedBox(height: 20),

              SectionLabel('03', s.widths),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final w in allWidths)
                    FDChip(
                      label: '$w',
                      selected: _widths.contains(w),
                      onTap: () => setState(() => _widths.contains(w) ? _widths.remove(w) : _widths.add(w)),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  SizedBox(
                    width: 90,
                    child: TextField(
                      controller: _customWidth,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      style: FD.monoStyle(size: 12, color: FD.text),
                      decoration: InputDecoration(
                        hintText: 'px',
                        hintStyle: FD.monoStyle(size: 11),
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(vertical: 10),
                        enabledBorder: const UnderlineInputBorder(borderSide: BorderSide(color: FD.line)),
                        focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: FD.accent)),
                      ),
                      onSubmitted: (_) => _addCustomWidth(),
                    ),
                  ),
                  const SizedBox(width: 16),
                  FDTextLink(label: '+ ${s.addWidth}', onTap: _addCustomWidth),
                ],
              ),
              const SizedBox(height: 10),
              Text(s.widthsHelp, style: const TextStyle(fontSize: 12, height: 1.4, color: FD.muted)),
              const SizedBox(height: 32),

              SectionLabel('04', s.outputFolder),
              Row(
                children: [
                  Expanded(
                    child: Tooltip(
                      message: outLabel,
                      child: Text(
                        _outputDir == null ? outLabel : p.basename(outLabel),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13, color: _outputDir == null ? FD.muted : FD.text),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FDTextLink(label: s.change, onTap: _pickOutputDir),
                ],
              ),
              const SizedBox(height: 32),

              SectionLabel('05', s.extras),
              FDToggle(label: s.csv, value: _csv, onChanged: _running ? null : (v) => setState(() => _csv = v)),
              FDToggle(
                label: s.srcset,
                value: _srcset,
                onChanged: _running ? null : (v) => setState(() => _srcset = v),
              ),
              FDToggle(label: s.alwaysStripped, value: true, onChanged: null),
              if (_hasVideos) ..._buildVideoSettings(),
            ],
          ),
        ),
        Container(height: 1, color: FD.lineSoft),
        Padding(
          padding: const EdgeInsets.all(20),
          child: FDButton(
            label: _running ? _workingLabel : (_files.isEmpty ? s.addPhotosFirst : s.run),
            big: true,
            filled: true,
            icon: _running ? null : Icons.arrow_forward,
            onPressed: canRun ? _run : null,
          ),
        ),
      ],
    );
  }

  List<Widget> _buildVideoSettings() {
    return [
      const SizedBox(height: 32),
      SectionLabel('06', s.video),
      Text(s.videoFormats.toUpperCase(), style: FD.monoStyle(size: 10)),
      const SizedBox(height: 10),
      Row(
        children: [
          for (final f in VideoFormat.values) ...[
            FDChip(
              label: f.label,
              selected: _videoFormats.contains(f),
              onTap: () => setState(() {
                if (_videoFormats.contains(f)) {
                  if (_videoFormats.length > 1) _videoFormats.remove(f);
                } else {
                  _videoFormats.add(f);
                }
              }),
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
      const SizedBox(height: 10),
      Text(s.videoHelp, style: const TextStyle(fontSize: 12, height: 1.4, color: FD.muted)),
      const SizedBox(height: 20),
      Text(s.videoWidths.toUpperCase(), style: FD.monoStyle(size: 10)),
      const SizedBox(height: 10),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final w in _videoPresetWidths)
            FDChip(
              label: '$w',
              selected: _videoWidths.contains(w),
              onTap: () => setState(() => _videoWidths.contains(w) ? _videoWidths.remove(w) : _videoWidths.add(w)),
            ),
        ],
      ),
      const SizedBox(height: 20),
      Text(s.duration.toUpperCase(), style: FD.monoStyle(size: 10)),
      const SizedBox(height: 10),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final d in _durations)
            FDChip(
              label: d == 0 ? s.whole : '$d s',
              selected: _maxSeconds == d,
              onTap: () => setState(() => _maxSeconds = d),
            ),
        ],
      ),
      const SizedBox(height: 16),
      FDToggle(label: s.mute, value: _mute, onChanged: _running ? null : (v) => setState(() => _mute = v)),
      FDToggle(label: s.poster, value: _poster, onChanged: _running ? null : (v) => setState(() => _poster = v)),
    ];
  }

  void _showAbout() {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.7),
      builder: (context) => Dialog(
        backgroundColor: FD.surface,
        shape: const RoundedRectangleBorder(side: BorderSide(color: FD.line)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.all(36),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const FDLogo(height: 56),
                const SizedBox(height: 28),
                Text('SNELLA', style: FD.displayStyle(44)),
                const SizedBox(height: 8),
                Text(s.tagline.toUpperCase(), style: FD.monoStyle(size: 10, color: FD.accent)),
                const SizedBox(height: 24),
                Text(s.aboutBody, style: const TextStyle(fontSize: 14, height: 1.6, color: FD.text)),
                const SizedBox(height: 16),
                Text(s.free, style: const TextStyle(fontSize: 13, height: 1.5, color: FD.muted)),
                const SizedBox(height: 28),
                Container(height: 1, color: FD.line),
                const SizedBox(height: 20),
                Text(s.madeBy.toUpperCase(), style: FD.monoStyle(size: 10, color: FD.text)),
                const SizedBox(height: 4),
                Text(s.madeBySub, style: const TextStyle(fontSize: 13, color: FD.muted)),
                const SizedBox(height: 20),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    FDButton(label: 'francescoferri.me', onPressed: () => openLink(FDLinks.site)),
                    FDButton(label: s.writeMe, onPressed: () => openLink(FDLinks.email)),
                    FDButton(label: s.close, onPressed: () => Navigator.of(context).pop()),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _TopBar extends StatelessWidget {
  const _TopBar({required this.onAbout});

  final VoidCallback onAbout;

  @override
  Widget build(BuildContext context) {
    final s = S.current;
    return Container(
      height: 64,
      padding: EdgeInsets.only(left: Platform.isMacOS ? 88 : 28, right: 28),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: FD.lineSoft)),
      ),
      child: Row(
        children: [
          const SnellaIcon(size: 28),
          const SizedBox(width: 14),
          Text('SNELLA', style: FD.displayStyle(24)),
          const SizedBox(width: 16),
          Container(width: 1, height: 18, color: FD.line),
          const SizedBox(width: 16),
          Expanded(
            child: Text(s.tagline.toUpperCase(), style: FD.monoStyle(size: 10), overflow: TextOverflow.ellipsis),
          ),
          FDTextLink(label: s.about, onTap: onAbout),
        ],
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer();

  @override
  Widget build(BuildContext context) {
    final s = S.current;
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 28),
      decoration: const BoxDecoration(
        color: Color(0xFF0A0A0A),
        border: Border(top: BorderSide(color: FD.lineSoft)),
      ),
      child: Row(
        children: [
          FDTextLink(label: '© ${DateTime.now().year} Francesco Design', size: 10, onTap: () => openLink(FDLinks.site)),
          const SizedBox(width: 20),
          Expanded(
            child: Text(
              s.free,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11.5, color: FD.muted),
            ),
          ),
          for (final social in FDLinks.socials) ...[
            const SizedBox(width: 18),
            FDTextLink(label: social.label, size: 10, onTap: () => openLink(social.uri)),
          ],
          const SizedBox(width: 18),
          Container(width: 1, height: 14, color: FD.line),
          const SizedBox(width: 18),
          FDTextLink(label: 'francescoferri.me', size: 10, arrow: true, onTap: () => openLink(FDLinks.site)),
        ],
      ),
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({required this.path, required this.onRemove, this.preview, this.info});

  final String path;
  final VoidCallback? onRemove;

  /// Per i video: il fotogramma estratto con ffmpeg.
  final String? preview;
  final VideoInfo? info;

  @override
  Widget build(BuildContext context) {
    final size = File(path).existsSync() ? File(path).lengthSync() : 0;
    final video = isSupportedVideo(path);
    final imagePath = video ? preview : path;
    final placeholder = Center(
      child: Text(p.extension(path).replaceAll('.', '').toUpperCase(), style: FD.monoStyle(size: 12)),
    );
    return Container(
      decoration: BoxDecoration(
        color: FD.surface,
        border: Border.all(color: FD.lineSoft),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (imagePath == null)
                  placeholder
                else
                  Image.file(
                    File(imagePath),
                    fit: BoxFit.cover,
                    cacheWidth: 360,
                    filterQuality: FilterQuality.medium,
                    errorBuilder: (_, _, _) => placeholder,
                  ),
                if (video)
                  Positioned(
                    left: 6,
                    bottom: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                      color: Colors.black.withValues(alpha: 0.7),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.play_arrow, size: 11, color: FD.text),
                          const SizedBox(width: 4),
                          Text(
                            info == null ? 'VIDEO' : formatDuration(info!.duration),
                            style: FD.monoStyle(size: 9, color: FD.text),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (onRemove != null)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        onTap: onRemove,
                        child: Container(
                          width: 22,
                          height: 22,
                          color: Colors.black.withValues(alpha: 0.65),
                          child: const Icon(Icons.close, size: 13, color: FD.text),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  p.basename(path),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11.5, color: FD.text),
                ),
                const SizedBox(height: 2),
                Text(
                  info == null ? formatBytes(size) : '${formatBytes(size)} · ${resolutionLabel(info!)}',
                  style: FD.monoStyle(size: 9.5),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ResultsView extends StatelessWidget {
  const _ResultsView({super.key, required this.results, required this.onOpenFolder, required this.onReset});

  final List<SourceResult> results;
  final VoidCallback onOpenFolder;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final s = S.current;
    final ok = results.where((r) => r.ok).toList();
    final failed = results.where((r) => !r.ok).toList();
    final before = ok.fold<int>(0, (sum, r) => sum + r.sourceBytes);
    final after = ok.fold<int>(0, (sum, r) => sum + r.largestOutputBytes);
    final pct = before == 0 ? 0 : ((1 - after / before) * 100).round().clamp(0, 100);
    final outputs = ok.expand((r) => r.outputs).toList();

    return ListView(
      padding: const EdgeInsets.all(48),
      children: [
        Text('06 — ${s.t('RISULTATO', 'RESULT')}', style: FD.monoStyle(size: 10, color: FD.accent)),
        const SizedBox(height: 20),
        Text(s.resultsTitle.toUpperCase(), style: FD.displayStyle(96)),
        const SizedBox(height: 16),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            s.fromTo(formatBytes(before), formatBytes(after)).toUpperCase(),
            style: FD.displayStyle(44, color: FD.muted),
          ),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Text(
              s.saved(pct).toUpperCase(),
              style: FD.monoStyle(size: 12, color: FD.accent, weight: FontWeight.w700),
            ),
            const SizedBox(width: 20),
            Text(s.filesCreated(outputs.length).toUpperCase(), style: FD.monoStyle(size: 12)),
            if (failed.isNotEmpty) ...[
              const SizedBox(width: 20),
              Text(s.failed(failed.length).toUpperCase(), style: FD.monoStyle(size: 12, color: FD.danger)),
            ],
          ],
        ),
        const SizedBox(height: 32),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            FDButton(label: s.openFolder, filled: true, icon: Icons.folder_open, onPressed: onOpenFolder),
            FDButton(label: s.startOver, onPressed: onReset),
          ],
        ),
        const SizedBox(height: 48),
        Container(height: 1, color: FD.lineSoft),
        for (final r in failed)
          _ResultRow(
            name: p.basename(r.sourcePath),
            meta: r.error == 'unreadable'
                ? s.errorUnreadable
                : r.error == 'no-ffmpeg'
                ? s.noFfmpeg
                : s.errorGeneric,
            size: '',
            error: true,
          ),
        for (final o in outputs)
          _ResultRow(
            name: o.name,
            meta: o.isPoster ? '${o.width} × ${o.height} · POSTER' : '${o.width} × ${o.height}',
            size: formatBytes(o.bytes),
          ),
      ],
    );
  }
}

class _ResultRow extends StatelessWidget {
  const _ResultRow({required this.name, required this.meta, required this.size, this.error = false});

  final String name;
  final String meta;
  final String size;
  final bool error;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: FD.lineSoft)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              name,
              overflow: TextOverflow.ellipsis,
              style: FD.monoStyle(size: 11.5, color: error ? FD.danger : FD.text).copyWith(letterSpacing: 0.3),
            ),
          ),
          SizedBox(
            width: 200,
            child: Text(meta, style: FD.monoStyle(size: 10.5, color: error ? FD.danger : FD.muted)),
          ),
          SizedBox(
            width: 80,
            child: Text(
              size,
              textAlign: TextAlign.right,
              style: FD.monoStyle(size: 10.5, color: FD.text),
            ),
          ),
        ],
      ),
    );
  }
}
