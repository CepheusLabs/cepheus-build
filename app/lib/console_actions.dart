part of 'main.dart';

extension _ConsoleActions on _BuildConsoleHomeState {
  Future<void> _run(BuildAction action) async {
    if (_isRunning) return;

    final command = _commandFor(action);
    if (command.validateExecutablePath) {
      // On Windows the executable is `python`; validate the CLI SCRIPT itself
      // (bin/cepheus-build). Elsewhere the executable IS that script.
      final scriptPath = Platform.isWindows
          ? _cliScriptPath(_settings.toolkitRoot)
          : command.executable;
      if (!await File(scriptPath).exists()) {
        _setStateSafe(() {
          _message = 'Build script not found';
          _liveOutput = 'Missing $scriptPath\n';
          _liveLineTimes = [DateTime.now()];
          _showLiveOutput = true;
        });
        return;
      }
    }

    final startedAt = DateTime.now();
    final buffer = StringBuffer()..writeln(command.display);
    var lineTimes = <DateTime>[startedAt];

    _setStateSafe(() {
      _runningAction = action;
      _startedAt = startedAt;
      _liveOutput = buffer.toString();
      _liveLineTimes = lineTimes;
      _showLiveOutput = true;
      _message = null;
    });

    Timer? flushTimer;
    try {
      final process = await Process.start(
        command.executable,
        command.args,
        workingDirectory: command.workingDirectory,
        runInShell: Platform.isWindows,
      );
      _setStateSafe(() => _process = process);

      // Coalesce live-log refreshes: the buffer accumulates every chunk
      // synchronously, but the (potentially huge) log view is only rebuilt at
      // most once per [_liveRefreshInterval], with a trailing flush.
      var lastFlush = DateTime.fromMillisecondsSinceEpoch(0);

      void pushLiveUpdate() {
        if (!mounted) return;
        lastFlush = DateTime.now();
        lineTimes = _syncLogLineTimes(buffer.toString(), lineTimes);
        _setStateSafe(() {
          _liveOutput = buffer.toString();
          _liveLineTimes = lineTimes;
        });
      }

      void append(String chunk) {
        buffer.write(chunk);
        if (!mounted) return;
        final waited = DateTime.now().difference(lastFlush);
        if (waited >= _liveRefreshInterval) {
          flushTimer?.cancel();
          flushTimer = null;
          pushLiveUpdate();
        } else {
          flushTimer ??= Timer(_liveRefreshInterval - waited, () {
            flushTimer = null;
            pushLiveUpdate();
          });
        }
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
      flushTimer?.cancel();

      final duration = DateTime.now().difference(startedAt);
      buffer.writeln();
      buffer.writeln('exit code $exitCode');
      lineTimes = _syncLogLineTimes(buffer.toString(), lineTimes);

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
        command: _redactSecrets(command.display),
        startedAt: startedAt,
        durationMs: duration.inMilliseconds,
        exitCode: exitCode,
        output: _truncateOutput(buffer.toString()),
        outputLineTimes: lineTimes
            .map((timestamp) => timestamp.toIso8601String())
            .toList(),
      );

      if (!mounted) return;
      _setStateSafe(() {
        _process = null;
        _runningAction = null;
        _startedAt = null;
        _liveOutput = entry.output;
        _liveLineTimes = lineTimes;
        _selectedHistory = entry;
        _history = [entry, ..._history].take(_maxHistoryEntries).toList();
        _message = exitCode == 0 ? 'Run completed' : 'Run failed';
      });
      try {
        await _saveSnapshot();
      } on Object catch (error) {
        if (!mounted) return;
        _setStateSafe(
          () => _message = 'Run finished, history could not be saved: $error',
        );
      }
    } on Object catch (error) {
      flushTimer?.cancel();
      if (!mounted) return;
      _setStateSafe(() {
        _process = null;
        _runningAction = null;
        _startedAt = null;
        _message = 'Run could not start';
        _liveOutput = '${buffer}error: $error\n';
        _liveLineTimes = _syncLogLineTimes(_liveOutput, lineTimes);
      });
    }
  }

  void _cancelRun() {
    final process = _process;
    if (process == null) return;
    _setStateSafe(() {
      _message = 'Cancel requested';
      _liveOutput = '$_liveOutput\ncancel requested\n';
      _liveLineTimes = _syncLogLineTimes(_liveOutput, _liveLineTimes);
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
      _setStateSafe(() {
        _message = 'Cancel forced';
        _liveOutput = '$_liveOutput\ncancel forced\n';
        _liveLineTimes = _syncLogLineTimes(_liveOutput, _liveLineTimes);
      });
    } on Object catch (error) {
      if (!Platform.isWindows) {
        await Process.run('kill', ['-KILL', '$pid']);
      }
      if (!mounted) return;
      _setStateSafe(() {
        _message = 'Cancel signal failed';
        _liveOutput = '$_liveOutput\ncancel signal failed: $error\n';
        _liveLineTimes = _syncLogLineTimes(_liveOutput, _liveLineTimes);
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
    _setStateSafe(() => _message = '$label copied');
  }

  Future<void> _clearHistory() async {
    _setStateSafe(() {
      _history = const [];
      _selectedHistory = null;
      _message = 'History cleared';
    });
    try {
      await _saveSnapshot();
    } on Object catch (error) {
      if (!mounted) return;
      _setStateSafe(() => _message = 'History file could not be saved: $error');
    }
  }

  _CommandSpec _commandFor(BuildAction action) {
    // Arg-vector construction is pure and lives in console_logic.dart so it can
    // be unit-tested directly; only platform wrapping + display stay here.
    final args = logic.cliArgsFor(_settings, action);

    final invocation = _cliInvocation(_settings.toolkitRoot, args);
    if (Platform.isWindows) {
      return _CommandSpec(
        executable: invocation.executable,
        args: invocation.args,
        workingDirectory: _settings.toolkitRoot,
        display: _displayCommand('python', ['bin\\cepheus-build', ...args]),
      );
    }
    return _CommandSpec(
      executable: invocation.executable,
      args: invocation.args,
      workingDirectory: _settings.toolkitRoot,
      display: _displayCommand('bin/cepheus-build', args),
      // Always validate (default); _run checks the script path on every host.
      validateExecutablePath: true,
    );
  }

  String get _visibleOutput {
    if (_showLiveOutput || _selectedHistory == null) return _liveOutput;
    return _selectedHistory!.output;
  }

  List<String> get _visibleOutputLineTimes {
    if (_showLiveOutput || _selectedHistory == null) {
      return _liveLineTimes
          .map((timestamp) => timestamp.toIso8601String())
          .toList();
    }
    final stored = _selectedHistory!.outputLineTimes;
    if (stored.isNotEmpty) return stored;
    final fallbackCount = _selectedHistory!.output
        .split(RegExp(r'\r?\n'))
        .where((line) => line.isNotEmpty)
        .length;
    return List.filled(
      fallbackCount,
      _selectedHistory!.startedAt.toIso8601String(),
    );
  }
}
