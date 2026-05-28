import 'dart:convert';

enum BuildAction {
  plan('Plan', 'plan'),
  dryRun('Dry Run', 'build'),
  build('Build', 'build'),
  matrix('Matrix', 'ci-matrix');

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
  });

  factory BuildSettings.defaults({required String toolkitRoot}) {
    return BuildSettings(
      toolkitRoot: toolkitRoot,
      product: 'printdeck',
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
    );
  }

  factory BuildSettings.fromJson(
    Map<String, dynamic> json, {
    required String fallbackToolkitRoot,
  }) {
    return BuildSettings(
      toolkitRoot: _string(json['toolkitRoot'], fallbackToolkitRoot),
      product: _string(json['product'], 'printdeck'),
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
    );
  }

  Map<String, dynamic> toJson() {
    return {
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
    required this.command,
    required this.startedAt,
    required this.durationMs,
    required this.exitCode,
    required this.output,
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
      command: _string(json['command'], ''),
      startedAt:
          DateTime.tryParse(_string(json['startedAt'], '')) ??
          DateTime.fromMillisecondsSinceEpoch(0),
      durationMs: json['durationMs'] is num
          ? (json['durationMs'] as num).round()
          : 0,
      exitCode: json['exitCode'] is num ? (json['exitCode'] as num).round() : 1,
      output: _string(json['output'], ''),
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
  final String command;
  final DateTime startedAt;
  final int durationMs;
  final int exitCode;
  final String output;

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
      'command': command,
      'startedAt': startedAt.toIso8601String(),
      'durationMs': durationMs,
      'exitCode': exitCode,
      'output': output,
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
