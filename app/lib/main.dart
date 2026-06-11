import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forge/forge.dart';

import 'build_models.dart';
import 'console_logic.dart' as logic;

part 'console_models.dart';
part 'console_data.dart';
part 'console_actions.dart';
part 'console_controls.dart';
part 'console_panels.dart';
part 'console_widgets.dart';
part 'console_log.dart';
part 'console_util.dart';

const _maxHistoryEntries = 250;

/// Caps applied to the *stored* copy of a run's output (never the live view).
const _maxStoredOutputChars = 1000000;
const _maxStoredOutputLines = 20000;

/// Minimum spacing between live-log UI rebuilds while a build streams output.
const _liveRefreshInterval = Duration(milliseconds: 100);

void main() {
  runApp(const CepheusBuildConsoleApp());
}

class CepheusBuildConsoleApp extends StatefulWidget {
  const CepheusBuildConsoleApp({super.key});

  @override
  State<CepheusBuildConsoleApp> createState() => _CepheusBuildConsoleAppState();
}

class _CepheusBuildConsoleAppState extends State<CepheusBuildConsoleApp> {
  ThemeMode _themeMode = ThemeMode.dark;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Cepheus Build',
      debugShowCheckedModeBanner: false,
      themeMode: _themeMode,
      theme: ClThemeData.light(),
      darkTheme: ClThemeData.dark(),
      home: BuildConsoleHome(
        themeMode: _themeMode,
        onThemeModeChanged: (mode) => setState(() => _themeMode = mode),
      ),
    );
  }
}

class BuildConsoleHome extends StatefulWidget {
  const BuildConsoleHome({
    super.key,
    required this.themeMode,
    required this.onThemeModeChanged,
  });

  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeModeChanged;

  @override
  State<BuildConsoleHome> createState() => _BuildConsoleHomeState();
}

class _BuildConsoleHomeState extends State<BuildConsoleHome> {
  late BuildSettings _settings;
  late TextEditingController _repoRootController;
  late TextEditingController _toolkitRootController;
  late TextEditingController _githubRepoController;
  late TextEditingController _githubWorkflowController;
  late TextEditingController _buildrootDirController;

  final ScrollController _historyScrollController = ScrollController();
  final ScrollController _logScrollController = ScrollController();

  List<String> _products = const [];
  List<_RunnerProfileChoice> _runnerProfiles = const [];
  List<_RunnerProfileChoice> _containerProfiles = const [];
  _ProductDescriptor _productDescriptor = _ProductDescriptor.empty('printdeck-app');
  List<BuildHistoryEntry> _history = const [];
  BuildHistoryEntry? _selectedHistory;
  Process? _process;
  BuildAction? _runningAction;
  DateTime? _startedAt;
  String _liveOutput = '';
  List<DateTime> _liveLineTimes = const [];
  String? _message;
  bool _loading = true;
  bool _showLiveOutput = true;
  _LogFilter _logFilter = _LogFilter.all;

  /// Detail from the most recent `describe` invocation failure, surfaced into
  /// [_message] by the loaders so users see which config step broke.
  String? _describeError;

  bool get _isRunning => _process != null;
  bool get _isGitHubMode => _settings.executionMode == ExecutionMode.github;
  bool get _isContainerMode =>
      _settings.executionMode == ExecutionMode.container;
  bool get _isFoundry => _settings.product == 'foundry';
  _StoreDescriptor? get _selectedStore {
    for (final store in _productDescriptor.storeChoices) {
      if (store.name == _settings.store) return store;
    }
    return null;
  }

  List<_RunnerProfileChoice> get _availableRunnerProfiles {
    if (_runnerProfiles.any(
      (profile) => profile.value == _settings.runnerProfile,
    )) {
      return _runnerProfiles;
    }
    return [
      _RunnerProfileChoice(
        value: _settings.runnerProfile,
        label: _settings.runnerProfile,
      ),
      ..._runnerProfiles,
    ];
  }

  String _runnerProfileLabel(String profile) {
    for (final choice in _runnerProfiles) {
      if (choice.value == profile) return choice.label;
    }
    return profile;
  }

  List<_RunnerProfileChoice> get _availableContainerProfiles {
    if (_containerProfiles.any(
      (profile) => profile.value == _settings.containerProfile,
    )) {
      return _containerProfiles;
    }
    return [
      _RunnerProfileChoice(
        value: _settings.containerProfile,
        label: _settings.containerProfile,
      ),
      ..._containerProfiles,
    ];
  }

  File get _historyFile =>
      File(_joinPath(_settings.toolkitRoot, 'history', 'build-history.json'));

  String get _statusLabel {
    if (_isRunning) return 'running ${_runningAction?.label ?? 'command'}';
    if (_selectedHistory != null && !_showLiveOutput) {
      return _selectedHistory!.succeeded ? 'viewing complete' : 'viewing error';
    }
    return _message ?? 'ready';
  }

  /// Forwards to [setState] so same-library extensions on this State can
  /// request a rebuild without tripping the protected-member lint.
  void _setStateSafe(VoidCallback fn) => setState(fn);

  @override
  void initState() {
    super.initState();
    final root = _defaultToolkitRoot();
    _settings = BuildSettings.defaults(toolkitRoot: root);
    _repoRootController = TextEditingController(text: _settings.repoRoot);
    _toolkitRootController = TextEditingController(text: _settings.toolkitRoot);
    _githubRepoController = TextEditingController(
      text: _effectiveGitHubRepo(_settings),
    );
    _githubWorkflowController = TextEditingController(
      text: _settings.githubWorkflow,
    );
    _buildrootDirController = TextEditingController(
      text: _settings.buildrootDir,
    );
    unawaited(_loadSnapshot(root));
  }

  @override
  void dispose() {
    _process?.kill(ProcessSignal.sigterm);
    _repoRootController.dispose();
    _toolkitRootController.dispose();
    _githubRepoController.dispose();
    _githubWorkflowController.dispose();
    _buildrootDirController.dispose();
    _historyScrollController.dispose();
    _logScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final brand = context.brandColors;
    final selected = _selectedHistory;
    return Scaffold(
      backgroundColor: brand.bg,
      body: Column(
        children: [
          ClCommandBar(
            title: 'Cepheus Build',
            subtitle: 'Shared builds, local history',
            actions: [
              ClThemeToggle(
                value: widget.themeMode,
                onChanged: _onThemeToggle,
              ),
            ],
          ),
          Expanded(
            child: _loading
                ? const Center(child: ClLoadingState(label: 'Loading console'))
                : LayoutBuilder(
                    builder: (context, constraints) {
                      return _buildConsoleWorkspace(constraints);
                    },
                  ),
          ),
          ClStatusStrip(
            entries: [
              ClStatusEntry(label: 'status', value: _statusLabel),
              ClStatusEntry(
                label: 'mode',
                value: _settings.executionMode.label,
              ),
              ClStatusEntry(
                label: 'runner',
                value: _runnerProfileLabel(_settings.runnerProfile),
              ),
              ClStatusEntry(label: 'product', value: _settings.product),
              ClStatusEntry(label: 'targets', value: _settings.targets),
              if (_settings.store.isNotEmpty)
                ClStatusEntry(label: 'store', value: _settings.store),
              ClStatusEntry(label: 'history', value: _historyFile.path),
              if (selected != null)
                ClStatusEntry(label: 'selected', value: selected.id),
            ],
          ),
        ],
      ),
    );
  }
}
