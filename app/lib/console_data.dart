part of 'main.dart';

extension _ConsoleData on _BuildConsoleHomeState {
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

    final products = await _loadProducts(toolkitRoot);
    if (products.isEmpty && _describeError != null) {
      message = 'Could not list products: $_describeError';
    }
    if (products.isNotEmpty && !products.contains(settings.product)) {
      settings = settings.copyWith(product: products.first);
    }
    final runnerProfiles = await _loadRunnerProfiles(toolkitRoot);
    if (runnerProfiles.isEmpty && _describeError != null) {
      message = 'Could not load runner profiles: $_describeError';
    }
    if (runnerProfiles.isNotEmpty &&
        !runnerProfiles.any(
          (profile) => profile.value == settings.runnerProfile,
        )) {
      settings = settings.copyWith(runnerProfile: runnerProfiles.first.value);
    }
    final descriptor = await _loadProductDescriptor(
      toolkitRoot,
      settings.product,
    );
    if (_describeError != null) {
      message = 'Could not describe ${settings.product}: $_describeError';
    }
    settings = _settingsForDescriptor(settings, descriptor);

    if (!mounted) return;
    _setStateSafe(() {
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

    // Restore the persisted theme by pushing it up to the MaterialApp owner.
    widget.onThemeModeChanged(_themeModeFromString(settings.themeMode));

    try {
      if (!await historyFile.exists()) {
        await _saveSnapshot();
      }
    } on Object catch (error) {
      if (!mounted) return;
      _setStateSafe(() => _message = 'History file could not be saved: $error');
    }
  }

  /// Runs the CLI `describe` introspection command and decodes its JSON.
  /// Returns null (recording [_describeError]) on a nonzero exit, a missing
  /// binary, or unparseable output, so callers can fall back to safe defaults.
  Future<Map<String, dynamic>?> _describeJson(
    String toolkitRoot, {
    String? product,
  }) async {
    final cliArgs = <String>[
      'describe',
      if (product != null) ...['-p', product],
      '--json',
    ];
    final invocation = _cliInvocation(toolkitRoot, cliArgs);
    try {
      final result = await Process.run(
        invocation.executable,
        invocation.args,
        workingDirectory: toolkitRoot,
        runInShell: Platform.isWindows,
      );
      if (result.exitCode != 0) {
        _describeError =
            _firstLine(result.stderr) ?? 'exit code ${result.exitCode}';
        return null;
      }
      final decoded = jsonDecode(result.stdout.toString());
      if (decoded is Map<String, dynamic>) {
        _describeError = null;
        return decoded;
      }
      _describeError = 'unexpected describe output';
      return null;
    } on Object catch (error) {
      _describeError = error.toString();
      return null;
    }
  }

  Future<List<String>> _loadProducts(String toolkitRoot) async {
    final data = await _describeJson(toolkitRoot);
    if (data == null) return const [];
    final raw = data['products'];
    if (raw is! List) return const [];
    final products = <String>[
      for (final entry in raw)
        if (entry is Map) _jsonString(entry['slug']),
    ].where((slug) => slug.isNotEmpty).toList();
    products.sort();
    return products;
  }

  Future<_ProductDescriptor> _loadProductDescriptor(
    String toolkitRoot,
    String product,
  ) async {
    final data = await _describeJson(toolkitRoot, product: product);
    if (data == null) return _ProductDescriptor.empty(product);

    final github = data['github'];
    final githubRepo = github is Map ? _jsonString(github['repository']) : '';
    final githubWorkflow = github is Map
        ? _jsonString(github['workflow'])
        : '';

    final stores = <_StoreDescriptor>[];
    final rawStores = data['stores'];
    if (rawStores is Map) {
      rawStores.forEach((name, value) {
        if (value is! Map) return;
        stores.add(
          _StoreDescriptor(
            name: name.toString(),
            enabled: value['enabled'] is bool ? value['enabled'] as bool : true,
            hosts: _jsonStringList(value['hosts']),
            requiredEnv: _jsonStringList(value['required_env']),
          ),
        );
      });
    }

    final choices = _jsonStringList(data['target_choices']);
    return _ProductDescriptor(
      product: product,
      targetChoices: choices.isEmpty ? const ['all'] : choices,
      storeChoices: stores,
      githubRepo: githubRepo,
      githubWorkflow: githubWorkflow,
    );
  }

  Future<List<_RunnerProfileChoice>> _loadRunnerProfiles(
    String toolkitRoot,
  ) async {
    final data = await _describeJson(toolkitRoot);
    if (data == null) return const [];
    final raw = data['runner_profiles'];
    if (raw is! List) return const [];
    final profiles = <_RunnerProfileChoice>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      final value = _jsonString(entry['value']);
      if (value.isEmpty) continue;
      profiles.add(
        _RunnerProfileChoice(
          value: value,
          label: _jsonString(entry['label'], value),
        ),
      );
    }
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
    _setStateSafe(() => _settings = settings);
    if (save) _persistSnapshot();
  }

  void _persistSnapshot() {
    unawaited(
      _saveSnapshot().catchError((Object error) {
        if (!mounted) return;
        _setStateSafe(() => _message = 'History file could not be saved: $error');
      }),
    );
  }

  Future<void> _applyToolkitRoot() async {
    final root = _toolkitRootController.text.trim();
    if (root.isEmpty) return;
    _setStateSafe(() {
      _loading = true;
      _liveOutput = '';
      _showLiveOutput = true;
    });
    await _loadSnapshot(root);
  }

  Future<void> _refreshProducts() async {
    final products = await _loadProducts(_settings.toolkitRoot);
    final productsError = products.isEmpty ? _describeError : null;
    final runnerProfiles = await _loadRunnerProfiles(_settings.toolkitRoot);
    final runnerError = runnerProfiles.isEmpty ? _describeError : null;
    var settings = _settings;
    if (!mounted) return;
    _setStateSafe(() {
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
      _message = productsError != null
          ? 'Could not list products: $productsError'
          : runnerError != null
          ? 'Could not load runner profiles: $runnerError'
          : 'Products refreshed';
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
    final descriptor = await _loadProductDescriptor(
      _settings.toolkitRoot,
      product,
    );
    final descriptorError = _describeError;
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
    // #4: if we kept a user-typed GitHub repo that doesn't match the newly
    // selected product's configured repository, warn — a dispatch would
    // otherwise silently target the wrong repo.
    final keptRepo = nextSettings.githubRepo.trim();
    final repoMismatch =
        !shouldFollowProduct &&
        descriptor.githubRepo.isNotEmpty &&
        keptRepo.isNotEmpty &&
        keptRepo != descriptor.githubRepo;
    if (!mounted) return;
    _setStateSafe(() {
      _productDescriptor = descriptor;
      _settings = nextSettings;
      _githubRepoController.text = _effectiveGitHubRepo(nextSettings);
      _githubWorkflowController.text = nextSettings.githubWorkflow;
      if (descriptorError != null) {
        _message = 'Could not describe $product: $descriptorError';
      } else if (repoMismatch) {
        _message =
            'GitHub repo "$keptRepo" does not match $product '
            '(configured: ${descriptor.githubRepo}).';
      }
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

  /// Applies a theme choice: pushes it up to the [MaterialApp] owner for the
  /// live switch, and persists it into settings so it survives a reload.
  void _onThemeToggle(ThemeMode mode) {
    widget.onThemeModeChanged(mode);
    _updateSettings(_settings.copyWith(themeMode: _themeModeToString(mode)));
  }
}
