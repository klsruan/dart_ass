/// Parsing and manipulation of ASS vector drawing commands (`\p` / clip vectors).
///
/// ASS drawings are sequences like `m 0 0 l 10 0 10 10 ...`.
/// This module parses them into points/paths and supports moving them.
bool _isWhitespaceCodeUnit(int cu) => cu <= 32;

bool _isAlphaCodeUnit(int cu) {
  // A-Z or a-z
  return (cu >= 65 && cu <= 90) || (cu >= 97 && cu <= 122);
}

AssPoint? getPoint(String p, {required int refIndex}) {
  int index = refIndex;

  while (index < p.length && _isWhitespaceCodeUnit(p.codeUnitAt(index))) {
    index++;
  }

  String xStr = '';
  while (index < p.length && !_isWhitespaceCodeUnit(p.codeUnitAt(index))) {
    xStr += p[index];
    index++;
  }
  if (xStr.isEmpty) {
    return null;
  }

  double? x = double.tryParse(xStr);
  if (x == null) {
    return null;
  }

  while (index < p.length && _isWhitespaceCodeUnit(p.codeUnitAt(index))) {
    index++;
  }

  String yStr = '';
  while (index < p.length && !_isWhitespaceCodeUnit(p.codeUnitAt(index))) {
    yStr += p[index];
    index++;
  }
  if (yStr.isEmpty) {
    return null;
  }

  double? y = double.tryParse(yStr);
  if (y == null) {
    return null;
  }

  AssPoint point = AssPoint(x: x, y: y);
  point.index = index;
  return point;
}

int addManyPoints(String p, AssPath currentPath, String cmd, int startIndex, int pointCount) {
  int index = startIndex;
  int addedPoints = 0;
  while (true) {
    AssPoint? point = getPoint(p, refIndex: index);
    if (point == null) {
      break;
    }

    index = point.index;
    point.code = cmd;
    currentPath.path.add(point);
    addedPoints++;

    if (pointCount > 0 && addedPoints >= pointCount) {
      break;
    }

    while (index < p.length && _isWhitespaceCodeUnit(p.codeUnitAt(index))) {
      index++;
    }

    if (index < p.length && _isAlphaCodeUnit(p.codeUnitAt(index))) {
      break;
    }
  }
  currentPath.lastIndex = index;
  return addedPoints;
}

bool addNPoints(String p, AssPath currentPath, String cmd, int startIndex, int n) {
  int index = startIndex;
  for (int i = 0; i < n; i++) {
    AssPoint? point = getPoint(p, refIndex: index);
    if (point == null) {
      return false;
    }
    index = point.index;
    point.code = cmd;
    currentPath.path.add(point);
  }
  currentPath.lastIndex = index;
  return true;
}

int addRepeatedTriples(String p, AssPath currentPath, String cmd, int startIndex) {
  int index = startIndex;
  int addedPoints = 0;
  while (true) {
    while (index < p.length && _isWhitespaceCodeUnit(p.codeUnitAt(index))) {
      index++;
    }
    if (index >= p.length) break;
    if (_isAlphaCodeUnit(p.codeUnitAt(index))) break;

    final ok = addNPoints(p, currentPath, cmd, index, 3);
    if (!ok) break;
    addedPoints += 3;
    index = currentPath.lastIndex;
  }
  currentPath.lastIndex = index;
  return addedPoints;
}

class AssPaths {
  List<AssPath> paths;

  AssPaths({required this.paths});

  AssPaths clone() => AssPaths(paths: paths.map((p) => p.clone()).toList(growable: true));

  /// Reallocates this shape according to an ASS alignment (`\an`) and an optional target point.
  ///
  /// This is a pragmatic helper useful for automation:
  /// - when [reverse] is false (default), it moves the shape so its alignment anchor
  ///   (based on its bounding box) becomes `(x,y)`.
  /// - when [reverse] is true, it performs the opposite move (useful when undoing a
  ///   previous reallocation).
  ///
  /// This mirrors the conceptual behavior of many ASS tooling scripts, but this
  /// implementation is intentionally lightweight (bounding-box based).
  void reallocate(
    int an, {
    bool reverse = false,
    double x = 0,
    double y = 0,
    AssBoundingBox? box,
  }) {
    final bb = box ?? boundingBox();
    final w = bb.width;
    final h = bb.height;

    final double tx = switch (an) {
      1 || 4 || 7 => 0.0,
      2 || 5 || 8 => 0.5,
      3 || 6 || 9 => 1.0,
      _ => 0.5,
    };
    final double ty = switch (an) {
      7 || 8 || 9 => 0.0,
      4 || 5 || 6 => 0.5,
      1 || 2 || 3 => 1.0,
      _ => 1.0,
    };

    if (!reverse) {
      move(x - (w * tx), y - (h * ty));
    } else {
      move(-x + (w * tx), -y + (h * ty));
    }
  }

  static AssPaths? parse(String drawingCommands) {
    String p = drawingCommands;
    int index = 0;
    AssPath? currentPath;
    List<AssPath> paths = [];
    int points = 0;
    bool mSeen = false;
    AssPoint? splineStart;

    while (index < p.length) {
      while (index < p.length && _isWhitespaceCodeUnit(p.codeUnitAt(index))) {
        index++;
      }

      if (index >= p.length) {
        break;
      }

      String cmd = p[index].toLowerCase();
      index++;

      while (index < p.length && _isWhitespaceCodeUnit(p.codeUnitAt(index))) {
        index++;
      }

      switch (cmd) {
        case 'm':
          mSeen = true;
          AssPoint? point = getPoint(p, refIndex: index);
          if (point == null) {
            continue;
          }
          index = point.index;
          currentPath = AssPath(path: []);
          currentPath.path.add(AssPoint(x: point.x, y: point.y, code: 'm'));
          paths.add(currentPath);
          points = 1;
          points += addManyPoints(p, currentPath, 'l', index, 0);
          index = currentPath.lastIndex;
          break;
        case 'n':
          if (!mSeen) {
            return null;
          }
          AssPoint? pointN = getPoint(p, refIndex: index);
          if (pointN == null) {
            continue;
          }
          index = pointN.index;
          currentPath = AssPath(path: []);
          currentPath.path.add(AssPoint(x: pointN.x, y: pointN.y, code: 'n'));
          paths.add(currentPath);
          points = 1;
          points += addManyPoints(p, currentPath, 'l', index, 0);
          index = currentPath.lastIndex;
          break;
        case 'l':
          if (currentPath == null) {
            continue;
          }
          points += addManyPoints(p, currentPath, 'l', index, 0);
          index = currentPath.lastIndex;
          break;
        case 'b':
          if (currentPath == null) {
            continue;
          }
          // `b` consumes points in groups of 3 and may repeat without repeating the command.
          points += addRepeatedTriples(p, currentPath, 'b', index);
          index = currentPath.lastIndex;
          break;
        case 's':
          if (currentPath == null) {
            continue;
          }
          splineStart = currentPath.path.isNotEmpty ? currentPath.path.last : null;
          final added = addRepeatedTriples(p, currentPath, 's', index);
          if (added == 0) {
            splineStart = null;
            break;
          }
          points += added;
          index = currentPath.lastIndex;
          continue;
        case 'p':
          if (points < 3 || currentPath == null) {
            continue;
          }
          points += addManyPoints(p, currentPath, 'p', index, 0);
          index = currentPath.lastIndex;
          break;
        case 'c':
          if (splineStart == null || currentPath == null) {
            continue;
          }
          int splineStartIndex = currentPath.path.indexOf(splineStart);
          if (splineStartIndex >= 0 && splineStartIndex + 2 < currentPath.path.length) {
            for (int i = 0; i < 3; i++) {
              AssPoint pnt = currentPath.path[splineStartIndex + i];
              currentPath.path.add(AssPoint(x: pnt.x, y: pnt.y, code: 'p'));
            }
          }
          splineStart = null;
          break;
        default:
          break;
      }
    }

    return AssPaths(paths: paths);
  }

  void move(double? px, double? py) {
    for (AssPath path in paths) {
      path.move(px, py);
    }
  }

  /// Applies a point-mapping function to all points.
  ///
  /// The mapper receives the current `(x,y)` and returns the new `(x,y)`.
  void mapPoints((double, double) Function(double x, double y) mapper) {
    for (final path in paths) {
      for (final p in path.path) {
        final (nx, ny) = mapper(p.x, p.y);
        p.x = nx;
        p.y = ny;
      }
    }
  }

  /// Returns the bounding box of all points.
  ///
  /// If there are no points, returns a zero-size box at (0,0).
  AssBoundingBox boundingBox() {
    double? minX;
    double? minY;
    double? maxX;
    double? maxY;

    for (final path in paths) {
      for (final p in path.path) {
        minX = minX == null ? p.x : (p.x < minX ? p.x : minX);
        minY = minY == null ? p.y : (p.y < minY ? p.y : minY);
        maxX = maxX == null ? p.x : (p.x > maxX ? p.x : maxX);
        maxY = maxY == null ? p.y : (p.y > maxY ? p.y : maxY);
      }
    }

    return AssBoundingBox(
      left: minX ?? 0,
      top: minY ?? 0,
      right: maxX ?? 0,
      bottom: maxY ?? 0,
    );
  }

  @override
  String toString() {
    StringBuffer bff = StringBuffer();
    for (AssPath path in paths) {
      bff.write(path.toString());
    }
    return bff.toString();
  }
}

class AssBoundingBox {
  final double left;
  final double top;
  final double right;
  final double bottom;

  const AssBoundingBox({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  double get width => right - left;
  double get height => bottom - top;

  @override
  String toString() => 'AssBoundingBox(left=$left, top=$top, right=$right, bottom=$bottom)';
}

class AssPath {
  List<AssPoint> path;
  int lastIndex = 0;

  AssPath({required this.path});

  AssPath clone() => AssPath(path: path.map((p) => p.clone()).toList(growable: true));

  void move(double? px, double? py) {
    for (AssPoint point in path) {
      point.move(px, py);
    }
  }

  /// Returns whether this contour is oriented clockwise.
  ///
  /// This follows the same sign convention used in many ASS shape toolchains.
  bool isClockWise() {
    if (path.length < 3) return false;
    double sum = 0;
    for (int i = 0; i < path.length; i++) {
      final curr = path[i];
      final next = path[(i + 1) % path.length];
      sum += (next.x - curr.x) * (next.y + curr.y);
    }
    return sum < 0;
  }

  /// Ensures the contour is closed by repeating the first point at the end (as a line).
  void close() {
    if (path.length < 2) return;
    final first = path.first;
    final last = path.last;
    if (first.x == last.x && first.y == last.y) return;
    path.add(AssPoint(x: first.x, y: first.y, code: 'l'));
  }

  @override
  String toString() {
    StringBuffer bff = StringBuffer();
    String? lastCmd;
    for (AssPoint point in path) {
      final cmd = point.code;
      if (cmd != null && cmd != lastCmd) {
        bff.write('$cmd ');
        lastCmd = cmd;
      }
      bff.write('${point.x} ${point.y} ');
    }
    return bff.toString();
  }
}

class AssPoint {
  double x;
  double y;
  String? code;
  int index = 0;

  AssPoint({required this.x, required this.y, this.code});

  AssPoint clone() => AssPoint(x: x, y: y, code: code);

  void move(double? px, double? py) {
    x += px ?? 0;
    y += py ?? 0;
  }

  @override
  String toString() {
    if (code != null) {
      return '$code $x $y';
    }
    return '$x $y';
  }
}
