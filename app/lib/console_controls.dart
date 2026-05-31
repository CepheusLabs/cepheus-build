part of 'main.dart';

extension _ConsoleControls on _BuildConsoleHomeState {
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
            _ErrorMessageBanner(
              message: _message,
              onDismiss: () => _setStateSafe(() => _message = null),
            ),
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
              _PathFieldRow(
                field: TextField(
                  controller: _repoRootController,
                  enabled: !_isRunning,
                  decoration: const InputDecoration(
                    hintText: 'leave empty for product config default',
                  ),
                  onChanged: (value) =>
                      _updateSettings(_settings.copyWith(repoRoot: value)),
                ),
                picker: _FolderPickButton(
                  enabled: !_isRunning,
                  dialogTitle: 'Select repo root',
                  onPicked: (picked) {
                    _repoRootController.text = picked;
                    _updateSettings(_settings.copyWith(repoRoot: picked));
                  },
                  onError: (error) =>
                      _setStateSafe(() => _message = error),
                ),
              ),
            ],
            const SizedBox(height: 14),
            _fieldLabel('Toolkit root'),
            _PathFieldRow(
              field: TextField(
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
              picker: _FolderPickButton(
                enabled: !_isRunning,
                dialogTitle: 'Select toolkit root',
                onPicked: (picked) {
                  _toolkitRootController.text = picked;
                  unawaited(_applyToolkitRoot());
                },
                onError: (error) => _setStateSafe(() => _message = error),
              ),
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
          _PathFieldRow(
            field: TextField(
              controller: _buildrootDirController,
              enabled: !_isRunning,
              decoration: const InputDecoration(
                hintText: 'optional, e.g. /opt/buildroot',
              ),
              onChanged: (value) =>
                  _updateSettings(_settings.copyWith(buildrootDir: value)),
            ),
            picker: _FolderPickButton(
              enabled: !_isRunning,
              dialogTitle: 'Select Buildroot checkout',
              onPicked: (picked) {
                _buildrootDirController.text = picked;
                _updateSettings(_settings.copyWith(buildrootDir: picked));
              },
              onError: (error) => _setStateSafe(() => _message = error),
            ),
          ),
        ],
      ],
    );
  }
}
