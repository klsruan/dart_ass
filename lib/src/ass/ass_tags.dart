import 'ass_path.dart';

class AssTag {
  final String tag;
  final dynamic value;

  AssTag({required this.tag, required this.value});

  void parse() {

  }

  @override
  String toString() {
    StringBuffer bff = StringBuffer();
    bff.write('\\$tag');
    if (value.isNotEmpty) {
      if (value.contains(',') ||
          value.contains('(') ||
          value.contains(')') ||
          value.contains(' ')) {
        bff.write('($value)');
      } else {
        bff.write(value);
      }
    }
    return bff.toString();
  }
}

class AssTagPosition {
  final double x;
  final double y;

  AssTagPosition(this.x, this.y);

  static AssTagPosition? parse(String value) {
    List<String> parts = value.split(',');
    if (parts.length != 2) return null;
    double? px = double.tryParse(parts[0].trim());
    double? py = double.tryParse(parts[1].trim());
    if (px == null || py == null) return null;
    return AssTagPosition(px, py);
  }

  String getAss() {
    return '\\pos(${toString()})';
  }

  @override
  String toString() {
    return '$x,$y';
  }
}

class AssMove {
  final double x1;
  final double y1;
  final double x2;
  final double y2;
  int? t1;
  int? t2;

  AssMove({
    required this.x1,
    required this.y1,
    required this.x2,
    required this.y2,
    this.t1,
    this.t2,
  });

  static AssMove? parse(String value) {
    List<String> parts = value.split(',');
    if (parts.length != 4 && parts.length != 6) return null;
    double? x1 = double.tryParse(parts[0].trim());
    double? y1 = double.tryParse(parts[1].trim());
    double? x2 = double.tryParse(parts[2].trim());
    double? y2 = double.tryParse(parts[3].trim());
    if (x1 == null || y1 == null || x2 == null || y2 == null) return null;
    if (parts.length == 4) {
      return AssMove(x1: x1, y1: y1, x2: x2, y2: y2);
    } else {
      int? t1 = int.tryParse(parts[4].trim());
      int? t2 = int.tryParse(parts[5].trim());
      if (t1 == null || t2 == null) return null;
      return AssMove(x1: x1, y1: y1, x2: x2, y2: y2, t1: t1, t2: t2);
    }
  }

  String getAss() {
    return '\\move(${toString()})';
  }

  @override
  String toString() {
    if (t1 != null && t2 != null) {
      return '$x1,$y1,$x2,$y2,$t1,$t2';
    }
    return '$x1,$y1,$x2,$y2';
  }
}

class AssTagClipRect {
  double x0;
  double y0;
  double x1;
  double y1;
  bool inverse;

  AssTagClipRect({
    required this.x0,
    required this.y0,
    required this.x1,
    required this.y1,
    this.inverse = false,
  });

  static AssTagClipRect? parse(String value, {bool inverse = false}) {
    List<String> parts = value.split(',');
    if (parts.length != 4) return null;
    double? x0 = double.tryParse(parts[0].trim());
    double? y0 = double.tryParse(parts[1].trim());
    double? x1 = double.tryParse(parts[2].trim());
    double? y1 = double.tryParse(parts[3].trim());
    if (x0 == null || y0 == null || x1 == null || y1 == null) return null;
    return AssTagClipRect(
      x0: x0,
      y0: y0,
      x1: x1,
      y1: y1,
      inverse: inverse,
    );
  }

  String getAss() {
    String tag = inverse ? '\\iclip' : '\\clip';
    return '$tag($x0,$y0,$x1,$y1)';
  }
}

class AssTagClipVect {
  int? scale;
  AssPaths? drawingPaths;
  String drawingCommands;
  bool inverse;

  AssTagClipVect({
    this.scale,
    required this.drawingCommands,
    this.drawingPaths,
    this.inverse = false,
  });

  static AssTagClipVect? parse(String value, {bool inverse = false}) {
    value = value.trim();
    if (value.startsWith('(') && value.endsWith(')')) {
      value = value.substring(1, value.length - 1).trim();
    }

    List<String> parts = value.split(',');
    int? scale;
    String drawingCommands;

    if (parts.length >= 2) {
      scale = int.tryParse(parts[0].trim());
      if (scale != null) {
        drawingCommands = parts.sublist(1).join(',').trim();
      } else {
        drawingCommands = value;
      }
    } else {
      drawingCommands = value;
    }

    if (drawingCommands.isEmpty) return null;
    return AssTagClipVect(
      scale: scale,
      drawingCommands: drawingCommands,
      drawingPaths: AssPaths.parse(drawingCommands),
      inverse: inverse,
    );
  }

  String getAss() {
    String tag = inverse ? '\\iclip' : '\\clip';
    if (scale != null) {
      return '$tag($scale,$drawingCommands)';
    } else {
      return '$tag($drawingCommands)';
    }
  }
}