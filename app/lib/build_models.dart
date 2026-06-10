import 'dart:convert';

enum BuildAction {
  plan('Plan', 'plan'),
  doctor('Check Deps', 'doctor'),
  installDeps('Install Deps', 'install-deps'),
  dryRun('Dry Run', 'build'),
  build('Build', 'build'),
  matrix('Matrix', 'ci-matrix'),
  deployPreview('Deploy Preview', 'deploy'),
  deploy('Deploy', 'deploy');

  const BuildAction(this.label, this.command);

  final String label;
  final String command;
}

enum ExecutionMode {
  local('Local', 'local'),
  github('GitHub', 'github');

  const ExecutionMode(this.label, this.value);

  final String label;
  final String value;

  static ExecutionMode fromValue(String value) {
    return ExecutionMode.values.firstWhere(
      (mode) => mode.value == value,
      orElse: () => ExecutionMode.local,
    );
  }
}

class BuildSettings {
  const BuildSettings({
    required this.toolkitRoot,
    required this.product,
    required this.targets,
    required this.executionMode,
    required this.runnerProfile,
    required this.buildMode,
    required this.repoRoot,
    required this.githubRepo,
    required this.githubWorkflow,
    required this.buildrootDir,
    required this.setupBuildrootDeps,
    required this.skipUnsupported,
    required this.keepGoing,
    required this.store,
    required this.themeMode,
  });

  factory BuildSettings.defaults({required String toolkitRoot}) {
    return BuildSettings(
      toolkitRoot: toolkitRoot,
      product: 'printdeck-app',
      targets: 'all',
      executionMode: ExecutionMode.local,
      runnerProfile: 'github-hosted',
      buildMode: 'release',
      repoRoot: '',
      githubRepo: '',
      githubWorkflow: 'shared-build.yml',
      buildrootDir: '',
      setupBuildrootDeps: true,
      skipUnsupported: true,
      keepGoing: true,
      store: '',
      themeMode: 'dark',
    );
  }

  factory BuildSettings.fromJson(
    Map<String, dynamic> json, {
    required String fallbackToolkitRoot,
  }) {
    return BuildSettings(
      toolkitRoot: _string(json['toolkitRoot'], fallbackToolkitRoot),
      product: _string(json['product'], 'printdeck-app'),
      targets: _string(json['targets'], 'all'),
      executionMode: ExecutionMode.fromValue(
        _string(json['executionMode'], ExecutionMode.local.value),
      ),
      runnerProfile: _string(json['runnerProfile'], 'github-hosted'),
      buildMode: _string(json['buildMode'], 'release'),
      repoRoot: _string(json['repoRoot'], ''),
      githubRepo: _string(json['githubRepo'], ''),
      githubWorkflow: _string(json['githubWorkflow'], 'shared-build.yml'),
      buildrootDir: _string(json['buildrootDir'], ''),
      setupBuildrootDeps: json['setupBuildrootDeps'] is bool
          ? json['setupBuildrootDeps'] as bool
          : true,
      skipUnsupported: json['skipUnsupported'] is bool
          ? json['skipUnsupported'] as bool
          : true,
      keepGoing: json['keepGoing'] is bool ? json['keepGoing'] as bool : true,
      store: _string(json['store'], ''),
      themeMode: _themeModeName(json['themeMode']),
    );
  }

  final String toolkitRoot;
  final String product;
  final String targets;
  final ExecutionMode executionMode;
  final String runnerProfile;
  final String buildMode;
  final String repoRoot;
  final String githubRepo;
  final String githubWorkflow;
  final String buildrootDir;
  final bool setupBuildrootDeps;
  final bool skipUnsupported;
  final bool keepGoing;
  final String store;

  /// Persisted Material theme selection: `'light'`, `'dark'`, or `'system'`.
  final String themeMode;

  BuildSettings copyWith({
    String? toolkitRoot,
    String? product,
    String? targets,
    ExecutionMode? executionMode,
    String? runnerProfile,
    String? buildMode,
    String? repoRoot,
    String? githubRepo,
    String? githubWorkflow,
    String? buildrootDir,
    bool? setupBuildrootDeps,
    bool? skipUnsupported,
    bool? keepGoing,
    String? store,
    String? themeMode,
  }) {
    return BuildSettings(
      toolkitRoot: toolkitRoot ?? this.toolkitRoot,
      product: product ?? this.product,
      targets: targets ?? this.targets,
      executionMode: executionMode ?? this.executionMode,
      runnerProfile: runnerProfile ?? this.runnerProfile,
      buildMode: buildMode ?? this.buildMode,
      repoRoot: repoRoot ?? this.repoRoot,
      githubRepo: githubRepo ?? this.githubRepo,
      githubWorkflow: githubWorkflow ?? this.githubWorkflow,
      buildrootDir: buildrootDir ?? this.buildrootDir,
      setupBuildrootDeps: setupBuildrootDeps ?? this.setupBuildrootDeps,
      skipUnsupported: skipUnsupported ?? this.skipUnsupported,
      keepGoing: keepGoing ?? this.keepGoing,
      store: store ?? this.store,
      themeMode: themeMode ?? this.themeMode,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'toolkitRoot': toolkitRoot,
      'product': product,
      'targets': targets,
      'executionMode': executionMode.value,
      'runnerProfile': runnerProfile,
      'buildMode': buildMode,
      'repoRoot': repoRoot,
      'githubRepo': githubRepo,
      'githubWorkflow': githubWorkflow,
      'buildrootDir': buildrootDir,
      'setupBuildrootDeps': setupBuildrootDeps,
      'skipUnsupported': skipUnsupported,
      'keepGoing': keepGoing,
      'store': store,
      'themeMode': themeMode,
    };
  }
}

class BuildHistoryEntry {
  const BuildHistoryEntry({
    required this.id,
    required this.action,
    required this.product,
    required this.targets,
    required this.executionMode,
    required this.runnerProfile,
    required this.buildMode,
    required this.repoRoot,
    required this.githubRepo,
    required this.store,
    required this.command,
    required this.startedAt,
    required this.durationMs,
    required this.exitCode,
    required this.output,
    required this.outputLineTimes,
  });

  factory BuildHistoryEntry.fromJson(Map<String, dynamic> json) {
    return BuildHistoryEntry(
      id: _string(json['id'], ''),
      action: BuildAction.values.firstWhere(
        (action) => action.name == json['action'],
        orElse: () => BuildAction.plan,
      ),
      product: _string(json['product'], ''),
      targets: _string(json['targets'], ''),
      executionMode: ExecutionMode.fromValue(
        _string(json['executionMode'], ExecutionMode.local.value),
      ),
      runnerProfile: _string(json['runnerProfile'], 'github-hosted'),
      buildMode: _string(json['buildMode'], 'release'),
      repoRoot: _string(json['repoRoot'], ''),
      githubRepo: _string(json['githubRepo'], ''),
      store: _string(json['store'], ''),
      command: _string(json['command'], ''),
      startedAt:
          DateTime.tryParse(_string(json['startedAt'], '')) ??
          DateTime.fromMillisecondsSinceEpoch(0),
      durationMs: json['durationMs'] is num
          ? (json['durationMs'] as num).round()
          : 0,
      exitCode: json['exitCode'] is num ? (json['exitCode'] as num).round() : 1,
      output: _string(json['output'], ''),
      outputLineTimes: json['outputLineTimes'] is List
          ? (json['outputLineTimes'] as List)
                .map((value) => value.toString())
                .toList()
          : const [],
    );
  }

  final String id;
  final BuildAction action;
  final String product;
  final String targets;
  final ExecutionMode executionMode;
  final String runnerProfile;
  final String buildMode;
  final String repoRoot;
  final String githubRepo;
  final String store;
  final String command;
  final DateTime startedAt;
  final int durationMs;
  final int exitCode;
  final String output;
  final List<String> outputLineTimes;

  bool get succeeded => exitCode == 0;

  String get status => succeeded ? 'complete' : 'error';

  String get durationLabel {
    final duration = Duration(milliseconds: durationMs);
    if (duration.inMinutes > 0) {
      final seconds = duration.inSeconds
          .remainder(60)
          .toString()
          .padLeft(2, '0');
      return '${duration.inMinutes}m ${seconds}s';
    }
    return '${duration.inSeconds}.${duration.inMilliseconds.remainder(1000).toString().padLeft(3, '0')}s';
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'action': action.name,
      'product': product,
      'targets': targets,
      'executionMode': executionMode.value,
      'runnerProfile': runnerProfile,
      'buildMode': buildMode,
      'repoRoot': repoRoot,
      'githubRepo': githubRepo,
      'store': store,
      'command': command,
      'startedAt': startedAt.toIso8601String(),
      'durationMs': durationMs,
      'exitCode': exitCode,
      'output': output,
      'outputLineTimes': outputLineTimes,
    };
  }
}

class BuildHistorySnapshot {
  const BuildHistorySnapshot({required this.settings, required this.entries});

  factory BuildHistorySnapshot.fromJson(
    Map<String, dynamic> json, {
    required String fallbackToolkitRoot,
  }) {
    final rawEntries = json['entries'];
    return BuildHistorySnapshot(
      settings: BuildSettings.fromJson(
        json['settings'] is Map<String, dynamic>
            ? json['settings'] as Map<String, dynamic>
            : const {},
        fallbackToolkitRoot: fallbackToolkitRoot,
      ),
      entries: rawEntries is List
          ? rawEntries
                .whereType<Map>()
                .map((entry) => BuildHistoryEntry.fromJson(entry.cast()))
                .toList()
          : const [],
    );
  }

  final BuildSettings settings;
  final List<BuildHistoryEntry> entries;

  String toPrettyJson() {
    return const JsonEncoder.withIndent('  ').convert({
      'settings': settings.toJson(),
      'entries': entries.map((entry) => entry.toJson()).toList(),
    });
  }
}

String _string(Object? value, String fallback) {
  if (value == null) return fallback;
  final text = value.toString();
  return text.isEmpty ? fallback : text;
}

/// Normalizes a persisted theme value to one of the supported names,
/// defaulting to `'dark'` to match the app's historical default.
String _themeModeName(Object? value) {
  final text = _string(value, 'dark');
  return const {'light', 'dark', 'system'}.contains(text) ? text : 'dark';
}
