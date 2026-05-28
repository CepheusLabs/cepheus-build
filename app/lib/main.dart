import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forge/forge.dart';

import 'build_models.dart';

const _maxHistoryEntries = 250;

class _ProductDescriptor {
  const _ProductDescriptor({
    required this.product,
    required this.targetChoices,
    required this.storeChoices,
    this.githubRepo = '',
    this.githubWorkflow = '',
  });

  factory _ProductDescriptor.empty(String product) {
    return _ProductDescriptor(
      product: product,
      targetChoices: const ['all'],
      storeChoices: const [],
    );
  }

  final String product;
  final List<String> targetChoices;
  final List<_StoreDescriptor> storeChoices;
  final String githubRepo;
  final String githubWorkflow;
}

class _StoreDescriptor {
  const _StoreDescriptor({
    required this.name,
    required this.enabled,
    required this.hosts,
    required this.requiredEnv,
  });

  final String name;
  final bool enabled;
  final List<String> hosts;
  final List<String> requiredEnv;

  String get label => enabled ? name : '$name (disabled)';
}

class _RunnerProfileChoice {
  const _RunnerProfileChoice({required this.value, required this.label});

  final String value;
  final String label;
}

enum _LogFilter {
  all('All'),
  issues('Warnings + errors'),
  warnings('Warnings'),
  errors('Errors'),
  skips('Skips'),
  commands('Commands'),
  targets('Targets'),
  exits('Exits'),
  output('Output');

  const _LogFilter(this.label);

  final String label;

  bool accepts(ClLogEntry entry) {
    return switch (this) {
      _LogFilter.all => true,
      _LogFilter.issues =>
        entry.tone == ClLogTone.warning || entry.tone == ClLogTone.danger,
      _LogFilter.warnings => entry.tone == ClLogTone.warning,
      _LogFilter.errors => entry.tone == ClLogTone.danger,
      _LogFilter.skips => entry.tag == 'skip',
      _LogFilter.commands => entry.tag == 'cmd',
      _LogFilter.targets => entry.tag == 'target',
      _LogFilter.exits => entry.tag == 'exit',
      _LogFilter.output => entry.tag == 'log',
    };
  }
}

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
  _ProductDescriptor _productDescriptor = _ProductDescriptor.empty('printdeck');
  List<BuildHistoryEntry> _history = const [];
  BuildHistoryEntry? _selectedHistory;
  Process? _process;
  BuildAction? _runningAction;
  DateTime? _startedAt;
  String _liveOutput = '';
  String? _message;
  bool _loading = true;
  bool _showLiveOutput = true;
  _LogFilter _logFilter = _LogFilter.all;
  bool _showRawLog = false;

  bool get _isRunning => _process != null;
  bool get _isGitHubMode => _settings.executionMode == ExecutionMode.github;
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

  File get _historyFile =>
      File(_joinPath(_settings.toolkitRoot, 'history', 'build-history.json'));

  String get _statusLabel {
    if (_isRunning) return 'running ${_runningAction?.label ?? 'command'}';
    if (_selectedHistory != null && !_showLiveOutput) {
      return _selectedHistory!.succeeded ? 'viewing complete' : 'viewing error';
    }
    return _message ?? 'ready';
  }

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

  Future<void> _loadSnapshot(String toolkitRoot) async {
    final historyFile = File(
      _joinPath(toolkitRoot, 'history', 'build-history.json'),
    );
    var settings = BuildSettings.defaults(toolkitRoot: toolkitRoot);
    var entries = <BuildHistoryEntry>[];
    var message = _message;

    try {
      if (await historyFile.exists()) {
        final decoded =
            jsonDecode(await historyFile.readAsString())
                as Map<String, dynamic>;
        final snapshot = BuildHistorySnapshot.fromJson(
          decoded,
          fallbackToolkitRoot: toolkitRoot,
        );
        settings = snapshot.settings.copyWith(toolkitRoot: toolkitRoot);
        entries = snapshot.entries;
      }
    } on Object catch (error) {
      message = 'History file could not be read: $error';
    }

    var products = <String>[];
    try {
      products = await _loadProducts(toolkitRoot);
    } on Object catch (error) {
      message = 'Products could not be loaded: $error';
    }
    if (products.isNotEmpty && !products.contains(settings.product)) {
      settings = settings.copyWith(product: products.first);
    }
    var runnerProfiles = <_RunnerProfileChoice>[];
    try {
      runnerProfiles = await _loadRunnerProfiles(toolkitRoot);
    } on Object catch (error) {
      message = 'Runner profiles could not be loaded: $error';
    }
    if (runnerProfiles.isNotEmpty &&
        !runnerProfiles.any(
          (profile) => profile.value == settings.runnerProfile,
        )) {
      settings = settings.copyWith(runnerProfile: runnerProfiles.first.value);
    }
    var descriptor = _ProductDescriptor.empty(settings.product);
    try {
      descriptor = await _loadProductDescriptor(toolkitRoot, settings.product);
    } on Object catch (error) {
      message = 'Product config could not be loaded: $error';
    }
    settings = _settingsForDescriptor(settings, descriptor);

    if (!mounted) return;
    setState(() {
      _settings = settings;
      _history = entries;
      _selectedHistory = entries.isEmpty ? null : entries.first;
      _products = products;
      _runnerProfiles = runnerProfiles;
      _productDescriptor = descriptor;
      _loading = false;
      _repoRootController.text = settings.repoRoot;
      _toolkitRootController.text = settings.toolkitRoot;
      _githubRepoController.text = _effectiveGitHubRepo(settings);
      _githubWorkflowController.text = settings.githubWorkflow;
      _buildrootDirController.text = settings.buildrootDir;
      _message = message;
    });

    try {
      if (!await historyFile.exists()) {
        await _saveSnapshot();
      }
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _message = 'History file could not be saved: $error');
    }
  }

  Future<List<String>> _loadProducts(String toolkitRoot) async {
    final productsDir = Directory(_joinPath(toolkitRoot, 'products'));
    if (!await productsDir.exists()) {
      return const [];
    }

    final products = <String>[];
    await for (final entity in productsDir.list()) {
      if (entity is! File || !entity.path.endsWith('.toml')) continue;
      products.add(_basename(entity.path).replaceFirst(RegExp(r'\.toml$'), ''));
    }
    products.sort();
    return products;
  }

  Future<_ProductDescriptor> _loadProductDescriptor(
    String toolkitRoot,
    String product,
  ) async {
    final file = File(_joinPath(toolkitRoot, 'products', '$product.toml'));
    if (!await file.exists()) return _ProductDescriptor.empty(product);

    final groups = <String>[];
    final targets = <String>[];
    final stores = <_StoreDescriptor>[];
    var githubRepo = '';
    var githubWorkflow = '';
    var section = '';
    String? currentStore;
    var storeEnabled = true;
    var storeHosts = <String>[];
    var storeRequiredEnv = <String>[];

    void flushStore() {
      final name = currentStore;
      if (name == null) return;
      stores.add(
        _StoreDescriptor(
          name: name,
          enabled: storeEnabled,
          hosts: storeHosts,
          requiredEnv: storeRequiredEnv,
        ),
      );
      currentStore = null;
      storeEnabled = true;
      storeHosts = <String>[];
      storeRequiredEnv = <String>[];
    }

    for (final rawLine in await file.readAsLines()) {
      final line = _stripTomlComment(rawLine).trim();
      if (line.isEmpty) continue;

      final sectionName = _tomlSection(line);
      if (sectionName != null) {
        flushStore();
        section = sectionName;
        final targetName = _targetSectionName(sectionName);
        if (targetName != null && !targets.contains(targetName)) {
          targets.add(targetName);
        }
        currentStore = _storeSectionName(sectionName);
        continue;
      }

      if (section == 'groups') {
        final groupName = _tomlAssignmentName(line);
        if (groupName != null && !groups.contains(groupName)) {
          groups.add(groupName);
        }
      } else if (section == 'github') {
        githubRepo = _tomlStringValue(line, 'repository') ?? githubRepo;
        githubWorkflow = _tomlStringValue(line, 'workflow') ?? githubWorkflow;
      } else if (currentStore != null) {
        storeEnabled = _tomlBoolValue(line, 'enabled') ?? storeEnabled;
        storeHosts = _tomlArrayValue(line, 'hosts') ?? storeHosts;
        storeRequiredEnv =
            _tomlArrayValue(line, 'required_env') ?? storeRequiredEnv;
      }
    }
    flushStore();

    final choices = _uniqueStrings([
      ...groups,
      ...targets,
      if (groups.isEmpty && targets.isEmpty) 'all',
    ]);
    return _ProductDescriptor(
      product: product,
      targetChoices: choices,
      storeChoices: stores,
      githubRepo: githubRepo,
      githubWorkflow: githubWorkflow,
    );
  }

  Future<List<_RunnerProfileChoice>> _loadRunnerProfiles(
    String toolkitRoot,
  ) async {
    final file = File(_joinPath(toolkitRoot, 'build.toml'));
    if (!await file.exists()) return const [];

    final profiles = <_RunnerProfileChoice>[];
    var section = '';
    var currentProfile = '';
    var currentLabel = '';

    void flush() {
      if (currentProfile.isEmpty) return;
      profiles.add(
        _RunnerProfileChoice(
          value: currentProfile,
          label: currentLabel.isEmpty ? currentProfile : currentLabel,
        ),
      );
      currentProfile = '';
      currentLabel = '';
    }

    for (final rawLine in await file.readAsLines()) {
      final line = _stripTomlComment(rawLine).trim();
      if (line.isEmpty) continue;
      final sectionName = _tomlSection(line);
      if (sectionName != null) {
        flush();
        section = sectionName;
        const prefix = 'github.runner_profiles.';
        if (sectionName.startsWith(prefix)) {
          currentProfile = sectionName.substring(prefix.length);
        }
        continue;
      }
      if (section.startsWith('github.runner_profiles.') &&
          currentProfile.isNotEmpty) {
        currentLabel = _tomlStringValue(line, 'label') ?? currentLabel;
      }
    }
    flush();
    return profiles;
  }

  BuildSettings _settingsForDescriptor(
    BuildSettings settings,
    _ProductDescriptor descriptor,
  ) {
    final targetChoices = descriptor.targetChoices;
    var targets = settings.targets.trim();
    if (!targetChoices.contains(targets)) {
      targets = targetChoices.contains('all') ? 'all' : targetChoices.first;
    }
    var githubRepo = settings.githubRepo;
    if (githubRepo.trim().isEmpty) {
      githubRepo = descriptor.githubRepo;
    }
    var githubWorkflow = settings.githubWorkflow;
    if (githubWorkflow.trim().isEmpty) {
      githubWorkflow = descriptor.githubWorkflow;
    }
    final stores = descriptor.storeChoices;
    var store = settings.store.trim();
    if (stores.isEmpty) {
      store = '';
    } else if (!stores.any((choice) => choice.name == store)) {
      final enabledStores = stores.where((choice) => choice.enabled);
      store = (enabledStores.isEmpty ? stores.first : enabledStores.first).name;
    }
    return settings.copyWith(
      targets: targets,
      githubRepo: githubRepo,
      githubWorkflow: githubWorkflow,
      store: store,
    );
  }

  Future<void> _saveSnapshot() async {
    final snapshot = BuildHistorySnapshot(
      settings: _settings,
      entries: _history,
    );
    await _historyFile.parent.create(recursive: true);
    await _historyFile.writeAsString('${snapshot.toPrettyJson()}\n');
  }

  void _updateSettings(BuildSettings settings, {bool save = true}) {
    setState(() => _settings = settings);
    if (save) _persistSnapshot();
  }

  void _persistSnapshot() {
    unawaited(
      _saveSnapshot().catchError((Object error) {
        if (!mounted) return;
        setState(() => _message = 'History file could not be saved: $error');
      }),
    );
  }

  Future<void> _applyToolkitRoot() async {
    final root = _toolkitRootController.text.trim();
    if (root.isEmpty) return;
    setState(() {
      _loading = true;
      _liveOutput = '';
      _showLiveOutput = true;
    });
    await _loadSnapshot(root);
  }

  Future<void> _refreshProducts() async {
    List<String> products;
    List<_RunnerProfileChoice> runnerProfiles;
    try {
      products = await _loadProducts(_settings.toolkitRoot);
      runnerProfiles = await _loadRunnerProfiles(_settings.toolkitRoot);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _message = 'Build config could not be loaded: $error');
      return;
    }
    var settings = _settings;
    if (!mounted) return;
    setState(() {
      _products = products;
      _runnerProfiles = runnerProfiles;
      if (products.isNotEmpty && !products.contains(_settings.product)) {
        settings = _settings.copyWith(product: products.first);
      }
      if (runnerProfiles.isNotEmpty &&
          !runnerProfiles.any(
            (profile) => profile.value == settings.runnerProfile,
          )) {
        settings = settings.copyWith(runnerProfile: runnerProfiles.first.value);
      }
      _settings = settings;
      _message = 'Products refreshed';
    });
    await _setProduct(settings.product, save: false);
    _persistSnapshot();
  }

  Future<void> _setProduct(String product, {bool save = true}) async {
    final previousDescriptor = _productDescriptor;
    final currentRepo = _settings.githubRepo.trim();
    final shouldFollowProduct =
        currentRepo.isEmpty || currentRepo == previousDescriptor.githubRepo;
    final currentWorkflow = _settings.githubWorkflow.trim();
    final shouldFollowWorkflow =
        currentWorkflow.isEmpty ||
        currentWorkflow == previousDescriptor.githubWorkflow;
    var descriptor = _ProductDescriptor.empty(product);
    try {
      descriptor = await _loadProductDescriptor(_settings.toolkitRoot, product);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _message = 'Product config could not be loaded: $error');
    }
    var nextSettings = _settings.copyWith(
      product: product,
      githubRepo: shouldFollowProduct
          ? descriptor.githubRepo
          : _settings.githubRepo,
      githubWorkflow: shouldFollowWorkflow
          ? descriptor.githubWorkflow
          : _settings.githubWorkflow,
    );
    nextSettings = _settingsForDescriptor(nextSettings, descriptor);
    if (!mounted) return;
    setState(() {
      _productDescriptor = descriptor;
      _settings = nextSettings;
      _githubRepoController.text = _effectiveGitHubRepo(nextSettings);
      _githubWorkflowController.text = nextSettings.githubWorkflow;
    });
    if (save) _persistSnapshot();
  }

  void _setTargets(String targets) {
    _updateSettings(_settings.copyWith(targets: targets));
  }

  void _setExecutionMode(ExecutionMode mode) {
    _updateSettings(_settings.copyWith(executionMode: mode));
  }

  void _setRunnerProfile(String profile) {
    _updateSettings(_settings.copyWith(runnerProfile: profile));
  }

  void _setBuildMode(String mode) {
    _updateSettings(_settings.copyWith(buildMode: mode));
  }

  void _setStore(String store) {
    _updateSettings(_settings.copyWith(store: store));
  }

  Future<void> _run(BuildAction action) async {
    if (_isRunning) return;

    final command = _commandFor(action);
    final script = File(command.executable);
    if (command.validateExecutablePath &&
        !Platform.isWindows &&
        !await script.exists()) {
      setState(() {
        _message = 'Build script not found';
        _liveOutput = 'Missing ${command.executable}\n';
        _showLiveOutput = true;
      });
      return;
    }

    final startedAt = DateTime.now();
    final buffer = StringBuffer()..writeln(command.display);

    setState(() {
      _runningAction = action;
      _startedAt = startedAt;
      _liveOutput = buffer.toString();
      _showLiveOutput = true;
      _message = null;
    });

    try {
      final process = await Process.start(
        command.executable,
        command.args,
        workingDirectory: command.workingDirectory,
        runInShell: Platform.isWindows,
      );
      setState(() => _process = process);

      void append(String chunk) {
        buffer.write(chunk);
        if (!mounted) return;
        setState(() {
          _liveOutput = buffer.toString();
        });
      }

      final stdoutDone = process.stdout
          .transform(utf8.decoder)
          .listen(append)
          .asFuture<void>();
      final stderrDone = process.stderr
          .transform(utf8.decoder)
          .listen(append)
          .asFuture<void>();
      final exitCode = await process.exitCode;
      await Future.wait([stdoutDone, stderrDone]);

      final duration = DateTime.now().difference(startedAt);
      buffer.writeln();
      buffer.writeln('exit code $exitCode');

      final entry = BuildHistoryEntry(
        id: startedAt.microsecondsSinceEpoch.toString(),
        action: action,
        product: _settings.product,
        targets: _settings.targets,
        executionMode: _settings.executionMode,
        runnerProfile: _settings.runnerProfile,
        buildMode: _settings.buildMode,
        repoRoot: _settings.repoRoot,
        githubRepo: _effectiveGitHubRepo(_settings),
        store: _settings.store,
        command: command.display,
        startedAt: startedAt,
        durationMs: duration.inMilliseconds,
        exitCode: exitCode,
        output: _truncateOutput(buffer.toString()),
      );

      if (!mounted) return;
      setState(() {
        _process = null;
        _runningAction = null;
        _startedAt = null;
        _liveOutput = entry.output;
        _selectedHistory = entry;
        _history = [entry, ..._history].take(_maxHistoryEntries).toList();
        _message = exitCode == 0 ? 'Run completed' : 'Run failed';
      });
      try {
        await _saveSnapshot();
      } on Object catch (error) {
        if (!mounted) return;
        setState(
          () => _message = 'Run finished, history could not be saved: $error',
        );
      }
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _process = null;
        _runningAction = null;
        _startedAt = null;
        _message = 'Run could not start';
        _liveOutput = '${buffer}error: $error\n';
      });
    }
  }

  void _cancelRun() {
    final process = _process;
    if (process == null) return;
    setState(() {
      _message = 'Cancel requested';
      _liveOutput = '$_liveOutput\ncancel requested\n';
    });
    unawaited(_terminateProcessTree(process.pid));
  }

  Future<void> _terminateProcessTree(int pid) async {
    try {
      if (Platform.isWindows) {
        await Process.run('taskkill', ['/PID', '$pid', '/T', '/F']);
        return;
      }

      var descendants = await _collectDescendantPids(pid);
      await _signalPids([...descendants, pid], 'TERM');
      await Future<void>.delayed(const Duration(seconds: 2));

      if (!await _isPidAlive(pid)) return;
      descendants = await _collectDescendantPids(pid);
      await _signalPids([...descendants, pid], 'KILL');
      if (!mounted) return;
      setState(() {
        _message = 'Cancel forced';
        _liveOutput = '$_liveOutput\ncancel forced\n';
      });
    } on Object catch (error) {
      if (!Platform.isWindows) {
        await Process.run('kill', ['-KILL', '$pid']);
      }
      if (!mounted) return;
      setState(() {
        _message = 'Cancel signal failed';
        _liveOutput = '$_liveOutput\ncancel signal failed: $error\n';
      });
    }
  }

  Future<List<int>> _collectDescendantPids(int pid) async {
    final result = await Process.run('pgrep', ['-P', '$pid']);
    if (result.exitCode != 0) return const [];
    final direct = result.stdout
        .toString()
        .split(RegExp(r'\s+'))
        .map(int.tryParse)
        .whereType<int>()
        .toList();
    final descendants = <int>[];
    for (final child in direct) {
      descendants.addAll(await _collectDescendantPids(child));
      descendants.add(child);
    }
    return descendants;
  }

  Future<void> _signalPids(List<int> pids, String signal) async {
    final seen = <int>{};
    for (final pid in pids) {
      if (!seen.add(pid)) continue;
      await Process.run('kill', ['-$signal', '$pid']);
    }
  }

  Future<bool> _isPidAlive(int pid) async {
    final result = await Process.run('kill', ['-0', '$pid']);
    return result.exitCode == 0;
  }

  Future<void> _copyLogText(String text, String label) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    setState(() => _message = '$label copied');
  }

  Future<void> _clearHistory() async {
    setState(() {
      _history = const [];
      _selectedHistory = null;
      _message = 'History cleared';
    });
    try {
      await _saveSnapshot();
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _message = 'History file could not be saved: $error');
    }
  }

  _CommandSpec _commandFor(BuildAction action) {
    final args = <String>[
      action.command,
      '-p',
      _settings.product,
      if (_settings.repoRoot.trim().isNotEmpty) ...[
        '--repo-root',
        _settings.repoRoot.trim(),
      ],
    ];

    switch (action) {
      case BuildAction.plan:
        args.addAll(_targetArgs);
      case BuildAction.doctor:
        args.addAll(_targetArgs);
      case BuildAction.installDeps:
        if (_settings.skipUnsupported) args.add('--skip-unsupported');
        args.addAll(_targetArgs);
      case BuildAction.matrix:
        args.addAll([
          '--runner-profile',
          _settings.runnerProfile,
          '--pretty',
          ..._targetArgs,
        ]);
      case BuildAction.dryRun:
        args.addAll(_buildCommandArgs(dryRun: true));
        args.addAll(_targetArgs);
      case BuildAction.build:
        args.addAll(_buildCommandArgs(dryRun: false));
        args.addAll(_targetArgs);
      case BuildAction.deployPreview:
        if (_settings.store.trim().isEmpty) {
          args.add('__missing_store__');
        } else {
          args.add(_settings.store.trim());
        }
        args.add('--dry-run');
      case BuildAction.deploy:
        if (_settings.store.trim().isEmpty) {
          args.add('__missing_store__');
        } else {
          args.add(_settings.store.trim());
        }
    }

    final script = _joinPath(_settings.toolkitRoot, 'bin', 'cepheus-build');
    if (Platform.isWindows) {
      return _CommandSpec(
        executable: 'python',
        args: [script, ...args],
        workingDirectory: _settings.toolkitRoot,
        display: _displayCommand('python', ['bin\\cepheus-build', ...args]),
        validateExecutablePath: false,
      );
    }
    return _CommandSpec(
      executable: script,
      args: args,
      workingDirectory: _settings.toolkitRoot,
      display: _displayCommand('bin/cepheus-build', args),
    );
  }

  List<String> _buildCommandArgs({required bool dryRun}) {
    final args = <String>['--execution-mode', _settings.executionMode.value];
    if (dryRun) args.add('--dry-run');

    if (_settings.executionMode == ExecutionMode.github) {
      args.addAll(['--runner-profile', _settings.runnerProfile]);
      final repo = _effectiveGitHubRepo(_settings);
      if (repo.isNotEmpty) args.addAll(['--github-repo', repo]);
      final workflow = _settings.githubWorkflow.trim();
      if (workflow.isNotEmpty) args.addAll(['--github-workflow', workflow]);
      if (_settings.product == 'foundry') {
        args.add(
          _settings.setupBuildrootDeps
              ? '--setup-buildroot-deps'
              : '--no-setup-buildroot-deps',
        );
        final buildrootDir = _settings.buildrootDir.trim();
        if (buildrootDir.isNotEmpty) {
          args.addAll(['--buildroot-dir', buildrootDir]);
        }
      }
      return args;
    }

    args.addAll(['--mode', _settings.buildMode]);
    if (!dryRun) args.add('--install-missing-deps');
    if (_settings.skipUnsupported) args.add('--skip-unsupported');
    args.add(_settings.keepGoing ? '--keep-going' : '--no-keep-going');
    if (_settings.product == 'foundry') {
      final buildrootDir = _settings.buildrootDir.trim();
      if (buildrootDir.isNotEmpty) {
        args.addAll(['--buildroot-dir', buildrootDir]);
      }
    }
    return args;
  }

  List<String> get _targetArgs {
    final raw = _settings.targets.trim();
    if (raw.isEmpty) return ['all'];
    return raw.split(RegExp(r'\s+')).where((part) => part.isNotEmpty).toList();
  }

  String get _visibleOutput {
    if (_showLiveOutput || _selectedHistory == null) return _liveOutput;
    return _selectedHistory!.output;
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
                onChanged: widget.onThemeModeChanged,
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

  Widget _buildControlsPanel() {
    final brand = context.brandColors;
    final products = _products.contains(_settings.product)
        ? _products
        : [_settings.product, ..._products];

    return ClPanel(
      fillParent: true,
      head: ClPanelHead(
        icon: ClIcons.tune,
        title: 'Build Controls',
        tools: [
          Tooltip(
            message: 'Reload products',
            child: ClButton.iconOnly(
              icon: ClIcons.refresh,
              size: ClButtonSize.sm,
              onPressed: _isRunning ? null : _refreshProducts,
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(14, 4, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _fieldLabel('Run location'),
            _BuildSegmented<ExecutionMode>(
              value: _settings.executionMode,
              expand: true,
              options: const [
                ClSegmentOption(
                  value: ExecutionMode.local,
                  label: 'Local',
                  icon: ClIcons.monitor,
                ),
                ClSegmentOption(
                  value: ExecutionMode.github,
                  label: 'GitHub',
                  icon: ClIcons.cloud,
                ),
              ],
              onChanged: _isRunning
                  ? null
                  : (value) => _setExecutionMode(value),
            ),
            const SizedBox(height: 14),
            _fieldLabel('Product'),
            DropdownButtonFormField<String>(
              initialValue: _settings.product,
              isExpanded: true,
              items: [
                for (final product in products)
                  DropdownMenuItem(value: product, child: Text(product)),
              ],
              onChanged: _isRunning
                  ? null
                  : (value) {
                      if (value == null) return;
                      unawaited(_setProduct(value));
                    },
            ),
            const SizedBox(height: 14),
            _fieldLabel('Targets or groups'),
            DropdownButtonFormField<String>(
              key: ValueKey(
                'targets-${_settings.product}-${_settings.targets}-${_productDescriptor.targetChoices.join('|')}',
              ),
              initialValue:
                  _productDescriptor.targetChoices.contains(_settings.targets)
                  ? _settings.targets
                  : _productDescriptor.targetChoices.first,
              isExpanded: true,
              items: [
                for (final target in _productDescriptor.targetChoices)
                  DropdownMenuItem(value: target, child: Text(target)),
              ],
              onChanged: _isRunning
                  ? null
                  : (value) {
                      if (value == null) return;
                      _setTargets(value);
                    },
            ),
            if (_isGitHubMode) ...[
              const SizedBox(height: 14),
              _fieldLabel('Runner profile'),
              DropdownButtonFormField<String>(
                key: ValueKey('runner-${_settings.runnerProfile}'),
                initialValue: _settings.runnerProfile,
                isExpanded: true,
                items: [
                  for (final profile in _availableRunnerProfiles)
                    DropdownMenuItem(
                      value: profile.value,
                      child: Text(profile.label),
                    ),
                ],
                onChanged: _isRunning
                    ? null
                    : (value) {
                        if (value == null) return;
                        _setRunnerProfile(value);
                      },
              ),
              const SizedBox(height: 14),
              _buildGitHubOptions(),
            ],
            if (!_isGitHubMode) ...[
              const SizedBox(height: 14),
              _fieldLabel('Build mode'),
              _BuildSegmented<String>(
                value: _settings.buildMode,
                expand: true,
                options: const [
                  ClSegmentOption(value: 'release', label: 'Release'),
                  ClSegmentOption(value: 'profile', label: 'Profile'),
                  ClSegmentOption(value: 'debug', label: 'Debug'),
                ],
                onChanged: _isRunning ? null : _setBuildMode,
              ),
              const SizedBox(height: 14),
              _fieldLabel('Repo root override'),
              TextField(
                controller: _repoRootController,
                enabled: !_isRunning,
                decoration: const InputDecoration(
                  hintText: 'leave empty for product config default',
                ),
                onChanged: (value) =>
                    _updateSettings(_settings.copyWith(repoRoot: value)),
              ),
            ],
            const SizedBox(height: 14),
            _fieldLabel('Toolkit root'),
            TextField(
              controller: _toolkitRootController,
              enabled: !_isRunning,
              decoration: InputDecoration(
                suffixIcon: IconButton(
                  tooltip: 'Load toolkit root',
                  onPressed: _isRunning ? null : _applyToolkitRoot,
                  icon: const ClIcon(ClIcons.refresh),
                ),
              ),
              onSubmitted: (_) => _applyToolkitRoot(),
            ),
            if (!_isGitHubMode) ...[
              const SizedBox(height: 14),
              DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: brand.borderSubtle),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: SwitchListTile(
                  dense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 10),
                  title: Text(
                    'Skip unsupported hosts',
                    style: context.clBodySmall,
                  ),
                  value: _settings.skipUnsupported,
                  onChanged: _isRunning
                      ? null
                      : (value) => _updateSettings(
                          _settings.copyWith(skipUnsupported: value),
                        ),
                ),
              ),
              const SizedBox(height: 10),
              DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: brand.borderSubtle),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: SwitchListTile(
                  dense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 10),
                  title: Text(
                    'Keep going after target failure',
                    style: context.clBodySmall,
                  ),
                  value: _settings.keepGoing,
                  onChanged: _isRunning
                      ? null
                      : (value) => _updateSettings(
                          _settings.copyWith(keepGoing: value),
                        ),
                ),
              ),
            ],
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ClButton(
                  icon: ClIcons.list,
                  onPressed: _isRunning ? null : () => _run(BuildAction.plan),
                  child: const Text('Plan'),
                ),
                if (_isGitHubMode)
                  ClButton(
                    icon: ClIcons.grid,
                    kind: ClButtonKind.outlined,
                    onPressed: _isRunning
                        ? null
                        : () => _run(BuildAction.matrix),
                    child: const Text('Matrix'),
                  ),
                ClButton(
                  icon: ClIcons.terminal,
                  kind: ClButtonKind.outlined,
                  onPressed: _isRunning ? null : () => _run(BuildAction.dryRun),
                  child: Text(_isGitHubMode ? 'Preview' : 'Dry Run'),
                ),
                ClButton(
                  icon: ClIcons.play,
                  onPressed: _isRunning ? null : () => _run(BuildAction.build),
                  child: Text(_isGitHubMode ? 'Dispatch' : 'Build'),
                ),
                if (_isRunning)
                  ClButton.destructive(
                    icon: ClIcons.stop,
                    onPressed: _cancelRun,
                    child: const Text('Cancel'),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            _buildDeployControls(),
            const SizedBox(height: 16),
            ClBanner(
              kind: ClBannerKind.info,
              title: 'History file',
              body: 'Commit this file when you want to share run history.',
              detail: _historyFile.path,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConsoleWorkspace(BoxConstraints constraints) {
    if (constraints.maxWidth < 980) {
      final logHeight = (constraints.maxHeight * 0.76).clamp(420.0, 760.0);
      final historyHeight = (constraints.maxHeight * 0.56).clamp(360.0, 560.0);
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 48),
        child: Column(
          children: [
            _buildControlsPanel(),
            const SizedBox(height: 12),
            SizedBox(height: logHeight, child: _buildLogPanel()),
            const SizedBox(height: 12),
            SizedBox(height: historyHeight, child: _buildHistoryPanel()),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(width: 330, child: _buildControlsPanel()),
          const SizedBox(width: 12),
          Expanded(child: _buildLogPanel()),
          const SizedBox(width: 12),
          SizedBox(width: 360, child: _buildHistoryPanel()),
        ],
      ),
    );
  }

  Widget _buildGitHubOptions() {
    final brand = context.brandColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClBanner(
          kind: ClBannerKind.info,
          title: 'GitHub dispatch',
          body:
              'Preview uses the shared CLI dry run. Dispatch sends workflow_dispatch to the selected repo.',
          detail: 'Runner profiles are loaded from build.toml.',
        ),
        const SizedBox(height: 12),
        _fieldLabel('GitHub repo'),
        TextField(
          controller: _githubRepoController,
          enabled: !_isRunning,
          decoration: InputDecoration(
            hintText: _productDescriptor.githubRepo.isEmpty
                ? 'owner/repository'
                : _productDescriptor.githubRepo,
          ),
          onChanged: (value) =>
              _updateSettings(_settings.copyWith(githubRepo: value)),
        ),
        const SizedBox(height: 12),
        _fieldLabel('Workflow'),
        TextField(
          controller: _githubWorkflowController,
          enabled: !_isRunning,
          decoration: const InputDecoration(hintText: 'shared-build.yml'),
          onChanged: (value) =>
              _updateSettings(_settings.copyWith(githubWorkflow: value)),
        ),
        if (_isFoundry) ...[
          const SizedBox(height: 12),
          DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: brand.borderSubtle),
              borderRadius: BorderRadius.circular(6),
            ),
            child: SwitchListTile(
              dense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 10),
              title: Text('Install Buildroot deps', style: context.clBodySmall),
              subtitle: Text(
                'Turn off for prepared org self-hosted images.',
                style: context.dataTiny,
              ),
              value: _settings.setupBuildrootDeps,
              onChanged: _isRunning
                  ? null
                  : (value) => _updateSettings(
                      _settings.copyWith(setupBuildrootDeps: value),
                    ),
            ),
          ),
          const SizedBox(height: 12),
          _fieldLabel('Buildroot checkout'),
          TextField(
            controller: _buildrootDirController,
            enabled: !_isRunning,
            decoration: const InputDecoration(
              hintText: 'optional, e.g. /opt/buildroot',
            ),
            onChanged: (value) =>
                _updateSettings(_settings.copyWith(buildrootDir: value)),
          ),
        ],
      ],
    );
  }

  Widget _buildDeployControls() {
    final stores = _productDescriptor.storeChoices;
    final selectedStore = _selectedStore;
    final hasStores = stores.isNotEmpty;
    final canDeploy =
        hasStores &&
        selectedStore != null &&
        selectedStore.enabled &&
        !_isRunning;
    final requiredEnv = selectedStore?.requiredEnv ?? const <String>[];
    final hosts = selectedStore?.hosts ?? const <String>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _fieldLabel('Store deploy'),
        if (!hasStores)
          const ClBanner(
            kind: ClBannerKind.info,
            title: 'No store lanes',
            body: 'Add [stores.*] entries to the product config.',
          )
        else ...[
          DropdownButtonFormField<String>(
            key: ValueKey('store-${_settings.product}-${_settings.store}'),
            initialValue: stores.any((store) => store.name == _settings.store)
                ? _settings.store
                : stores.first.name,
            isExpanded: true,
            items: [
              for (final store in stores)
                DropdownMenuItem(
                  value: store.name,
                  enabled: store.enabled,
                  child: Text(store.label),
                ),
            ],
            onChanged: _isRunning
                ? null
                : (value) {
                    if (value == null) return;
                    _setStore(value);
                  },
          ),
          const SizedBox(height: 8),
          ClBanner(
            kind: selectedStore?.enabled == false
                ? ClBannerKind.warn
                : ClBannerKind.info,
            title: selectedStore?.enabled == false
                ? 'Store lane disabled'
                : 'Store lane',
            body: requiredEnv.isEmpty
                ? 'No required environment variables declared.'
                : 'Requires ${requiredEnv.join(', ')}.',
            detail: hosts.isEmpty ? 'Hosts: any' : 'Hosts: ${hosts.join(', ')}',
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ClButton(
                icon: ClIcons.terminal,
                kind: ClButtonKind.outlined,
                onPressed: canDeploy
                    ? () => _run(BuildAction.deployPreview)
                    : null,
                child: const Text('Preview Deploy'),
              ),
              ClButton(
                icon: ClIcons.upload,
                onPressed: canDeploy ? () => _run(BuildAction.deploy) : null,
                child: const Text('Deploy'),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildLogPanel() {
    final title = _showLiveOutput ? 'Run Output' : 'History Output';
    final subtitle = _isRunning && _startedAt != null
        ? 'started ${_timeLabel(_startedAt!)}'
        : _selectedHistory == null
        ? 'no selected run'
        : '${_selectedHistory!.product} ${_entryScope(_selectedHistory!)}';
    final allEntries = _logEntries(_visibleOutput);
    final visibleEntries = allEntries
        .where((entry) => _logFilter.accepts(entry))
        .toList();
    final visibleText = _logTextForEntries(visibleEntries);
    final fullText = _visibleOutput;
    final rawDisplayText = _logFilter == _LogFilter.all
        ? fullText
        : visibleText;

    return ClPanel(
      fillParent: true,
      head: ClPanelHead(
        icon: ClIcons.terminal,
        title: title,
        count: subtitle,
        tools: [
          if (_selectedHistory != null)
            ClFilterPill(
              active: !_showLiveOutput,
              onTap: () => setState(() => _showLiveOutput = false),
              label: 'Selected',
            ),
          ClFilterPill(
            active: _showLiveOutput,
            onTap: () => setState(() => _showLiveOutput = true),
            label: 'Live',
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: _CommandPreview(
              command: _commandFor(_runningAction ?? BuildAction.plan).display,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: _LogFilterBar(
              value: _logFilter,
              visibleCount: visibleEntries.length,
              totalCount: allEntries.length,
              onChanged: (value) => setState(() => _logFilter = value),
              rawMode: _showRawLog,
              onRawModeChanged: (value) => setState(() => _showRawLog = value),
              onCopyVisible: visibleText.isEmpty
                  ? null
                  : () => unawaited(_copyLogText(visibleText, 'Visible log')),
              onCopyAll: fullText.isEmpty
                  ? null
                  : () => unawaited(_copyLogText(fullText, 'Full log')),
            ),
          ),
          Expanded(
            child: _showRawLog
                ? _SelectableRawLogView(
                    text: rawDisplayText,
                    emptyMessage: allEntries.isEmpty
                        ? 'No output yet. Run plan, matrix, dry-run, or build.'
                        : 'No lines match ${_logFilter.label}.',
                    controller: _logScrollController,
                  )
                : ClLogView(
                    controller: _logScrollController,
                    entries: visibleEntries,
                    emptyMessage: allEntries.isEmpty
                        ? 'No output yet. Run plan, matrix, dry-run, or build.'
                        : 'No lines match ${_logFilter.label}.',
                    padding: const EdgeInsets.fromLTRB(0, 8, 0, 28),
                    timeColumnWidth: 42,
                    tagColumnWidth: 72,
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildHistoryPanel() {
    return ClPanel(
      fillParent: true,
      head: ClPanelHead(
        icon: ClIcons.list,
        title: 'History',
        count: _history.length.toString(),
        tools: [
          Tooltip(
            message: 'Clear history',
            child: ClButton.iconOnly(
              icon: ClIcons.trash,
              size: ClButtonSize.sm,
              onPressed: _history.isEmpty || _isRunning ? null : _clearHistory,
            ),
          ),
        ],
      ),
      body: _history.isEmpty
          ? const Center(
              child: ClEmptyState(
                title: 'No runs yet',
                body: 'Plan, dry-run, matrix, and build results appear here.',
                icon: ClIcons.terminal,
              ),
            )
          : ListView.separated(
              controller: _historyScrollController,
              padding: const EdgeInsets.fromLTRB(10, 4, 10, 12),
              itemBuilder: (context, index) {
                final entry = _history[index];
                final selected = _selectedHistory?.id == entry.id;
                return ClListRow(
                  selected: selected,
                  onTap: () {
                    setState(() {
                      _selectedHistory = entry;
                      _showLiveOutput = false;
                    });
                  },
                  pre: ClStatusBadge(
                    status: entry.succeeded ? 'complete' : 'error',
                    label: entry.succeeded ? 'ok' : 'fail',
                  ),
                  meta: ClListRowMeta(
                    name: '${entry.product} · ${entry.action.label}',
                    sub:
                        '${entry.executionMode.label} · ${_runnerProfileLabel(entry.runnerProfile)} · ${_entryScope(entry)} · ${_timeLabel(entry.startedAt)}',
                  ),
                  trailing: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(entry.durationLabel, style: context.dataTiny),
                      Text('exit ${entry.exitCode}', style: context.dataTiny),
                    ],
                  ),
                );
              },
              separatorBuilder: (_, _) => const SizedBox(height: 4),
              itemCount: _history.length,
            ),
    );
  }

  Widget _fieldLabel(String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: ClTechLabel(label),
    );
  }
}

class _LogFilterBar extends StatelessWidget {
  const _LogFilterBar({
    required this.value,
    required this.visibleCount,
    required this.totalCount,
    required this.onChanged,
    required this.rawMode,
    required this.onRawModeChanged,
    required this.onCopyVisible,
    required this.onCopyAll,
  });

  final _LogFilter value;
  final int visibleCount;
  final int totalCount;
  final ValueChanged<_LogFilter> onChanged;
  final bool rawMode;
  final ValueChanged<bool> onRawModeChanged;
  final VoidCallback? onCopyVisible;
  final VoidCallback? onCopyAll;

  @override
  Widget build(BuildContext context) {
    final brand = context.brandColors;
    return Wrap(
      spacing: 10,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 220, minWidth: 180),
          child: SizedBox(
            width: 220,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: brand.bgAlt,
                border: Border.all(color: brand.borderSubtle),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<_LogFilter>(
                    value: value,
                    isExpanded: true,
                    icon: const ClIcon(ClIcons.chevronDown, size: 15),
                    style: context.clBodySmall.copyWith(color: brand.ink2),
                    dropdownColor: brand.surface2,
                    items: [
                      for (final filter in _LogFilter.values)
                        DropdownMenuItem(
                          value: filter,
                          child: Text(filter.label),
                        ),
                    ],
                    onChanged: (filter) {
                      if (filter == null) return;
                      onChanged(filter);
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
        SizedBox(
          height: 30,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '$visibleCount / $totalCount lines',
              style: context.dataTiny.copyWith(color: brand.ink3),
            ),
          ),
        ),
        Tooltip(
          message: 'Use selectable raw text',
          child: ClFilterPill(
            active: rawMode,
            onTap: () => onRawModeChanged(!rawMode),
            label: 'Text',
          ),
        ),
        Tooltip(
          message: 'Copy filtered output',
          child: ClButton.iconOnly(
            icon: ClIcons.copy,
            size: ClButtonSize.sm,
            kind: ClButtonKind.outlined,
            onPressed: onCopyVisible,
          ),
        ),
        Tooltip(
          message: 'Copy full raw output',
          child: ClButton.iconOnly(
            icon: ClIcons.copy,
            size: ClButtonSize.sm,
            onPressed: onCopyAll,
          ),
        ),
      ],
    );
  }
}

class _SelectableRawLogView extends StatelessWidget {
  const _SelectableRawLogView({
    required this.text,
    required this.emptyMessage,
    required this.controller,
  });

  final String text;
  final String emptyMessage;
  final ScrollController controller;

  @override
  Widget build(BuildContext context) {
    final brand = context.brandColors;
    if (text.isEmpty) {
      return Center(
        child: Text(
          emptyMessage,
          style: context.dataSmall.copyWith(color: brand.ink3),
          textAlign: TextAlign.center,
        ),
      );
    }
    return Scrollbar(
      controller: controller,
      child: SingleChildScrollView(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 28),
        child: SizedBox(
          width: double.infinity,
          child: SelectableText(
            text,
            style: context.dataTiny.copyWith(color: brand.ink2, height: 1.6),
          ),
        ),
      ),
    );
  }
}

class _BuildSegmented<T> extends StatelessWidget {
  const _BuildSegmented({
    required this.value,
    required this.options,
    required this.onChanged,
    this.expand = false,
  });

  final T value;
  final List<ClSegmentOption<T>> options;
  final ValueChanged<T>? onChanged;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final brand = context.brandColors;
    Widget segment(ClSegmentOption<T> option) {
      final selected = option.value == value;
      final fg = selected ? brand.onPrimary : brand.ink2;
      final bg = selected ? brand.primary : Colors.transparent;
      final border = selected ? brand.primary : brand.borderSubtle;
      final tile = Material(
        color: bg,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          onTap: onChanged == null ? null : () => onChanged!(option.value),
          borderRadius: BorderRadius.circular(6),
          mouseCursor: onChanged == null
              ? SystemMouseCursors.basic
              : SystemMouseCursors.click,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            height: 30,
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              border: Border.all(color: border),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (option.icon != null) ...[
                  Icon(option.icon, size: 14, color: fg),
                  const SizedBox(width: 6),
                ],
                Flexible(
                  child: Text(
                    option.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'Geist',
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: fg,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      final wrapped = option.tooltip == null
          ? tile
          : Tooltip(message: option.tooltip!, child: tile);
      return expand ? Expanded(child: wrapped) : wrapped;
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        color: brand.bgAlt,
        border: Border.all(color: brand.borderSubtle),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: Row(
          mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
          children: [
            for (var index = 0; index < options.length; index++) ...[
              if (index > 0) const SizedBox(width: 2),
              segment(options[index]),
            ],
          ],
        ),
      ),
    );
  }
}

class _CommandPreview extends StatelessWidget {
  const _CommandPreview({required this.command});

  final String command;

  @override
  Widget build(BuildContext context) {
    final brand = context.brandColors;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: brand.bgAlt,
        border: Border.all(color: brand.borderSubtle),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SelectableText(
            command,
            style: context.dataTiny.copyWith(color: brand.ink2),
          ),
        ),
      ),
    );
  }
}

class _CommandSpec {
  const _CommandSpec({
    required this.executable,
    required this.args,
    required this.workingDirectory,
    required this.display,
    this.validateExecutablePath = true,
  });

  final String executable;
  final List<String> args;
  final String workingDirectory;
  final String display;
  final bool validateExecutablePath;
}

List<ClLogEntry> _logEntries(String output) {
  final lines = output.split(RegExp(r'\r?\n'));
  return [
    for (var i = 0; i < lines.length; i++)
      if (lines[i].isNotEmpty)
        ClLogEntry(
          time: (i + 1).toString().padLeft(3, '0'),
          tag: _tagFor(lines[i]),
          message: lines[i],
          tone: _toneFor(lines[i]),
        ),
  ];
}

String _logTextForEntries(List<ClLogEntry> entries) {
  return entries.map((entry) => entry.message).join('\n');
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

String _basename(String path) {
  final normalized = path.replaceAll('\\', '/');
  final pieces = normalized.split('/');
  return pieces.isEmpty ? path : pieces.last;
}

String _stripTomlComment(String line) {
  var inString = false;
  var escaped = false;
  for (var index = 0; index < line.length; index++) {
    final char = line[index];
    if (char == r'\' && inString && !escaped) {
      escaped = true;
      continue;
    }
    if (char == '"' && !escaped) {
      inString = !inString;
    }
    if (char == '#' && !inString) {
      return line.substring(0, index);
    }
    escaped = false;
  }
  return line;
}

String? _tomlSection(String line) {
  final match = RegExp(r'^\[([^\]]+)\]$').firstMatch(line);
  return match?.group(1);
}

String? _targetSectionName(String section) {
  const prefix = 'targets.';
  if (!section.startsWith(prefix)) return null;
  return section.substring(prefix.length);
}

String? _storeSectionName(String section) {
  const prefix = 'stores.';
  if (!section.startsWith(prefix)) return null;
  return section.substring(prefix.length);
}

String? _tomlAssignmentName(String line) {
  return RegExp(r'^([A-Za-z0-9_-]+)\s*=').firstMatch(line)?.group(1);
}

String? _tomlStringValue(String line, String key) {
  final escapedKey = RegExp.escape(key);
  final match = RegExp('^$escapedKey\\s*=\\s*"([^"]*)"').firstMatch(line);
  return match?.group(1);
}

bool? _tomlBoolValue(String line, String key) {
  final escapedKey = RegExp.escape(key);
  final match = RegExp(
    '^$escapedKey\\s*=\\s*(true|false)\\s*\$',
  ).firstMatch(line);
  final value = match?.group(1);
  if (value == null) return null;
  return value == 'true';
}

List<String>? _tomlArrayValue(String line, String key) {
  final escapedKey = RegExp.escape(key);
  final match = RegExp(
    '^$escapedKey\\s*=\\s*\\[(.*)\\]\\s*\$',
  ).firstMatch(line);
  final raw = match?.group(1);
  if (raw == null) return null;
  return [
    for (final valueMatch in RegExp('"([^"]*)"').allMatches(raw))
      valueMatch.group(1) ?? '',
  ].where((value) => value.isNotEmpty).toList();
}

List<String> _uniqueStrings(Iterable<String> values) {
  final seen = <String>{};
  final result = <String>[];
  for (final value in values) {
    final normalized = value.trim();
    if (normalized.isEmpty || seen.contains(normalized)) continue;
    seen.add(normalized);
    result.add(normalized);
  }
  return result;
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

String _truncateOutput(String output) {
  return output;
}

String _timeLabel(DateTime value) {
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
}
