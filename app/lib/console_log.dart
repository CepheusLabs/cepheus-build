part of 'main.dart';

List<ClLogEntry> _logEntries(
  String output, {
  List<String> lineTimes = const [],
}) {
  final lines = output.split(RegExp(r'\r?\n'));
  var visibleIndex = 0;
  return [
    for (var i = 0; i < lines.length; i++)
      if (lines[i].isNotEmpty)
        ClLogEntry(
          time: _logTimestampForIndex(lineTimes, visibleIndex++),
          tag: _tagFor(lines[i]),
          message: lines[i],
          tone: _toneFor(lines[i]),
        ),
  ];
}

String _logTextForEntries(List<ClLogEntry> entries) {
  return entries
      .map((entry) => '${entry.time} ${entry.tag} ${entry.message}')
      .join('\n');
}

List<DateTime> _syncLogLineTimes(
  String output,
  List<DateTime> current, {
  DateTime? timestamp,
}) {
  final lineCount = output
      .split(RegExp(r'\r?\n'))
      .where((line) => line.isNotEmpty)
      .length;
  if (current.length == lineCount) return current;
  final next = current.take(lineCount).toList();
  while (next.length < lineCount) {
    next.add(timestamp ?? DateTime.now());
  }
  return next;
}

String _logTimestampForIndex(List<String> lineTimes, int index) {
  if (index < 0 || index >= lineTimes.length) return '--:--:--';
  final timestamp = DateTime.tryParse(lineTimes[index]);
  if (timestamp == null) return '--:--:--';
  final local = timestamp.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}

String _tagFor(String line) {
  final lower = line.toLowerCase();
  if (line.startsWith('+') || line.startsWith('bin/')) return 'cmd';
  if (_isErrorLine(line)) return 'error';
  if (_isWarningLine(line)) return 'warn';
  if (lower.startsWith('skip:')) return 'skip';
  if (lower.startsWith('exit code')) return 'exit';
  if (line.startsWith('==>')) return 'target';
  return 'log';
}

String _entryScope(BuildHistoryEntry entry) {
  if ((entry.action == BuildAction.deploy ||
          entry.action == BuildAction.deployPreview) &&
      entry.store.isNotEmpty) {
    return entry.store;
  }
  return entry.targets;
}

ClLogTone _toneFor(String line) {
  final lower = line.toLowerCase();
  if (line.startsWith('+') || line.startsWith('bin/')) return ClLogTone.input;
  if (_isErrorLine(line)) return ClLogTone.danger;
  if (_isWarningLine(line)) return ClLogTone.warning;
  if (lower.startsWith('skip:')) return ClLogTone.muted;
  if (lower == 'exit code 0') return ClLogTone.success;
  if (lower.startsWith('exit code')) return ClLogTone.danger;
  if (line.startsWith('==>')) return ClLogTone.accent;
  return ClLogTone.neutral;
}

bool _isErrorLine(String line) {
  final lower = line.trimLeft().toLowerCase();
  if (lower.startsWith('error:') ||
      lower.startsWith('fatal:') ||
      lower.startsWith('failed:')) {
    return true;
  }
  return RegExp(r'(^|\s)(error|failed|failure):').hasMatch(lower) ||
      lower.contains('command failed');
}

bool _isWarningLine(String line) {
  final lower = line.trimLeft().toLowerCase();
  if (lower.startsWith('warning:') || lower.startsWith('warn:')) return true;
  return RegExp(r'(^|\s)(warning|warn):').hasMatch(lower);
}
