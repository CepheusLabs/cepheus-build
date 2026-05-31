part of 'main.dart';

extension _ConsolePanels on _BuildConsoleHomeState {
  /// Confirms a real store submission before running it. Preview stays
  /// immediate; only the outward-facing [BuildAction.deploy] is gated.
  Future<void> _confirmAndDeploy() async {
    final store = _selectedStore?.name ?? _settings.store;
    final confirmed = await _confirm(
      context,
      title: 'Deploy to store',
      message:
          'Product: ${_settings.product}\nStore: $store\n\n'
          'This submits to the store. Continue?',
      confirmLabel: 'Deploy',
    );
    if (!confirmed || !mounted) return;
    _run(BuildAction.deploy);
  }

  /// Confirms clearing the local run history, which cannot be undone.
  Future<void> _confirmAndClearHistory() async {
    final confirmed = await _confirm(
      context,
      title: 'Clear history',
      message: 'Clear all run history? This cannot be undone.',
      confirmLabel: 'Clear',
    );
    if (!confirmed || !mounted) return;
    unawaited(_clearHistory());
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
                onPressed: canDeploy
                    ? () => unawaited(_confirmAndDeploy())
                    : null,
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
    final allEntries = _logEntries(
      _visibleOutput,
      lineTimes: _visibleOutputLineTimes,
    );
    final visibleEntries = allEntries
        .where((entry) => _logFilter.accepts(entry))
        .toList();
    // The flattened log text is only needed when a copy button is pressed, so
    // build it lazily inside the callbacks instead of joining the whole log on
    // every (throttled) live rebuild. Each entry carries a non-empty message,
    // so an empty entries list is the only way the text would be empty.

    return ClPanel(
      fillParent: true,
      head: ClPanelHead(
        icon: ClIcons.terminal,
        title: title,
        count: subtitle,
        tools: [
          if (_isRunning && _startedAt != null)
            _ElapsedIndicator(startedAt: _startedAt!),
          if (_selectedHistory != null)
            ClFilterPill(
              active: !_showLiveOutput,
              onTap: () => _setStateSafe(() => _showLiveOutput = false),
              label: 'Selected',
            ),
          ClFilterPill(
            active: _showLiveOutput,
            onTap: () => _setStateSafe(() => _showLiveOutput = true),
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
              onChanged: (value) => _setStateSafe(() => _logFilter = value),
              onCopyVisible: visibleEntries.isEmpty
                  ? null
                  : () => unawaited(
                      _copyLogText(
                        _logTextForEntries(visibleEntries),
                        'Visible log',
                      ),
                    ),
              onCopyAll: allEntries.isEmpty
                  ? null
                  : () => unawaited(
                      _copyLogText(_logTextForEntries(allEntries), 'Full log'),
                    ),
            ),
          ),
          Expanded(
            child: ClLogView(
              controller: _logScrollController,
              entries: visibleEntries,
              emptyMessage: allEntries.isEmpty
                  ? 'No output yet. Run plan, matrix, dry-run, or build.'
                  : 'No lines match ${_logFilter.label}.',
              padding: const EdgeInsets.fromLTRB(0, 8, 0, 28),
              timeColumnWidth: 72,
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
              onPressed: _history.isEmpty || _isRunning
                  ? null
                  : () => unawaited(_confirmAndClearHistory()),
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
                    _setStateSafe(() {
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
