String convertMillisecondsToAssTime(int ms) {
  if (ms < 0) {
    throw FormatException("The millisecond value must be non-negative.");
  }
  int hours = ms ~/ 3600000 % 10;
  int minutes = (ms % 3600000) ~/ 60000;
  int seconds = (ms % 60000) ~/ 1000;
  int hundredths = (ms % 1000) ~/ 10;
  return "$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}.${hundredths.toString().padLeft(2, '0')}";
}

int convertAssTimeToMilliseconds(String time) {
  final regex = RegExp(r"^(\d):(\d{2}):(\d{2})\.(\d{2})$");
  if (!regex.hasMatch(time)) {
    throw FormatException("The time format should be H:MM:SS.ss");
  }
  var matches = regex.firstMatch(time);
  if (matches == null) {
    throw FormatException("The time format should be H:MM:SS.ss");
  }
  int hours = int.parse(matches.group(1)!);
  int minutes = int.parse(matches.group(2)!);
  int seconds = int.parse(matches.group(3)!);
  int hundredths = int.parse(matches.group(4)!);
  return hours * 3600000 + minutes * 60000 + seconds * 1000 + hundredths * 10;
}

class AssTime {
  int? time;

  AssTime({this.time});

  factory AssTime.parse(String assTime) {
    return AssTime(time: convertAssTimeToMilliseconds(assTime));
  }

  static AssTime zero() {
    return AssTime(time: 0);
  }

  @override
  String toString() {
    StringBuffer bff = StringBuffer();
    if (time != null) {
      bff.write(convertMillisecondsToAssTime(time!));
    }
    return bff.toString();
  }
}