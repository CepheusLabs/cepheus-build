import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:forge/forge.dart';

import 'build_models.dart';

const _maxHistoryEntries = 250;
const _maxStoredOutputChars = 160000;
const _targetPresets = [
  'all',
  'desktop',
  'mobile',
  'release',
  'quality',
  'os',
  'mcu',
];
const _fallbackProducts = [
  'anvil',
  'colorwake-studio',
  'deckhand',
  'foundry',
  'printdeck',
];

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
  late TextEditingController _targetsController;
  late TextEditingController _toolkitRootController;
  late TextEditingController _githubRepoController;
  late TextEditingController _githubWorkflowController;
  late TextEditingController _buildrootDirController;

  final ScrollController _historyScrollController = ScrollController();
  final ScrollController _logScrollController = ScrollController();

  List<String> _products = const [];
  List<BuildHistoryEntry> _history = const [];
  BuildHistoryEntry? _selectedHistory;
  Process? _process;
  BuildAction? _runningAction;
  DateTime? _startedAt;
  String _liveOutput = '';
  String? _message;
  bool _loading = true;
  bool _showLiveOutput = true;

  bool get _isRunning => _process != null;

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
    _targetsController = TextEditingController(text: _settings.targets);
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
    _targetsController.dispose();
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
      products = _fallbackProducts;
      message = 'Products could not be loaded: $error';
    }
    if (products.isNotEmpty && !products.contains(settings.product)) {
      settings = settings.copyWith(product: products.first);
    }

    if (!mounted) return;
    setState(() {
      _settings = settings;
      _history = entries;
      _selectedHistory = entries.isEmpty ? null : entries.first;
      _products = products;
      _loading = false;
      _repoRootController.text = settings.repoRoot;
      _targetsController.text = settings.targets;
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
      return _fallbackProducts;
    }

    final products = <String>[];
    await for (final entity in productsDir.list()) {
      if (entity is! File || !entity.path.endsWith('.toml')) continue;
      products.add(_basename(entity.path).replaceFirst(RegExp(r'\.toml$'), ''));
    }
    products.sort();
    return products;
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
    try {
      products = await _loadProducts(_settings.toolkitRoot);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _message = 'Products could not be loaded: $error');
      return;
    }
    if (!mounted) return;
    setState(() {
      _products = products;
      if (products.isNotEmpty && !products.contains(_settings.product)) {
        _settings = _settings.copyWith(product: products.first);
      }
      _message = 'Products refreshed';
    });
    _persistSnapshot();
  }

  void _setProduct(String product) {
    final previousDefault = _defaultGitHubRepoForProduct(_settings.product);
    final currentRepo = _settings.githubRepo.trim();
    final shouldFollowProduct =
        currentRepo.isEmpty || currentRepo == previousDefault;
    final nextSettings = _settings.copyWith(
      product: product,
      githubRepo: shouldFollowProduct
          ? _defaultGitHubRepoForProduct(product)
          : _settings.githubRepo,
    );
    _githubRepoController.text = _effectiveGitHubRepo(nextSettings);
    _updateSettings(nextSettings);
  }

  void _setTargets(String targets) {
    _targetsController.text = targets;
    _updateSettings(_settings.copyWith(targets: targets));
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
    process.kill(ProcessSignal.sigterm);
    setState(() {
      _message = 'Cancel requested';
      _liveOutput = '$_liveOutput\ncancel requested\n';
    });
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
    if (_settings.executionMode == ExecutionMode.github &&
        action == BuildAction.build) {
      return _githubDispatchCommand();
    }
    if (_settings.executionMode == ExecutionMode.github &&
        action == BuildAction.dryRun) {
      final dispatch = _githubDispatchCommand();
      return _echoCommand(dispatch.display);
    }

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
      case BuildAction.matrix:
        args.addAll([
          '--runner-profile',
          _settings.runnerProfile.value,
          '--pretty',
          ..._targetArgs,
        ]);
      case BuildAction.dryRun:
        args.addAll(['--mode', _settings.buildMode, '--dry-run']);
        if (_settings.skipUnsupported) args.add('--skip-unsupported');
        args.addAll(_targetArgs);
      case BuildAction.build:
        args.addAll(['--mode', _settings.buildMode]);
        if (_settings.skipUnsupported) args.add('--skip-unsupported');
        args.addAll(_targetArgs);
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

  _CommandSpec _githubDispatchCommand() {
    final workflow = _settings.githubWorkflow.trim().isEmpty
        ? 'shared-build.yml'
        : _settings.githubWorkflow.trim();
    final args = <String>[
      'workflow',
      'run',
      workflow,
      '-R',
      _effectiveGitHubRepo(_settings),
      '-f',
      'targets=${_targetArgs.join(' ')}',
      '-f',
      'runner-profile=${_settings.runnerProfile.value}',
      '-f',
      'planner-runner-json=${_plannerRunnerJson(_settings.runnerProfile)}',
      '-f',
      'setup-buildroot-deps=${_settings.setupBuildrootDeps}',
    ];
    final buildrootDir = _settings.buildrootDir.trim();
    if (buildrootDir.isNotEmpty) {
      args.addAll(['-f', 'buildroot-dir=$buildrootDir']);
    }
    return _CommandSpec(
      executable: 'gh',
      args: args,
      workingDirectory: _settings.repoRoot.trim().isEmpty
          ? _settings.toolkitRoot
          : _settings.repoRoot.trim(),
      display: _displayCommand('gh', args),
      validateExecutablePath: false,
    );
  }

  _CommandSpec _echoCommand(String line) {
    if (Platform.isWindows) {
      return _CommandSpec(
        executable: 'cmd',
        args: ['/c', 'echo', line],
        workingDirectory: _settings.toolkitRoot,
        display: line,
        validateExecutablePath: false,
      );
    }
    return _CommandSpec(
      executable: '/bin/sh',
      args: ['-lc', 'printf "%s\\n" "\$1"', 'print-command', line],
      workingDirectory: _settings.toolkitRoot,
      display: line,
    );
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
            nav: [
              ClNavPill(
                label: 'Console',
                selected: true,
                icon: ClIcons.terminal,
                onPressed: () {},
              ),
              ClNavPill(
                label: 'History',
                icon: ClIcons.list,
                onPressed: () => setState(() => _showLiveOutput = false),
              ),
            ],
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
                      if (constraints.maxWidth < 980) {
                        return SingleChildScrollView(
                          padding: const EdgeInsets.all(14),
                          child: Column(
                            children: [
                              _buildControlsPanel(),
                              const SizedBox(height: 12),
                              SizedBox(height: 440, child: _buildLogPanel()),
                              const SizedBox(height: 12),
                              SizedBox(
                                height: 420,
                                child: _buildHistoryPanel(),
                              ),
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
                value: _settings.runnerProfile.label,
              ),
              ClStatusEntry(label: 'product', value: _settings.product),
              ClStatusEntry(label: 'targets', value: _settings.targets),
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
            ClSegmented<ExecutionMode>(
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
                  : (value) => _updateSettings(
                      _settings.copyWith(executionMode: value),
                    ),
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
                      _setProduct(value);
                    },
            ),
            const SizedBox(height: 14),
            _fieldLabel('Targets or groups'),
            TextField(
              controller: _targetsController,
              enabled: !_isRunning,
              decoration: const InputDecoration(hintText: 'all, os, desktop'),
              onChanged: (value) =>
                  _updateSettings(_settings.copyWith(targets: value)),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final preset in _targetPresets)
                  ClFilterPill(
                    active: _settings.targets.trim() == preset,
                    disabled: _isRunning,
                    onTap: () => _setTargets(preset),
                    label: preset,
                  ),
              ],
            ),
            const SizedBox(height: 14),
            _fieldLabel('Runner profile'),
            ClSegmented<RunnerProfile>(
              value: _settings.runnerProfile,
              expand: true,
              options: const [
                ClSegmentOption(
                  value: RunnerProfile.githubHosted,
                  label: 'GitHub',
                  icon: ClIcons.cloud,
                ),
                ClSegmentOption(
                  value: RunnerProfile.selfHosted,
                  label: 'Org runners',
                  icon: ClIcons.server,
                ),
              ],
              onChanged: _isRunning
                  ? null
                  : (value) => _updateSettings(
                      _settings.copyWith(runnerProfile: value),
                    ),
            ),
            if (_settings.executionMode == ExecutionMode.github) ...[
              const SizedBox(height: 14),
              _buildGitHubOptions(),
            ],
            const SizedBox(height: 14),
            _fieldLabel('Build mode'),
            ClSegmented<String>(
              value: _settings.buildMode,
              expand: true,
              options: const [
                ClSegmentOption(value: 'release', label: 'Release'),
                ClSegmentOption(value: 'profile', label: 'Profile'),
                ClSegmentOption(value: 'debug', label: 'Debug'),
              ],
              onChanged: _isRunning
                  ? null
                  : (value) =>
                        _updateSettings(_settings.copyWith(buildMode: value)),
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
            if (_settings.executionMode == ExecutionMode.github)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: ClBanner(
                  kind: ClBannerKind.info,
                  title: 'GitHub dispatch',
                  body:
                      'Build sends workflow_dispatch to the selected repo. Dry Run previews the gh command.',
                  detail: _settings.runnerProfile == RunnerProfile.selfHosted
                      ? 'Planner: ["self-hosted","linux"]; matrix rows use org self-hosted OS labels.'
                      : 'Planner: ubuntu-latest; matrix rows use GitHub-provided runners.',
                ),
              ),
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
                ClButton(
                  icon: ClIcons.grid,
                  kind: ClButtonKind.outlined,
                  onPressed: _isRunning ? null : () => _run(BuildAction.matrix),
                  child: const Text('Matrix'),
                ),
                ClButton(
                  icon: ClIcons.terminal,
                  kind: ClButtonKind.outlined,
                  onPressed: _isRunning ? null : () => _run(BuildAction.dryRun),
                  child: Text(
                    _settings.executionMode == ExecutionMode.github
                        ? 'Preview'
                        : 'Dry Run',
                  ),
                ),
                ClButton(
                  icon: ClIcons.play,
                  onPressed: _isRunning ? null : () => _run(BuildAction.build),
                  child: Text(
                    _settings.executionMode == ExecutionMode.github
                        ? 'Dispatch'
                        : 'Build',
                  ),
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

  Widget _buildGitHubOptions() {
    final brand = context.brandColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _fieldLabel('GitHub repo'),
        TextField(
          controller: _githubRepoController,
          enabled: !_isRunning,
          decoration: const InputDecoration(hintText: 'CepheusLabs/foundry'),
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
    );
  }

  Widget _buildLogPanel() {
    final title = _showLiveOutput ? 'Run Output' : 'History Output';
    final subtitle = _isRunning && _startedAt != null
        ? 'started ${_timeLabel(_startedAt!)}'
        : _selectedHistory == null
        ? 'no selected run'
        : '${_selectedHistory!.product} ${_selectedHistory!.targets}';

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
          Expanded(
            child: ClLogView(
              controller: _logScrollController,
              entries: _logEntries(_visibleOutput),
              emptyMessage:
                  'No output yet. Run plan, matrix, dry-run, or build.',
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
                        '${entry.executionMode.label} · ${entry.runnerProfile.label} · ${entry.targets} · ${_timeLabel(entry.startedAt)}',
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
  final start = lines.length > 1200 ? lines.length - 1200 : 0;
  return [
    for (var i = start; i < lines.length; i++)
      if (lines[i].isNotEmpty)
        ClLogEntry(
          time: (i + 1).toString().padLeft(3, '0'),
          tag: _tagFor(lines[i]),
          message: lines[i],
          tone: _toneFor(lines[i]),
        ),
  ];
}

String _tagFor(String line) {
  final lower = line.toLowerCase();
  if (line.startsWith('+') || line.startsWith('bin/')) return 'cmd';
  if (lower.contains('error') || lower.contains('failed')) return 'error';
  if (lower.contains('warning') || lower.contains('warn')) return 'warn';
  if (lower.startsWith('exit code')) return 'exit';
  if (line.startsWith('==>')) return 'target';
  return 'log';
}

ClLogTone _toneFor(String line) {
  final lower = line.toLowerCase();
  if (line.startsWith('+') || line.startsWith('bin/')) return ClLogTone.input;
  if (lower.contains('error') || lower.contains('failed')) {
    return ClLogTone.danger;
  }
  if (lower.contains('warning') || lower.contains('warn')) {
    return ClLogTone.warning;
  }
  if (lower == 'exit code 0') return ClLogTone.success;
  if (lower.startsWith('exit code')) return ClLogTone.danger;
  if (line.startsWith('==>')) return ClLogTone.accent;
  return ClLogTone.neutral;
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

String _displayCommand(String executable, List<String> args) {
  return [executable, ...args].map(_quoteForDisplay).join(' ');
}

String _effectiveGitHubRepo(BuildSettings settings) {
  final configured = settings.githubRepo.trim();
  if (configured.isNotEmpty) return configured;
  return _defaultGitHubRepoForProduct(settings.product);
}

String _defaultGitHubRepoForProduct(String product) {
  return switch (product) {
    'deckhand' => 'CepheusLabs/deckhand-app',
    'colorwake-studio' => 'CepheusLabs/colorwake-studio',
    'printdeck' => 'CepheusLabs/printdeck',
    'anvil' => 'CepheusLabs/anvil',
    'foundry' => 'CepheusLabs/foundry',
    _ => 'CepheusLabs/$product',
  };
}

String _plannerRunnerJson(RunnerProfile profile) {
  return switch (profile) {
    RunnerProfile.githubHosted => '"ubuntu-latest"',
    RunnerProfile.selfHosted => '["self-hosted","linux"]',
  };
}

String _quoteForDisplay(String value) {
  if (value.isEmpty) return "''";
  if (!RegExp(r'\s').hasMatch(value)) return value;
  return "'${value.replaceAll("'", r"'\''")}'";
}

String _truncateOutput(String output) {
  if (output.length <= _maxStoredOutputChars) return output;
  final tail = output.substring(output.length - _maxStoredOutputChars);
  return 'output truncated to last $_maxStoredOutputChars characters\n$tail';
}

String _timeLabel(DateTime value) {
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
}
