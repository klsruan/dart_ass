AssPoint? getPoint(String p, {required int refIndex}) {
  int index = refIndex;

  while (index < p.length && p[index].trim().isEmpty) {
    index++;
  }

  String xStr = '';
  while (index < p.length && p[index].trim().isNotEmpty && p[index] != ' ') {
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

  while (index < p.length && p[index].trim().isEmpty) {
    index++;
  }

  String yStr = '';
  while (index < p.length && p[index].trim().isNotEmpty && p[index] != ' ') {
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

    while (index < p.length && p[index].trim().isEmpty) {
      index++;
    }

    if (index < p.length && RegExp(r'[a-z]').hasMatch(p[index])) {
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

class AssPaths {
  List<AssPath> paths;

  AssPaths({required this.paths});

  static AssPaths? parse(String drawingCommands) {
    String p = drawingCommands;
    int index = 0;
    AssPath? currentPath;
    List<AssPath> paths = [];
    int points = 0;
    bool mSeen = false;
    AssPoint? splineStart;

    while (index < p.length) {
      while (index < p.length && p[index].trim().isEmpty) {
        index++;
      }

      if (index >= p.length) {
        break;
      }

      String cmd = p[index];
      index++;

      while (index < p.length && p[index].trim().isEmpty) {
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
          points += addManyPoints(p, currentPath, 'b', index, 3);
          index = currentPath.lastIndex;
          break;
        case 's':
          if (currentPath == null) {
            continue;
          }
          splineStart = currentPath.path.isNotEmpty ? currentPath.path.last : null;
          bool success = addNPoints(p, currentPath, 's', index, 3);
          if (!success) {
            splineStart = null;
            break;
          }
          points += 3;
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

  @override
  String toString() {
    StringBuffer bff = StringBuffer();
    for (AssPath path in paths) {
      bff.write(path.toString());
    }
    return bff.toString();
  }
}

class AssPath {
  List<AssPoint> path;
  int lastIndex = 0;

  AssPath({required this.path});

  void move(double? px, double? py) {
    for (AssPoint point in path) {
      point.move(px, py);
    }
  }

  @override
  String toString() {
    StringBuffer bff = StringBuffer();
    for (AssPoint point in path) {
      if (point.code != null) {
        bff.write('${point.code} ');
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