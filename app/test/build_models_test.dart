import 'dart:convert';

import 'package:cepheus_build_gui/build_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BuildAction', () {
    test('every value maps to the expected CLI command', () {
      const expected = <BuildAction, String>{
        BuildAction.plan: 'plan',
        BuildAction.doctor: 'doctor',
        BuildAction.installDeps: 'install-deps',
        BuildAction.dryRun: 'build',
        BuildAction.build: 'build',
        BuildAction.matrix: 'ci-matrix',
        BuildAction.deployPreview: 'deploy',
        BuildAction.deploy: 'deploy',
      };
      // Guard against new enum values being added without a mapping here.
      expect(expected.keys.toSet(), BuildAction.values.toSet());
      for (final entry in expected.entries) {
        expect(entry.key.command, entry.value, reason: '${entry.key} command');
      }
    });

    test('dryRun and build share the "build" command', () {
      expect(BuildAction.dryRun.command, 'build');
      expect(BuildAction.build.command, 'build');
    });

    test('deploy and deployPreview share the "deploy" command', () {
      expect(BuildAction.deploy.command, 'deploy');
      expect(BuildAction.deployPreview.command, 'deploy');
    });

    test('every value has a non-empty label', () {
      for (final action in BuildAction.values) {
        expect(action.label, isNotEmpty, reason: '${action.name} label');
      }
    });
  });

  group('ExecutionMode', () {
    test('fromValue resolves known values', () {
      expect(ExecutionMode.fromValue('github'), ExecutionMode.github);
      expect(ExecutionMode.fromValue('local'), ExecutionMode.local);
    });

    test('fromValue falls back to local for unknown/empty values', () {
      expect(ExecutionMode.fromValue('nonsense'), ExecutionMode.local);
      expect(ExecutionMode.fromValue(''), ExecutionMode.local);
    });

    test('value/label round-trip via fromValue', () {
      for (final mode in ExecutionMode.values) {
        expect(ExecutionMode.fromValue(mode.value), mode);
        expect(mode.label, isNotEmpty);
      }
      expect(ExecutionMode.local.value, 'local');
      expect(ExecutionMode.github.value, 'github');
      expect(ExecutionMode.local.label, 'Local');
      expect(ExecutionMode.github.label, 'GitHub');
    });
  });

  group('BuildSettings.defaults', () {
    final defaults = BuildSettings.defaults(toolkitRoot: '/tmp/toolkit');

    test('carries the requested toolkitRoot', () {
      expect(defaults.toolkitRoot, '/tmp/toolkit');
    });

    test('has the documented default values', () {
      expect(defaults.product, 'printdeck-app');
      expect(defaults.targets, 'all');
      expect(defaults.executionMode, ExecutionMode.local);
      expect(defaults.runnerProfile, 'github-hosted');
      expect(defaults.buildMode, 'release');
      expect(defaults.repoRoot, '');
      expect(defaults.githubRepo, '');
      expect(defaults.githubWorkflow, 'shared-build.yml');
      expect(defaults.buildrootDir, '');
      expect(defaults.setupBuildrootDeps, isTrue);
      expect(defaults.skipUnsupported, isTrue);
      expect(defaults.keepGoing, isTrue);
      expect(defaults.store, '');
      expect(defaults.themeMode, 'dark');
    });
  });

  group('BuildSettings JSON', () {
    test('toJson includes toolkitRoot and themeMode keys (regression guard)', () {
      final json = BuildSettings.defaults(toolkitRoot: '/tmp/root').toJson();
      // Item #3 / #15 regression: these keys MUST be persisted.
      expect(json.containsKey('toolkitRoot'), isTrue,
          reason: 'toJson must persist toolkitRoot');
      expect(json.containsKey('themeMode'), isTrue,
          reason: 'toJson must persist themeMode');
      expect(json['toolkitRoot'], '/tmp/root');
      expect(json['themeMode'], 'dark');
    });

    test('defaults -> toJson -> fromJson preserves every field', () {
      final original = BuildSettings.defaults(toolkitRoot: '/tmp/root');
      final restored = BuildSettings.fromJson(
        original.toJson(),
        fallbackToolkitRoot: '/unused/fallback',
      );

      expect(restored.toolkitRoot, original.toolkitRoot);
      expect(restored.product, original.product);
      expect(restored.targets, original.targets);
      expect(restored.executionMode, original.executionMode);
      expect(restored.runnerProfile, original.runnerProfile);
      expect(restored.buildMode, original.buildMode);
      expect(restored.repoRoot, original.repoRoot);
      expect(restored.githubRepo, original.githubRepo);
      expect(restored.githubWorkflow, original.githubWorkflow);
      expect(restored.buildrootDir, original.buildrootDir);
      expect(restored.setupBuildrootDeps, original.setupBuildrootDeps);
      expect(restored.skipUnsupported, original.skipUnsupported);
      expect(restored.keepGoing, original.keepGoing);
      expect(restored.store, original.store);
      expect(restored.themeMode, original.themeMode);
    });

    test('round-trips a fully non-default configuration', () {
      const original = BuildSettings(
        toolkitRoot: '/opt/cepheus',
        product: 'anvil',
        targets: 'desktop',
        executionMode: ExecutionMode.github,
        runnerProfile: 'self-hosted',
        buildMode: 'debug',
        repoRoot: '/repos/anvil',
        githubRepo: 'cepheus/anvil',
        githubWorkflow: 'custom.yml',
        buildrootDir: 'buildroot',
        setupBuildrootDeps: false,
        skipUnsupported: false,
        keepGoing: false,
        store: 'play',
        themeMode: 'system',
      );

      final restored = BuildSettings.fromJson(
        original.toJson(),
        fallbackToolkitRoot: '/unused',
      );

      expect(restored.toolkitRoot, '/opt/cepheus');
      expect(restored.product, 'anvil');
      expect(restored.targets, 'desktop');
      expect(restored.executionMode, ExecutionMode.github);
      expect(restored.runnerProfile, 'self-hosted');
      expect(restored.buildMode, 'debug');
      expect(restored.repoRoot, '/repos/anvil');
      expect(restored.githubRepo, 'cepheus/anvil');
      expect(restored.githubWorkflow, 'custom.yml');
      expect(restored.buildrootDir, 'buildroot');
      expect(restored.setupBuildrootDeps, isFalse);
      expect(restored.skipUnsupported, isFalse);
      expect(restored.keepGoing, isFalse);
      expect(restored.store, 'play');
      expect(restored.themeMode, 'system');
    });

    test('fromJson on an empty map yields defaults (with fallback root)', () {
      final restored = BuildSettings.fromJson(
        const {},
        fallbackToolkitRoot: '/fallback/root',
      );
      final defaults = BuildSettings.defaults(toolkitRoot: '/fallback/root');

      expect(restored.toolkitRoot, '/fallback/root');
      expect(restored.product, defaults.product);
      expect(restored.targets, defaults.targets);
      expect(restored.executionMode, defaults.executionMode);
      expect(restored.runnerProfile, defaults.runnerProfile);
      expect(restored.buildMode, defaults.buildMode);
      expect(restored.githubWorkflow, defaults.githubWorkflow);
      expect(restored.setupBuildrootDeps, defaults.setupBuildrootDeps);
      expect(restored.skipUnsupported, defaults.skipUnsupported);
      expect(restored.keepGoing, defaults.keepGoing);
      expect(restored.themeMode, defaults.themeMode);
    });

    test('fromJson uses fallbackToolkitRoot when toolkitRoot is missing', () {
      final restored = BuildSettings.fromJson(
        const {'product': 'foundry'},
        fallbackToolkitRoot: '/from/fallback',
      );
      expect(restored.toolkitRoot, '/from/fallback');
      expect(restored.product, 'foundry');
    });

    test('fromJson with an unknown executionMode string defaults to local', () {
      final restored = BuildSettings.fromJson(
        const {'executionMode': 'banana'},
        fallbackToolkitRoot: '/x',
      );
      expect(restored.executionMode, ExecutionMode.local);
    });

    test('fromJson with missing themeMode defaults to dark', () {
      final restored = BuildSettings.fromJson(
        const {'product': 'deckhand'},
        fallbackToolkitRoot: '/x',
      );
      expect(restored.themeMode, 'dark');
    });

    test('fromJson with an invalid themeMode falls back to dark', () {
      final restored = BuildSettings.fromJson(
        const {'themeMode': 'neon'},
        fallbackToolkitRoot: '/x',
      );
      expect(restored.themeMode, 'dark');
    });

    test('fromJson accepts each valid themeMode value verbatim', () {
      for (final mode in const ['light', 'dark', 'system']) {
        final restored = BuildSettings.fromJson(
          {'themeMode': mode},
          fallbackToolkitRoot: '/x',
        );
        expect(restored.themeMode, mode);
      }
    });

    test('fromJson tolerates wrong-typed boolean fields by defaulting', () {
      final restored = BuildSettings.fromJson(
        const {
          'setupBuildrootDeps': 'yes',
          'skipUnsupported': 0,
          'keepGoing': 'true',
        },
        fallbackToolkitRoot: '/x',
      );
      // Non-bool values are ignored and the defaults (true) are kept.
      expect(restored.setupBuildrootDeps, isTrue);
      expect(restored.skipUnsupported, isTrue);
      expect(restored.keepGoing, isTrue);
    });

    test('fromJson honours explicit false booleans', () {
      final restored = BuildSettings.fromJson(
        const {
          'setupBuildrootDeps': false,
          'skipUnsupported': false,
          'keepGoing': false,
        },
        fallbackToolkitRoot: '/x',
      );
      expect(restored.setupBuildrootDeps, isFalse);
      expect(restored.skipUnsupported, isFalse);
      expect(restored.keepGoing, isFalse);
    });
  });

  group('BuildSettings.copyWith', () {
    final base = BuildSettings.defaults(toolkitRoot: '/base');

    test('returns an unchanged copy when no arguments are given', () {
      final copy = base.copyWith();
      expect(copy.toJson(), base.toJson());
    });

    test('changes only the specified field (product)', () {
      final copy = base.copyWith(product: 'anvil');
      expect(copy.product, 'anvil');
      // Everything else is untouched.
      final expected = base.toJson()..['product'] = 'anvil';
      expect(copy.toJson(), expected);
    });

    test('changes only the specified field (executionMode)', () {
      final copy = base.copyWith(executionMode: ExecutionMode.github);
      expect(copy.executionMode, ExecutionMode.github);
      final expected = base.toJson()..['executionMode'] = 'github';
      expect(copy.toJson(), expected);
    });

    test('changes only the specified field (themeMode)', () {
      final copy = base.copyWith(themeMode: 'light');
      expect(copy.themeMode, 'light');
      final expected = base.toJson()..['themeMode'] = 'light';
      expect(copy.toJson(), expected);
    });

    test('can flip a boolean flag in isolation', () {
      final copy = base.copyWith(keepGoing: false);
      expect(copy.keepGoing, isFalse);
      expect(copy.skipUnsupported, base.skipUnsupported);
      expect(copy.setupBuildrootDeps, base.setupBuildrootDeps);
    });
  });

  group('BuildHistoryEntry', () {
    BuildHistoryEntry entryWith({int exitCode = 0, int durationMs = 0}) {
      return BuildHistoryEntry(
        id: 'id-1',
        action: BuildAction.build,
        product: 'printdeck-app',
        targets: 'all',
        executionMode: ExecutionMode.local,
        runnerProfile: 'github-hosted',
        buildMode: 'release',
        repoRoot: '/repo',
        githubRepo: 'cepheus/printdeck-app',
        store: '',
        command: 'cepheus-build build -p printdeck-app all',
        startedAt: DateTime.utc(2026, 5, 30, 12, 0, 0),
        durationMs: durationMs,
        exitCode: exitCode,
        output: 'log output',
        outputLineTimes: const ['12:00:00', '12:00:01'],
      );
    }

    test('succeeded is true iff exitCode == 0', () {
      expect(entryWith(exitCode: 0).succeeded, isTrue);
      expect(entryWith(exitCode: 1).succeeded, isFalse);
      expect(entryWith(exitCode: -1).succeeded, isFalse);
    });

    test('status reflects success/failure', () {
      expect(entryWith(exitCode: 0).status, 'complete');
      expect(entryWith(exitCode: 2).status, 'error');
    });

    test('durationLabel formats sub-minute durations as S.mmms', () {
      expect(entryWith(durationMs: 0).durationLabel, '0.000s');
      expect(entryWith(durationMs: 1500).durationLabel, '1.500s');
      expect(entryWith(durationMs: 12345).durationLabel, '12.345s');
      // Just under a minute stays in the seconds format.
      expect(entryWith(durationMs: 59999).durationLabel, '59.999s');
    });

    test('durationLabel formats >= 1 minute as "Nm SSs"', () {
      expect(entryWith(durationMs: 60000).durationLabel, '1m 00s');
      expect(entryWith(durationMs: 65000).durationLabel, '1m 05s');
      expect(entryWith(durationMs: 125000).durationLabel, '2m 05s');
      // Milliseconds are dropped once we cross into the minutes branch.
      expect(entryWith(durationMs: 90500).durationLabel, '1m 30s');
    });

    test('toJson -> fromJson preserves every field', () {
      final original = entryWith(exitCode: 3, durationMs: 65000);
      final restored = BuildHistoryEntry.fromJson(original.toJson());

      expect(restored.id, original.id);
      expect(restored.action, original.action);
      expect(restored.product, original.product);
      expect(restored.targets, original.targets);
      expect(restored.executionMode, original.executionMode);
      expect(restored.runnerProfile, original.runnerProfile);
      expect(restored.buildMode, original.buildMode);
      expect(restored.repoRoot, original.repoRoot);
      expect(restored.githubRepo, original.githubRepo);
      expect(restored.store, original.store);
      expect(restored.command, original.command);
      expect(restored.startedAt, original.startedAt);
      expect(restored.durationMs, original.durationMs);
      expect(restored.exitCode, original.exitCode);
      expect(restored.output, original.output);
      expect(restored.outputLineTimes, original.outputLineTimes);
    });

    test('fromJson on empty map uses safe fallbacks', () {
      final restored = BuildHistoryEntry.fromJson(const {});
      expect(restored.id, '');
      expect(restored.action, BuildAction.plan); // default action
      expect(restored.executionMode, ExecutionMode.local);
      expect(restored.runnerProfile, 'github-hosted');
      expect(restored.buildMode, 'release');
      expect(restored.durationMs, 0);
      // Missing exitCode is treated as a failure (1), not success.
      expect(restored.exitCode, 1);
      expect(restored.succeeded, isFalse);
      expect(restored.outputLineTimes, isEmpty);
      // Unparseable startedAt becomes the epoch.
      expect(restored.startedAt, DateTime.fromMillisecondsSinceEpoch(0));
    });

    test('fromJson resolves action by enum name and falls back to plan', () {
      expect(
        BuildHistoryEntry.fromJson(const {'action': 'matrix'}).action,
        BuildAction.matrix,
      );
      expect(
        BuildHistoryEntry.fromJson(const {'action': 'not-a-real-action'}).action,
        BuildAction.plan,
      );
    });
  });

  group('BuildHistorySnapshot', () {
    BuildHistoryEntry makeEntry(String id, int exitCode) {
      return BuildHistoryEntry(
        id: id,
        action: BuildAction.plan,
        product: 'printdeck-app',
        targets: 'all',
        executionMode: ExecutionMode.local,
        runnerProfile: 'github-hosted',
        buildMode: 'release',
        repoRoot: '',
        githubRepo: '',
        store: '',
        command: 'cepheus-build plan -p printdeck-app all',
        startedAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
        durationMs: 4200,
        exitCode: exitCode,
        output: 'output for $id',
        outputLineTimes: const [],
      );
    }

    test('toPrettyJson -> fromJson preserves settings and entries', () {
      final snapshot = BuildHistorySnapshot(
        settings: BuildSettings.defaults(toolkitRoot: '/root')
            .copyWith(product: 'anvil', themeMode: 'light'),
        entries: [makeEntry('a', 0), makeEntry('b', 1)],
      );

      final decoded =
          jsonDecode(snapshot.toPrettyJson()) as Map<String, dynamic>;
      final restored = BuildHistorySnapshot.fromJson(
        decoded,
        fallbackToolkitRoot: '/unused',
      );

      expect(restored.settings.product, 'anvil');
      expect(restored.settings.themeMode, 'light');
      expect(restored.settings.toolkitRoot, '/root');
      expect(restored.entries, hasLength(2));
      expect(restored.entries[0].id, 'a');
      expect(restored.entries[0].succeeded, isTrue);
      expect(restored.entries[1].id, 'b');
      expect(restored.entries[1].succeeded, isFalse);
      expect(restored.entries[1].output, 'output for b');
    });

    test('toPrettyJson emits indented JSON', () {
      final snapshot = BuildHistorySnapshot(
        settings: BuildSettings.defaults(toolkitRoot: '/root'),
        entries: const [],
      );
      final pretty = snapshot.toPrettyJson();
      expect(pretty, contains('\n'));
      expect(pretty, contains('  "settings"'));
      expect(pretty, contains('"entries"'));
    });

    test('fromJson on an empty map yields empty entries + default settings', () {
      final restored = BuildHistorySnapshot.fromJson(
        const {},
        fallbackToolkitRoot: '/fallback',
      );
      expect(restored.entries, isEmpty);
      expect(restored.settings.toolkitRoot, '/fallback');
      expect(restored.settings.product, 'printdeck-app');
      expect(restored.settings.themeMode, 'dark');
    });

    test('fromJson tolerates malformed entries/settings without throwing', () {
      final restored = BuildHistorySnapshot.fromJson(
        const {
          'settings': 'not-a-map',
          'entries': 'not-a-list',
        },
        fallbackToolkitRoot: '/fallback',
      );
      expect(restored.entries, isEmpty);
      expect(restored.settings.toolkitRoot, '/fallback');
      expect(restored.settings.product, 'printdeck-app');
    });

    test('fromJson skips non-map elements inside the entries list', () {
      final restored = BuildHistorySnapshot.fromJson(
        {
          'entries': [
            makeEntry('keep', 0).toJson(),
            'garbage',
            42,
          ],
        },
        fallbackToolkitRoot: '/x',
      );
      expect(restored.entries, hasLength(1));
      expect(restored.entries.single.id, 'keep');
    });
  });
}
