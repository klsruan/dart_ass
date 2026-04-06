import 'dart:io';
import 'package:dart_ass/dart_ass.dart';

String _fmtNum(num? v, {int decimals = 2}) {
  if (v == null) return 'null';
  if (v is int) return v.toString();
  return v.toStringAsFixed(decimals);
}

void _usage() {
  stderr.writeln('Usage:');
  stderr.writeln('  dart run example/dart_ass_line_analysis.dart [file.ass] [options]');
  stderr.writeln('');
  stderr.writeln('Options:');
  stderr.writeln('  --dialog N           Process only dialog index N');
  stderr.writeln('  --from N             Start dialog index (inclusive)');
  stderr.writeln('  --to N               End dialog index (exclusive)');
  stderr.writeln('  --max-words N         Limit words printed (default: 12)');
  stderr.writeln('  --max-chars N         Limit chars printed (default: 20)');
  stderr.writeln('  --include-ws          Include whitespace tokens');
  stderr.writeln('  --no-words            Skip words output');
  stderr.writeln('  --no-chars            Skip chars output');
  stderr.writeln('  --no-karaoke          Skip karaoke output');
  stderr.writeln('  --no-breaks           Skip line breaks/segments output');
  stderr.writeln('  --no-text-data        Ignore override tags (use base style only)');
}

int? _readIntOpt(Map<String, String?> opts, String name) {
  final v = opts[name];
  if (v == null) return null;
  return int.tryParse(v);
}

Map<String, String?> _parseOpts(List<String> args, List<String> positionals) {
  final opts = <String, String?>{};
  for (int i = 0; i < args.length; i++) {
    final a = args[i];
    if (!a.startsWith('--')) {
      positionals.add(a);
      continue;
    }
    final eq = a.indexOf('=');
    if (eq != -1) {
      opts[a.substring(2, eq)] = a.substring(eq + 1);
      continue;
    }
    final name = a.substring(2);
    // flags
    const flags = {
      'include-ws',
      'no-words',
      'no-chars',
      'no-karaoke',
      'no-breaks',
      'no-text-data',
      'help',
      'h',
    };
    if (flags.contains(name)) {
      opts[name] = 'true';
      continue;
    }
    // --opt value
    if (i + 1 >= args.length) {
      opts[name] = null;
      continue;
    }
    opts[name] = args[++i];
  }
  return opts;
}

Future<void> main(List<String> args) async {
  final positionals = <String>[];
  final opts = _parseOpts(args, positionals);
  if (opts.containsKey('help') || opts.containsKey('h')) {
    _usage();
    return;
  }

  final filePath = positionals.isEmpty ? 'example/test.ass' : positionals.first;
  final file = File(filePath);
  if (!file.existsSync()) {
    stderr.writeln('File not found: $filePath');
    _usage();
    exitCode = 66;
    return;
  }

  final ass = Ass(filePath: filePath);
  await ass.parse();

  final dialogs = ass.dialogs?.dialogs ?? const <AssDialog>[];
  if (dialogs.isEmpty) {
    stdout.writeln('No dialogs found.');
    return;
  }

  final includeWs = opts.containsKey('include-ws');
  final noWords = opts.containsKey('no-words');
  final noChars = opts.containsKey('no-chars');
  final noKaraoke = opts.containsKey('no-karaoke');
  final noBreaks = opts.containsKey('no-breaks');
  final useTextData = !opts.containsKey('no-text-data');
  final maxWords = _readIntOpt(opts, 'max-words') ?? 12;
  final maxChars = _readIntOpt(opts, 'max-chars') ?? 20;

  int from = _readIntOpt(opts, 'from') ?? 0;
  int to = _readIntOpt(opts, 'to') ?? dialogs.length;
  final dialogOnly = _readIntOpt(opts, 'dialog');
  if (dialogOnly != null) {
    from = dialogOnly;
    to = dialogOnly + 1;
  }
  if (from < 0) from = 0;
  if (to > dialogs.length) to = dialogs.length;
  if (from >= to) {
    stderr.writeln('Invalid range: from=$from to=$to (dialogs=${dialogs.length})');
    exitCode = 64;
    return;
  }

  stdout.writeln('File: $filePath');
  stdout.writeln('Dialogs: ${dialogs.length} (processing $from..${to - 1})');
  stdout.writeln('useTextData: $useTextData');
  stdout.writeln('');

  // Populates `dialog.line` and measures segments (can be expensive for large files).
  await ass.dialogs!.extend(useTextData);

  for (int i = from; i < to; i++) {
    final d = dialogs[i];
    final line = d.line;
    if (line == null) continue;

    stdout.writeln('--- Dialog #$i ${d.startTime} -> ${d.endTime} style=${d.styleName} ---');
    stdout.writeln('ass: ${d.text.getAss()}');

    if (!noBreaks) {
      final breaks = await line.lineBreaks(useTextData: useTextData);
      for (final br in breaks) {
        stdout.writeln(
          'break#${br.index}: "${br.text}" w=${_fmtNum(br.width)} h=${_fmtNum(br.height)} segs=${br.segments.length}',
        );
        for (final seg in br.segments) {
          final st = seg.effectiveStyle;
          stdout.writeln(
            '  seg: "${seg.text}" w=${_fmtNum(seg.width)} h=${_fmtNum(seg.height)} '
            'fn=${st?.fontName} fs=${_fmtNum(st?.fontSize, decimals: 1)} '
            'b=${st?.bold} i=${st?.italic} fscx=${_fmtNum(st?.scaleX, decimals: 1)} fscy=${_fmtNum(st?.scaleY, decimals: 1)}',
          );
        }
      }
    }

    if (!noWords) {
      final words = await line.words(
        useTextData: useTextData,
        includeWhitespace: includeWs,
      );
      stdout.writeln('words: ${words.length}');
      for (final w in words.take(maxWords)) {
        stdout.writeln(
          '  word#${w.index} br=${w.lineIndex} x=${_fmtNum(w.x)} w=${_fmtNum(w.width)} "${w.text}"',
        );
      }
      if (words.length > maxWords) stdout.writeln('  ...');
    }

    if (!noChars) {
      final chars = await line.chars(
        useTextData: useTextData,
        includeWhitespace: includeWs,
      );
      stdout.writeln('chars: ${chars.length}');
      for (final c in chars.take(maxChars)) {
        stdout.writeln(
          '  char#${c.index} br=${c.lineIndex} x=${_fmtNum(c.x)} w=${_fmtNum(c.width)} "${c.text}"',
        );
      }
      if (chars.length > maxChars) stdout.writeln('  ...');
    }

    if (!noKaraoke) {
      final kara = await line.karaoke(useTextData: useTextData);
      int total = 0;
      for (final k in kara) {
        total += k.durationMs ?? 0;
      }
      stdout.writeln('karaoke blocks: ${kara.length} total=${total}ms');
      for (final k in kara) {
        stdout.writeln(
          '  kara ${k.karaokeTag} dur=${k.durationMs}ms '
          '[${k.startOffsetMs}-${k.endOffsetMs}] w=${_fmtNum(k.width)} "${k.text}"',
        );
      }
    }

    stdout.writeln('');
  }
}
