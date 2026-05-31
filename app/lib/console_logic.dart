/// Pure, side-effect-free console logic, extracted so it can be unit-tested
/// directly (the `_BuildConsoleHomeState` part files are private and cannot be
/// imported from tests). Everything here is deterministic: no Flutter, no I/O,
/// no clocks. The GUI part files delegate to these functions.
library;

import 'build_models.dart';

// ---------------------------------------------------------------------------
// CLI argument construction
// ---------------------------------------------------------------------------

/// Splits a free-text targets string (e.g. "macos web") into CLI args,
/// defaulting to `["all"]` when empty.
List<String> targetArgs(String targets) {
  final raw = targets.trim();
  if (raw.isEmpty) return ['all'];
  return raw.split(RegExp(r'\s+')).where((part) => part.isNotEmpty).toList();
}

/// Positional store-lane arg for deploy/preview. Callers gate this on a
/// selected, enabled store; asserts rather than inventing a placeholder.
String storeArg(BuildSettings settings) {
  final store = settings.store.trim();
  assert(store.isNotEmpty, 'deploy invoked without a selected store');
  return store;
}

/// The `--execution-mode ...` block shared by dry-run and build actions.
List<String> buildModeArgs(BuildSettings settings, {required bool dryRun}) {
  final args = <String>['--execution-mode', settings.executionMode.value];
  if (dryRun) args.add('--dry-run');

  if (settings.executionMode == ExecutionMode.github) {
    args.addAll(['--runner-profile', settings.runnerProfile]);
    final repo = settings.githubRepo.trim();
    if (repo.isNotEmpty) args.addAll(['--github-repo', repo]);
    final workflow = settings.githubWorkflow.trim();
    if (workflow.isNotEmpty) args.addAll(['--github-workflow', workflow]);
    if (settings.product == 'foundry') {
      args.add(
        settings.setupBuildrootDeps
            ? '--setup-buildroot-deps'
            : '--no-setup-buildroot-deps',
      );
      final buildrootDir = settings.buildrootDir.trim();
      if (buildrootDir.isNotEmpty) {
        args.addAll(['--buildroot-dir', buildrootDir]);
      }
    }
    return args;
  }

  args.addAll(['--mode', settings.buildMode]);
  if (!dryRun) args.add('--install-missing-deps');
  if (settings.skipUnsupported) args.add('--skip-unsupported');
  args.add(settings.keepGoing ? '--keep-going' : '--no-keep-going');
  if (settings.product == 'foundry') {
    final buildrootDir = settings.buildrootDir.trim();
    if (buildrootDir.isNotEmpty) {
      args.addAll(['--buildroot-dir', buildrootDir]);
    }
  }
  return args;
}

/// Builds the full CLI argument vector (everything after the executable) for a
/// given action + settings. Platform-specific executable wrapping and display
/// formatting stay in the widget layer; this is the testable core.
List<String> cliArgsFor(BuildSettings settings, BuildAction action) {
  final args = <String>[
    action.command,
    '-p',
    settings.product,
    if (settings.repoRoot.trim().isNotEmpty) ...[
      '--repo-root',
      settings.repoRoot.trim(),
    ],
  ];

  switch (action) {
    case BuildAction.plan:
    case BuildAction.doctor:
      args.addAll(targetArgs(settings.targets));
    case BuildAction.installDeps:
      if (settings.skipUnsupported) args.add('--skip-unsupported');
      args.addAll(targetArgs(settings.targets));
    case BuildAction.matrix:
      args.addAll([
        '--runner-profile',
        settings.runnerProfile,
        '--pretty',
        ...targetArgs(settings.targets),
      ]);
    case BuildAction.dryRun:
      args.addAll(buildModeArgs(settings, dryRun: true));
      args.addAll(targetArgs(settings.targets));
    case BuildAction.build:
      args.addAll(buildModeArgs(settings, dryRun: false));
      args.addAll(targetArgs(settings.targets));
    case BuildAction.deployPreview:
      args.add(storeArg(settings));
      args.add('--dry-run');
    case BuildAction.deploy:
      args.add(storeArg(settings));
  }
  return args;
}

// ---------------------------------------------------------------------------
// Secret redaction (applied before a command is persisted to history)
// ---------------------------------------------------------------------------

/// Masks secret-looking values in a command string before it is persisted to
/// history. Env-var *references* (e.g. `$GOOGLE_PLAY_SERVICE_ACCOUNT_JSON`)
/// are left intact — only inline literals are redacted. Examples:
///   `--token abc...(>=20 chars)`            -> `--token ***`
///   `SERVICE_ACCOUNT_KEY={"type":"..."}`    -> `SERVICE_ACCOUNT_KEY=***`
///   `deploy google_play $GP_KEY_JSON`       -> unchanged
String redactSecrets(String command) {
  final sensitive = RegExp(
    r'(token|secret|key|password|service-account)',
    caseSensitive: false,
  );

  bool looksInline(String value) {
    final bare = stripQuotes(value);
    if (bare.startsWith(r'$')) return false; // env-var reference
    return bare.startsWith('{') || bare.length >= 20;
  }

  bool looksSecretBlob(String value) {
    final bare = stripQuotes(value);
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

String stripQuotes(String value) {
  if (value.length >= 2) {
    final first = value[0];
    final last = value[value.length - 1];
    if ((first == "'" && last == "'") || (first == '"' && last == '"')) {
      return value.substring(1, value.length - 1);
    }
  }
  return value;
}

// ---------------------------------------------------------------------------
// Stored-output truncation
// ---------------------------------------------------------------------------

/// Caps a stored run log so a single runaway build cannot bloat the history
/// file. Keeps the last [maxLines] lines and at most [maxChars] characters
/// (the tail, where failures live), prefixing a marker when anything was
/// dropped. The live buffer is never truncated — only the persisted copy.
String truncateOutput(
  String output, {
  required int maxLines,
  required int maxChars,
}) {
  final lines = output.split('\n');
  final overLines = lines.length > maxLines;
  final overChars = output.length > maxChars;
  if (!overLines && !overChars) return output;

  var kept = overLines ? lines.sublist(lines.length - maxLines) : lines;
  var text = kept.join('\n');
  if (text.length > maxChars) {
    text = text.substring(text.length - maxChars);
    // The char trim may have clipped the first retained line.
    kept = text.split('\n');
  }
  final marker =
      '… [output truncated: showing last ${kept.length} of ${lines.length} lines] …';
  return '$marker\n$text';
}

// ---------------------------------------------------------------------------
// History → CSV export
// ---------------------------------------------------------------------------

/// Renders build history as CSV (Excel-friendly CRLF rows) for reporting.
String historyToCsv(List<BuildHistoryEntry> entries) {
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
        csvField(entry.id),
        csvField(entry.startedAt.toIso8601String()),
        csvField(entry.product),
        csvField(entry.action.label),
        csvField(entry.targets),
        csvField(entry.executionMode.value),
        csvField(entry.runnerProfile),
        csvField(entry.buildMode),
        csvField(entry.store),
        csvField(entry.exitCode),
        csvField(entry.status),
        csvField(entry.durationMs),
        csvField(entry.command),
      ].join(','),
    );
  }
  return '${rows.join('\r\n')}\r\n';
}

String csvField(Object? value) {
  final text = value?.toString() ?? '';
  if (text.contains(RegExp(r'[",\r\n]'))) {
    return '"${text.replaceAll('"', '""')}"';
  }
  return text;
}

/// Compact filesystem-safe timestamp, e.g. `20260530-142233` (local time).
String compactTimestamp(DateTime value) {
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${local.year}${two(local.month)}${two(local.day)}'
      '-${two(local.hour)}${two(local.minute)}${two(local.second)}';
}
