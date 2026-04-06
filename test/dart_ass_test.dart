import 'dart:ffi';
import 'dart:io';
import 'package:dart_ass/dart_ass.dart';
import 'package:dart_ass/src/font_collector.dart';
import 'package:dart_ass/src/win/windows_gdi_font_collector.dart' as win;
import 'package:test/test.dart';
import 'package:ffi/ffi.dart';

void main() {
  group('dart_ass', () {
    group('ass_color.dart', () {
      test('assColorToRGB parses ASS and raw hex', () {
        expect(assColorToRGB('&H00FFAACC&'), equals([0xFF, 0xAA, 0xCC]));
        expect(assColorToRGB('FFAACC'), equals([0xFF, 0xAA, 0xCC]));
        expect(assColorToRGB('00FFAACC'), equals([0xFF, 0xAA, 0xCC]));
      });

      test('assColorToRGB throws on invalid input', () {
        expect(() => assColorToRGB('FFF'), throwsA(isA<FormatException>()));
        expect(() => assColorToRGB('ZZZZZZ'), throwsA(isA<FormatException>()));
      });

      test('rgbToAssColor validates ranges', () {
        expect(rgbToAssColor(255, 170, 204), equals('FFAACC'));
        expect(() => rgbToAssColor(-1, 0, 0), throwsA(isA<FormatException>()));
        expect(() => rgbToAssColor(0, 256, 0), throwsA(isA<FormatException>()));
      });

      test('AssColor parse/getAss/toString', () {
        final c = AssColor.parse('00FFAACC');
        expect(c.red, 0xFF);
        expect(c.green, 0xAA);
        expect(c.blue, 0xCC);
        expect(c.getAss(), equals('&HFFAACC&'));
        expect(c.toString(), equals('FFAACC'));
      });
    });

    group('ass_alpha.dart', () {
      test('assAlphaToRGB and rgbToAssAlpha', () {
        expect(assAlphaToRGB('00'), equals(0));
        expect(assAlphaToRGB('FF'), equals(255));
        expect(rgbToAssAlpha(255), equals('FF'));
        expect(() => assAlphaToRGB('Z1'), throwsA(isA<FormatException>()));
        expect(() => rgbToAssAlpha(256), throwsA(isA<FormatException>()));
      });

      test('AssAlpha parse/getAss/toString', () {
        final a = AssAlpha.parse('7F');
        expect(a.alpha, 0x7F);
        expect(a.getAss(), equals('&H7F&'));
        expect(a.toString(), equals('7F'));
      });
    });

    group('ass_time.dart', () {
      test('convertMillisecondsToAssTime/convertAssTimeToMilliseconds roundtrip', () {
        expect(convertMillisecondsToAssTime(0), equals('0:00:00.00'));
        expect(convertAssTimeToMilliseconds('0:00:00.00'), equals(0));
        expect(convertAssTimeToMilliseconds('0:00:01.23'), equals(1230));
        expect(() => convertMillisecondsToAssTime(-1), throwsA(isA<FormatException>()));
        expect(() => convertAssTimeToMilliseconds('00:00:00.00'), throwsA(isA<FormatException>()));
      });

      test('AssTime parse/zero/toString', () {
        expect(AssTime.zero().toString(), equals('0:00:00.00'));
        expect(AssTime.parse('0:00:01.00').time, equals(1000));
      });
    });

    group('ass_path.dart', () {
      test('AssPaths.parse/move/toString', () {
        final paths = AssPaths.parse('m 0 0 l 10 0 10 10');
        expect(paths, isNotNull);
        expect(paths!.paths, isNotEmpty);
        final before = paths.toString();
        paths.move(5, -2);
        final after = paths.toString();
        expect(before, isNot(equals(after)));
      });

      test('AssPoint.move updates coordinates', () {
        final p = AssPoint(x: 1, y: 2);
        p.move(2, -1);
        expect(p.x, 3);
        expect(p.y, 1);
      });
    });

    group('ass_tags.dart', () {
      test('AssTag serializes with/without parentheses', () {
        expect(AssTag(tag: 'b', value: '1').toString(), equals(r'\b1'));
        expect(AssTag(tag: 'fn', value: 'My Font').toString(), equals(r'\fn(My Font)'));
        expect(AssTag(tag: 'clip', value: 'm 0 0 l 1 1').toString(), equals(r'\clip(m 0 0 l 1 1)'));
      });

      test('AssTagPosition parse/getAss', () {
        final pos = AssTagPosition.parse('10,20');
        expect(pos, isNotNull);
        expect(pos!.toString(), equals('10.0,20.0'));
        expect(pos.getAss(), equals(r'\pos(10.0,20.0)'));
        expect(AssTagPosition.parse('10'), isNull);
      });

      test('AssMove parse/getAss', () {
        final mv1 = AssMove.parse('0,0,10,20');
        expect(mv1, isNotNull);
        expect(mv1!.getAss(), equals(r'\move(0.0,0.0,10.0,20.0)'));
        final mv2 = AssMove.parse('0,0,10,20,100,200');
        expect(mv2, isNotNull);
        expect(mv2!.getAss(), equals(r'\move(0.0,0.0,10.0,20.0,100,200)'));
        expect(AssMove.parse('0,0,10'), isNull);
      });

      test('Clip rect/vect parse/getAss', () {
        final clip = AssTagClipRect.parse('0,0,100,200');
        expect(clip, isNotNull);
        expect(clip!.getAss(), equals(r'\clip(0.0,0.0,100.0,200.0)'));

        final vect = AssTagClipVect.parse('(1,m 0 0 l 10 0 10 10)');
        expect(vect, isNotNull);
        expect(vect!.drawingPaths, isNotNull);
        expect(vect.getAss(), equals(r'\clip(1,m 0 0 l 10 0 10 10)'));
      });
    });

    group('ass_text.dart', () {
      test('AssText.parse splits tagged segments', () {
        final t = AssText.parse(r'Hello{\b1}World{\i1}!');
        expect(t, isNotNull);
        expect(t!.segments.length, 3);
        expect(t.segments[0].text, 'Hello');
        expect(t.segments[1].overrideTags, isNotNull);
        expect(t.segments[1].text, 'World');
        expect(t.segments[2].overrideTags, isNotNull);
        expect(t.segments[2].text, '!');
      });

      test('AssOverrideTags.parse supports \\fnFontName without parentheses', () {
        final tags = AssOverrideTags.parse(r'{\fnC059\b1}');
        expect(tags, isNotNull);
        expect(tags!.getTagValue('fn'), equals('C059'));
        expect(tags.fontName, equals('C059'));
        expect(tags.bold, isTrue);
      });

      test('AssOverrideTags.parse supports \\rStyleName without parentheses', () {
        final tags = AssOverrideTags.parse(r'{\rAltStyle\fnC059\b1}');
        expect(tags, isNotNull);
        expect(tags!.getTagValue('r'), equals('AltStyle'));
        expect(tags.getTagValue('fn'), equals('C059'));
        expect(tags.bold, isTrue);
      });

      test('AssOverrideTags.parse keeps karaoke + fn sequence intact', () {
        final tags = AssOverrideTags.parse(r'{\k36\fnC059\b1}');
        expect(tags, isNotNull);
        expect(tags!.getTagValue('k'), equals('36'));
        expect(tags.getTagValue('fn'), equals('C059'));
        expect(tags.bold, isTrue);
      });

      test('AssOverrideTags.parse maps \\K to \\kf (karaoke alias)', () {
        final tags = AssOverrideTags.parse(r'{\K20}');
        expect(tags, isNotNull);
        expect(tags!.getTagValue('kf'), equals('20'));
        expect(tags.getTagValue('k'), isNull);
        expect(tags.toString(), contains(r'\kf20'));
      });

      test('AssOverrideTags.parse getters/setters and serialization', () {
        final tags = AssOverrideTags.parse(r'{\b1\i0\fs20\c&H00FFFFFF&\alpha&H80&\pos(10,20)}');
        expect(tags, isNotNull);
        expect(tags!.bold, isTrue);
        expect(tags.italic, isFalse);
        expect(tags.fontSize, 20);
        expect(tags.primaryColor?.toString(), 'FFFFFF');
        expect(tags.mainAlpha?.toString(), '80');
        expect(tags.position?.toString(), '10.0,20.0');

        final tags2 = AssOverrideTags();
        tags2.setTag('b', '0');
        tags2.setTag('i', '0');
        tags2.setTag('u', '0');
        tags2.setTag('fn', 'Old');
        tags2.setTag('bord', '0');

        tags2.bold = true;
        tags2.italic = true;
        tags2.underline = true;
        tags2.fontName = 'Arial';
        tags2.borderSize = 2.5;
        expect(tags2.toString(), contains(r'\b1'));
        expect(tags2.toString(), contains(r'\i1'));
        expect(tags2.toString(), contains(r'\u1'));
        expect(tags2.toString(), contains(r'\fnArial'));
        expect(tags2.toString(), contains(r'\bord2.5'));
        expect(tags2.getAss(), startsWith('{'));
      });

      test('AssTransformation.parse/getAss', () {
        final tr = AssTransformation.parse(r'(0,500,1,\bord2\fs10)');
        expect(tr, isNotNull);
        expect(tr!.t1, 0);
        expect(tr.t2, 500);
        expect(tr.accel, 1);
        expect(tr.styles.borderSize, 2);
        expect(tr.styles.fontSize, 10);
        expect(tr.getAss(), contains(r'\t('));
      });
    });

    group('ass_struct.dart', () {
      test('Header/Garbage/Styles/Dialog toString', () async {
        final header = AssHeader(
          title: 'T',
          wrapStyle: 0,
          scaledBorderAndShadow: 'yes',
          yCbCrMatrix: 'TV.709',
          playResX: 1280,
          playResY: 720,
        );
        expect(header.toString(), contains('Title: T'));

        final garbage = AssGarbage(audioFilePath: 'a.mp3', activeLine: 1);
        expect(garbage.toString(), contains('[Dart Ass Project Garbage]'));

        final style = AssStyle(
          styleName: 'Default',
          fontName: 'Arial',
          fontSize: 48,
          color1: AssColor.parse('FFFFFF'),
          color2: AssColor.parse('0000FF'),
          color3: AssColor.parse('000000'),
          color4: AssColor.parse('000000'),
          alpha1: AssAlpha.parse('00'),
          alpha2: AssAlpha.parse('00'),
          alpha3: AssAlpha.parse('00'),
          alpha4: AssAlpha.parse('00'),
          bold: false,
          italic: false,
          underline: false,
          strikeOut: false,
          scaleX: 100,
          scaleY: 100,
          spacing: 0,
          angle: 0,
          borderStyle: 1,
          outline: 2,
          shadow: 1,
          alignment: 2,
          marginL: 10,
          marginR: 10,
          marginV: 10,
          encoding: 1,
        );
        final styles = AssStyles(styles: [style]);
        expect(styles.getStyleByName('Default'), same(style));
        expect(styles.toString(), contains('[V4+ Styles]'));

        final dialog = AssDialog(
          layer: 0,
          startTime: AssTime(time: 0),
          endTime: AssTime(time: 1000),
          styleName: 'Default',
          name: '',
          marginL: 10,
          marginR: 10,
          marginV: 10,
          effect: '',
          text: AssText(segments: []), // empty: safe extend
          header: header,
          commented: false,
          style: style,
        );
        final dialogs = AssDialogs(dialogs: [dialog]);
        expect(dialogs.toString(), contains('[Events]'));
        await dialogs.extend(false);
        expect(dialog.line, isNotNull);
      });
    });

    group('ass_automation.dart', () {
      test('AssAutomation flow can shift, set tag and remove', () async {
        final ass = convertSrtToAss(
          [
            '1',
            '00:00:01,000 --> 00:00:02,000',
            'Hello',
            '',
            '2',
            '00:00:03,000 --> 00:00:04,000',
            'World',
            '',
          ].join('\n'),
        );

        // Seleciona tudo, muda tempo e seta uma tag no bloco inicial.
        final res1 = await AssAutomation(ass)
            .flow()
            .selectAll()
            .shiftTime(500)
            .ensureLeadingTags()
            .setTag('bord', '3')
            .run();

        expect(res1.dialogsTouched, 2);
        final d0 = ass.dialogs!.dialogs[0];
        expect(d0.startTime.time, 1500);
        expect(d0.text.segments.first.overrideTags, isNotNull);
        expect(d0.text.segments.first.overrideTags!.borderSize, 3);

        // Remove o segundo dialog.
        final res2 = await AssAutomation(ass)
            .flow()
            .selectAll()
            .where((_, i) => i == 1)
            .removeSelected()
            .run();

        expect(res2.dialogsTouched, 0); // remove não conta como "touched"
        expect(ass.dialogs!.dialogs.length, 1);
      });

      test('splitCharsFx supports callback emission', () async {
        final ass = convertSrtToAss(
          [
            '1',
            '00:00:01,000 --> 00:00:02,000',
            'Hi',
            '',
          ].join('\n'),
        );

        final res = await AssAutomation(ass)
            .flow()
            .selectAll()
            .splitCharsFx(
              stepMs: 50,
              durMs: 200,
              commentOriginal: true,
              onCharEnv: (env) {
                final d = env.unit.defaultDialog;
                final tags = env.unit.ensureLeadingTags(d);
                tags.setTag('bord', '2');
                env.emit.emit(d);
              },
            )
            .run();

        expect(res.dialogsTouched, 1); // original commented
        // Original + 2 FX lines
        expect(ass.dialogs!.dialogs.length, 3);
        expect(ass.dialogs!.dialogs[0].commented, isTrue);
        expect(ass.dialogs!.dialogs[1].effect, 'fx');
        expect(ass.dialogs!.dialogs[1].text.getAss(), contains(r'\bord2'));
      });

      test('splitKaraokeFx does not comment non-karaoke lines by default', () async {
        final ass = convertSrtToAss(
          [
            '1',
            '00:00:01,000 --> 00:00:02,000',
            'Hello',
            '',
          ].join('\n'),
        );

        final res = await AssAutomation(ass)
            .flow()
            .selectAll()
            .splitKaraokeFx(commentOriginal: true)
            .run();

        expect(res.dialogsTouched, 0);
        expect(ass.dialogs!.dialogs.length, 1);
        expect(ass.dialogs!.dialogs[0].commented, isFalse);
      });

      test('splitKaraokeFx callback receives optional metrics when dialog.line is set', () async {
        final header = AssHeader(
          title: 'T',
          wrapStyle: 0,
          scaledBorderAndShadow: 'yes',
          yCbCrMatrix: 'TV.709',
          playResX: 1920,
          playResY: 1080,
        );
        final style = AssStyle(
          styleName: 'Default',
          fontName: 'Arial',
          fontSize: 48,
          color1: AssColor.parse('FFFFFF'),
          color2: AssColor.parse('0000FF'),
          color3: AssColor.parse('000000'),
          color4: AssColor.parse('000000'),
          alpha1: AssAlpha.parse('00'),
          alpha2: AssAlpha.parse('00'),
          alpha3: AssAlpha.parse('00'),
          alpha4: AssAlpha.parse('00'),
          bold: false,
          italic: false,
          underline: false,
          strikeOut: false,
          scaleX: 100,
          scaleY: 100,
          spacing: 0,
          angle: 0,
          borderStyle: 1,
          outline: 2,
          shadow: 1,
          alignment: 2,
          marginL: 10,
          marginR: 10,
          marginV: 10,
          encoding: 1,
        );

        final t = AssText.parse(r'{\k10}A{\k20}B')!;
        final dialog = AssDialog(
          layer: 0,
          startTime: AssTime(time: 0),
          endTime: AssTime(time: 1000),
          styleName: style.styleName,
          name: '',
          marginL: 10,
          marginR: 10,
          marginV: 10,
          effect: 'karaoke',
          text: t,
          header: header,
          commented: false,
          style: style,
        );

        // Provide "fake" segment metrics.
        final line = AssLine.parse(t, style)!;
        line.segments[0].width = 10;
        line.segments[0].height = 5;
        line.segments[1].width = 20;
        line.segments[1].height = 5;
        dialog.line = line;

        final ass = Ass(filePath: '');
        ass.header = header;
        ass.styles = AssStyles(styles: [style]);
        ass.dialogs = AssDialogs(dialogs: [dialog]);

        int seen = 0;
        await AssAutomation(ass)
            .flow()
            .selectAll()
            .splitKaraokeFx(
              commentOriginal: false,
              onKaraokeEnv: (env) {
                final unit = env.unit;
                expect(unit.width, isNotNull);
                expect(unit.x, isNotNull);
                if (unit.blockIndex == 0) {
                  expect(unit.width, 10);
                  expect(unit.x, 0);
                }
                if (unit.blockIndex == 1) {
                  expect(unit.width, 20);
                  expect(unit.x, 10);
                }
                seen++;
                env.emit.emit(unit.defaultDialog);
              },
            )
            .run();

        expect(seen, 2);
      });
    });

    group('ass_line.dart (FX helpers)', () {
      AssHeader _header() => AssHeader(
            title: 'T',
            wrapStyle: 0,
            scaledBorderAndShadow: 'yes',
            yCbCrMatrix: 'TV.709',
            playResX: 1920,
            playResY: 1080,
          );

      AssStyle _style() => AssStyle(
            styleName: 'Default',
            fontName: 'Arial',
            fontSize: 48,
            color1: AssColor.parse('FFFFFF'),
            color2: AssColor.parse('0000FF'),
            color3: AssColor.parse('000000'),
            color4: AssColor.parse('000000'),
            alpha1: AssAlpha.parse('00'),
            alpha2: AssAlpha.parse('00'),
            alpha3: AssAlpha.parse('00'),
            alpha4: AssAlpha.parse('00'),
            bold: false,
            italic: false,
            underline: false,
            strikeOut: false,
            scaleX: 100,
            scaleY: 100,
            spacing: 0,
            angle: 0,
            borderStyle: 1,
            outline: 2,
            shadow: 1,
            alignment: 2,
            marginL: 10,
            marginR: 10,
            marginV: 10,
            encoding: 1,
          );

      test('AssDialog.toCharFxDialogs generates one line per char', () {
        final header = _header();
        final style = _style();
        final dialog = AssDialog(
          layer: 1,
          startTime: AssTime(time: 0),
          endTime: AssTime(time: 1000),
          styleName: style.styleName,
          name: '',
          marginL: 10,
          marginR: 10,
          marginV: 10,
          effect: 'karaoke',
          text: AssText.parse(r'{\bord2}Hi')!,
          header: header,
          commented: false,
          style: style,
        );

        final fx = dialog.toCharFxDialogs(stepMs: 50, durMs: 200, commentOriginal: true);
        expect(dialog.commented, isTrue);
        expect(fx.length, 2);
        expect(fx[0].startTime.time, 0);
        expect(fx[0].endTime.time, 200);
        expect(fx[0].effect, 'fx');
        expect(fx[1].startTime.time, 50);
        expect(fx[1].endTime.time, 250);
        // base tags should be kept
        expect(fx[0].text.getAss(), contains(r'{\bord2}'));
      });

      test('AssDialog.toKaraokeFxDialogs uses \\k durations', () {
        final header = _header();
        final style = _style();
        final dialog = AssDialog(
          layer: 1,
          startTime: AssTime(time: 0),
          endTime: AssTime(time: 1000),
          styleName: style.styleName,
          name: '',
          marginL: 10,
          marginR: 10,
          marginV: 10,
          effect: 'karaoke',
          text: AssText.parse(r'{\k10}A{\k20}B')!,
          header: header,
          commented: false,
          style: style,
        );

        final fx = dialog.toKaraokeFxDialogs(commentOriginal: false);
        expect(dialog.commented, isFalse);
        expect(fx.length, 2);
        expect(fx[0].startTime.time, 0);
        expect(fx[0].endTime.time, 100);
        expect(fx[0].text.toString(), 'A');
        expect(fx[1].startTime.time, 100);
        expect(fx[1].endTime.time, 300);
        expect(fx[1].text.toString(), 'B');
        // Karaoke tags should not be carried over by default
        expect(fx[0].text.getAss(), isNot(contains(r'\k')));
      });
    });

    group('util.dart', () {
      test('convertSrtToAss + convertAssToSrt', () {
        final srt = [
          '1',
          '00:00:01,000 --> 00:00:02,500',
          'Hello',
          '',
          '2',
          '00:00:03,000 --> 00:00:04,000',
          'World',
          '',
        ].join('\n');

        final ass = convertSrtToAss(srt, title: 'X', fontName: 'Arial', fontSize: 20);
        expect(ass.header?.title, 'X');
        expect(ass.styles?.styles, isNotEmpty);
        expect(ass.dialogs?.dialogs.length, 2);

        final back = convertAssToSrt(ass);
        expect(back, contains('Hello'));
        expect(back, contains('World'));
        expect(back, contains('00:00:01,000 --> 00:00:02,500'));
      });
    });

    group('Ass parsing/serialization', () {
      test('Ass.parse reads sections and Ass.toFile writes output', () async {
        final dir = await Directory.systemTemp.createTemp('dart_ass_test_');
        addTearDown(() async {
          if (await dir.exists()) await dir.delete(recursive: true);
        });

        final src = File('${dir.path}/in.ass');
        await src.writeAsString('''
[Script Info]
Title: Example
WrapStyle: 0
ScaledBorderAndShadow: yes
YCbCr Matrix: TV.709
PlayResX: 1920
PlayResY: 1080

[Dart Ass Project Garbage]
Audio File: audio.wav
Active Line: 3

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Arial,48,&H00FFFFFF,&H00FFFFFF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,1,2,10,10,10,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:00.00,0:00:01.00,Default,,10,10,10,,Hello
''');

        final ass = Ass(filePath: src.path);
        await ass.parse();
        expect(ass.header, isNotNull);
        expect(ass.header!.title, 'Example');
        expect(ass.garbage?.audioFilePath, 'audio.wav');
        expect(ass.styles?.styles.length, 1);
        expect(ass.dialogs?.dialogs.length, 1);
        expect(ass.toString(), contains('[Script Info]'));

        final out = '${dir.path}/out.ass';
        await ass.toFile(out);
        expect(File(out).existsSync(), isTrue);
        expect(File(out).readAsStringSync(), contains('; Script generated by Dart ASS'));
      });

      test('Ass.parse throws for missing file', () async {
        final ass = Ass(filePath: 'does_not_exist.ass');
        await expectLater(ass.parse(), throwsA(isA<Exception>()));
      });
    });

    group('font_collector.dart', () {
      test('FontCollector.getFontsData returns list on supported platforms', () async {
        if (!(Platform.isWindows || Platform.isLinux || Platform.isAndroid)) {
          return;
        }
        final fonts = await FontCollector.getFontsData();
        expect(fonts, isA<List<SystemFont>>());
      });
    });

    group('ass_font.dart (non-FFI paths)', () {
      test('AssFont methods before init are safe', () {
        final font = AssFont(
          styleName: 'Default',
          fontName: 'Arial',
          fontSize: 48,
          bold: false,
          italic: false,
          underline: false,
          strikeOut: false,
          scaleX: 100,
          scaleY: 100,
          spacing: 0,
        );
        font.setSize(12);
        expect(font.metrics(), isNull);
        expect(font.textExtents('abc'), isNull);
        expect(font.getTextToShape('abc'), isNull);
        expect(font.getTextToAssPaths('abc'), isNull);
        expect(font.getTextToSvg('abc'), isNull);
        font.dispose();
      });
    });

    group('windows_gdi_font_collector.dart (helpers only)', () {
      test('normalizeRegName removes @ and suffix', () {
        expect(win.normalizeRegName('@Arial (TrueType)'), equals('Arial'));
        expect(win.normalizeRegName('  Name  '), equals('Name'));
      });

      test('utf16PtrToString and utf16ArrayToString', () {
        final ptr = 'Hi'.toNativeUtf16();
        addTearDown(() => calloc.free(ptr));
        expect(win.utf16PtrToString(ptr.cast<Uint16>()), equals('Hi'));

        final logFont = calloc.allocate<win.LOGFONTW>(sizeOf<win.LOGFONTW>());
        addTearDown(() => calloc.free(logFont));
        logFont.ref.lfFaceName[0] = 'O'.codeUnitAt(0);
        logFont.ref.lfFaceName[1] = 'K'.codeUnitAt(0);
        logFont.ref.lfFaceName[2] = 0;
        expect(win.utf16ArrayToString(logFont.ref.lfFaceName, 32), equals('OK'));
      });
    });
  });
}
