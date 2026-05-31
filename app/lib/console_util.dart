part of 'main.dart';

String _defaultToolkitRoot() {
  final starts = <String>[Directory.current.absolute.path];
  starts.add(Platform.resolvedExecutable);
  try {
    starts.add(Platform.script.toFilePath());
  } on UnsupportedError {
    // Non-file script URIs are not useful for local checkout discovery.
  }

  for (final start in starts) {
    final found = _findToolkitRootFrom(start);
    if (found != null) return found;
  }

  return Directory.current.absolute.path;
}

String? _findToolkitRootFrom(String start) {
  var directory = FileSystemEntity.isFileSync(start)
      ? File(start).parent
      : Directory(start);

  for (var i = 0; i < 16; i++) {
    final path = directory.absolute.path;
    if (_isToolkitRoot(path)) return path;
    final parent = directory.parent;
    if (parent.absolute.path == path) return null;
    directory = parent;
  }
  return null;
}

bool _isToolkitRoot(String path) {
  return File(_joinPath(path, 'bin', 'cepheus-build')).existsSync() &&
      Directory(_joinPath(path, 'products')).existsSync();
}

String _joinPath(String first, String second, [String? third, String? fourth]) {
  final parts = [first, second, ?third, ?fourth];
  final separator = Platform.pathSeparator;
  return parts
      .where((part) => part.isNotEmpty)
      .map((part) => part.replaceAll(RegExp(r'[\\/]+$'), ''))
      .join(separator);
}

/// Builds the executable + args used to invoke the CLI, mirroring the platform
/// logic in [_ConsoleActions._commandFor]: on Windows we run
/// `python <script> ...`, elsewhere we exec the script directly.
({String executable, List<String> args}) _cliInvocation(
  String toolkitRoot,
  List<String> cliArgs,
) {
  final script = _cliScriptPath(toolkitRoot);
  if (Platform.isWindows) {
    return (executable: 'python', args: [script, ...cliArgs]);
  }
  return (executable: script, args: cliArgs);
}

/// Absolute path to the `bin/cepheus-build` CLI entry point.
String _cliScriptPath(String toolkitRoot) {
  return _joinPath(toolkitRoot, 'bin', 'cepheus-build');
}

/// Reads a string field from decoded JSON, returning [fallback] when absent.
String _jsonString(Object? value, [String fallback = '']) {
  if (value == null) return fallback;
  final text = value.toString();
  return text.isEmpty ? fallback : text;
}

/// Reads a list-of-strings field from decoded JSON, dropping empties.
List<String> _jsonStringList(Object? value) {
  if (value is! List) return const [];
  return value
      .map((entry) => entry?.toString() ?? '')
      .where((entry) => entry.isNotEmpty)
      .toList();
}

/// Returns the first non-empty line of [value] (e.g. a process's stderr),
/// trimmed, or null when there is nothing useful to report.
String? _firstLine(Object? value) {
  final text = value?.toString().trim() ?? '';
  if (text.isEmpty) return null;
  final newline = text.indexOf('\n');
  return newline == -1 ? text : text.substring(0, newline).trim();
}

String _displayCommand(String executable, List<String> args) {
  return [executable, ...args].map(_quoteForDisplay).join(' ');
}

String _effectiveGitHubRepo(BuildSettings settings) {
  return settings.githubRepo.trim();
}

String _quoteForDisplay(String value) {
  if (value.isEmpty) return "''";
  if (!RegExp(r'\s').hasMatch(value)) return value;
  return "'${value.replaceAll("'", r"'\''")}'";
}

/// Caps a stored run log (see [logic.truncateOutput]). The LIVE buffer is never
/// truncated — only the persisted `output` copy passes through here.
String _truncateOutput(String output) => logic.truncateOutput(
  output,
  maxLines: _maxStoredOutputLines,
  maxChars: _maxStoredOutputChars,
);

/// Masks secret-looking values before a command is persisted to history.
/// Delegates to [logic.redactSecrets].
String _redactSecrets(String command) => logic.redactSecrets(command);

/// Maps a persisted theme name to a [ThemeMode], defaulting to dark.
ThemeMode _themeModeFromString(String value) {
  switch (value) {
    case 'light':
      return ThemeMode.light;
    case 'system':
      return ThemeMode.system;
    case 'dark':
    default:
      return ThemeMode.dark;
  }
}

String _themeModeToString(ThemeMode mode) {
  switch (mode) {
    case ThemeMode.light:
      return 'light';
    case ThemeMode.system:
      return 'system';
    case ThemeMode.dark:
      return 'dark';
  }
}

String _timeLabel(DateTime value) {
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
}
