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

/// Caps a stored run log so a single runaway build cannot bloat the history
/// file. Keeps the last [_maxStoredOutputLines] lines and at most
/// [_maxStoredOutputChars] characters (the tail, where failures live),
/// prefixing a marker when anything was dropped. The LIVE buffer is never
/// truncated — only the persisted `output` copy passes through here.
String _truncateOutput(String output) {
  final lines = output.split('\n');
  final overLines = lines.length > _maxStoredOutputLines;
  final overChars = output.length > _maxStoredOutputChars;
  if (!overLines && !overChars) return output;

  var kept = overLines
      ? lines.sublist(lines.length - _maxStoredOutputLines)
      : lines;
  var text = kept.join('\n');
  if (text.length > _maxStoredOutputChars) {
    text = text.substring(text.length - _maxStoredOutputChars);
    // The char trim may have clipped the first retained line.
    kept = text.split('\n');
  }
  final marker =
      '… [output truncated: showing last ${kept.length} of ${lines.length} lines] …';
  return '$marker\n$text';
}

/// Masks secret-looking values in a command string before it is persisted to
/// history. Env-var *references* (e.g. `$GOOGLE_PLAY_SERVICE_ACCOUNT_JSON`)
/// are left intact — only inline literals are redacted. Examples:
///   `--token abc...(>=20 chars)`            -> `--token ***`
///   `SERVICE_ACCOUNT_KEY={"type":"..."}`    -> `SERVICE_ACCOUNT_KEY=***`
///   `deploy google_play $GP_KEY_JSON`       -> unchanged
String _redactSecrets(String command) {
  final sensitive = RegExp(
    r'(token|secret|key|password|service-account)',
    caseSensitive: false,
  );

  bool looksInline(String value) {
    final bare = _stripQuotes(value);
    if (bare.startsWith(r'$')) return false; // env-var reference
    return bare.startsWith('{') || bare.length >= 20;
  }

  bool looksSecretBlob(String value) {
    final bare = _stripQuotes(value);
    if (bare.startsWith(r'$')) return false;
    // No '/': avoids masking filesystem paths and `owner/repo` specs. Inline
    // secrets that do contain '/' are still caught via sensitive flag/KEY=...
    return RegExp(r'^[A-Za-z0-9+=_-]{20,}$').hasMatch(bare);
  }

  final tokens = command.split(' ');
  final result = <String>[];
  String? prevFlag;
  for (final token in tokens) {
    if (token.isEmpty) {
      result.add(token);
      continue;
    }
    final eq = token.indexOf('=');
    if (token.startsWith('--')) {
      if (eq > 0) {
        final key = token.substring(0, eq);
        final value = token.substring(eq + 1);
        result.add(
          sensitive.hasMatch(key) && looksInline(value) ? '$key=***' : token,
        );
        prevFlag = null;
      } else {
        result.add(token);
        prevFlag = token;
      }
      continue;
    }
    if (prevFlag != null && sensitive.hasMatch(prevFlag) && looksInline(token)) {
      result.add('***');
      prevFlag = null;
      continue;
    }
    prevFlag = null;
    if (eq > 0 && !token.startsWith('-')) {
      final key = token.substring(0, eq);
      final value = token.substring(eq + 1);
      if (sensitive.hasMatch(key) && looksInline(value)) {
        result.add('$key=***');
        continue;
      }
    }
    if (looksSecretBlob(token)) {
      result.add('***');
      continue;
    }
    result.add(token);
  }
  return result.join(' ');
}

String _stripQuotes(String value) {
  if (value.length >= 2) {
    final first = value[0];
    final last = value[value.length - 1];
    if ((first == "'" && last == "'") || (first == '"' && last == '"')) {
      return value.substring(1, value.length - 1);
    }
  }
  return value;
}

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

/// Renders build history as CSV (Excel-friendly CRLF rows) for reporting.
String _historyToCsv(List<BuildHistoryEntry> entries) {
  const header = [
    'id',
    'started_at',
    'product',
    'action',
    'targets',
    'execution_mode',
    'runner_profile',
    'build_mode',
    'store',
    'exit_code',
    'status',
    'duration_ms',
    'command',
  ];
  final rows = <String>[header.join(',')];
  for (final entry in entries) {
    rows.add(
      [
        _csvField(entry.id),
        _csvField(entry.startedAt.toIso8601String()),
        _csvField(entry.product),
        _csvField(entry.action.label),
        _csvField(entry.targets),
        _csvField(entry.executionMode.value),
        _csvField(entry.runnerProfile),
        _csvField(entry.buildMode),
        _csvField(entry.store),
        _csvField(entry.exitCode),
        _csvField(entry.status),
        _csvField(entry.durationMs),
        _csvField(entry.command),
      ].join(','),
    );
  }
  return '${rows.join('\r\n')}\r\n';
}

String _csvField(Object? value) {
  final text = value?.toString() ?? '';
  if (text.contains(RegExp(r'[",\r\n]'))) {
    return '"${text.replaceAll('"', '""')}"';
  }
  return text;
}

/// Compact filesystem-safe timestamp, e.g. `20260530-142233`.
String _compactTimestamp(DateTime value) {
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${local.year}${two(local.month)}${two(local.day)}'
      '-${two(local.hour)}${two(local.minute)}${two(local.second)}';
}

String _timeLabel(DateTime value) {
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
}
