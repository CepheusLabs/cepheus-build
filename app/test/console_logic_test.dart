import 'package:cepheus_build_gui/build_models.dart';
import 'package:cepheus_build_gui/console_logic.dart';
import 'package:flutter_test/flutter_test.dart';

/// A settings object with sensible test defaults; override per-case via copyWith.
BuildSettings _settings({
  String product = 'printdeck-app',
  String targets = 'all',
  ExecutionMode executionMode = ExecutionMode.local,
  String runnerProfile = 'github-hosted',
  String containerProfile = 'default',
  String buildMode = 'release',
  String repoRoot = '',
  String githubRepo = '',
  String githubWorkflow = 'shared-build.yml',
  String buildrootDir = '',
  bool setupBuildrootDeps = true,
  bool skipUnsupported = true,
  bool keepGoing = true,
  String store = '',
}) {
  return BuildSettings(
    toolkitRoot: '/toolkit',
    product: product,
    targets: targets,
    executionMode: executionMode,
    runnerProfile: runnerProfile,
    containerProfile: containerProfile,
    buildMode: buildMode,
    repoRoot: repoRoot,
    githubRepo: githubRepo,
    githubWorkflow: githubWorkflow,
    buildrootDir: buildrootDir,
    setupBuildrootDeps: setupBuildrootDeps,
    skipUnsupported: skipUnsupported,
    keepGoing: keepGoing,
    store: store,
    themeMode: 'dark',
  );
}

void main() {
  // -------------------------------------------------------------------------
  // targetArgs
  // -------------------------------------------------------------------------
  group('targetArgs', () {
    test('empty string defaults to all', () {
      expect(targetArgs(''), ['all']);
      expect(targetArgs('   '), ['all']);
    });

    test('single target', () {
      expect(targetArgs('macos'), ['macos']);
    });

    test('splits on whitespace and drops blanks', () {
      expect(targetArgs('macos  web   android'), ['macos', 'web', 'android']);
    });
  });

  // -------------------------------------------------------------------------
  // storeArg
  // -------------------------------------------------------------------------
  group('storeArg', () {
    test('returns trimmed store name', () {
      expect(storeArg(_settings(store: '  google_play ')), 'google_play');
    });
  });

  // -------------------------------------------------------------------------
  // cliArgsFor — per action
  // -------------------------------------------------------------------------
  group('cliArgsFor', () {
    test('plan: product + targets', () {
      final args = cliArgsFor(_settings(targets: 'all'), BuildAction.plan);
      expect(args, ['plan', '-p', 'printdeck-app', 'all']);
    });

    test('doctor mirrors plan (shared switch arm)', () {
      final plan = cliArgsFor(_settings(), BuildAction.plan);
      final doctor = cliArgsFor(_settings(), BuildAction.doctor);
      expect(doctor.first, 'doctor');
      expect(doctor.sublist(1), plan.sublist(1));
    });

    test('repoRoot override is injected when set', () {
      final args = cliArgsFor(
        _settings(repoRoot: '/work/printdeck-app', targets: 'web'),
        BuildAction.plan,
      );
      expect(args, ['plan', '-p', 'printdeck-app', '--repo-root', '/work/printdeck-app', 'web']);
    });

    test('installDeps adds --skip-unsupported when set, omits when not', () {
      expect(
        cliArgsFor(_settings(skipUnsupported: true, targets: 'desktop'),
            BuildAction.installDeps),
        contains('--skip-unsupported'),
      );
      expect(
        cliArgsFor(_settings(skipUnsupported: false, targets: 'desktop'),
            BuildAction.installDeps),
        isNot(contains('--skip-unsupported')),
      );
    });

    test('matrix adds runner-profile + --pretty', () {
      final args = cliArgsFor(
        _settings(runnerProfile: 'self-hosted', targets: 'all'),
        BuildAction.matrix,
      );
      expect(args, [
        'ci-matrix', '-p', 'printdeck-app',
        '--runner-profile', 'self-hosted', '--pretty', 'all',
      ]);
    });

    test('dryRun build (local) includes --dry-run and --mode', () {
      final args = cliArgsFor(
        _settings(buildMode: 'release', targets: 'macos'),
        BuildAction.dryRun,
      );
      expect(args.first, 'build');
      expect(args, contains('--dry-run'));
      expect(args, containsAllInOrder(['--mode', 'release']));
      expect(args, isNot(contains('--install-missing-deps')));
      expect(args.last, 'macos');
    });

    test('real build (local) adds --install-missing-deps, no --dry-run', () {
      final args = cliArgsFor(_settings(targets: 'macos'), BuildAction.build);
      expect(args, contains('--install-missing-deps'));
      expect(args, isNot(contains('--dry-run')));
    });

    test('local build respects keepGoing flag', () {
      expect(
        cliArgsFor(_settings(keepGoing: true), BuildAction.build),
        contains('--keep-going'),
      );
      expect(
        cliArgsFor(_settings(keepGoing: false), BuildAction.build),
        contains('--no-keep-going'),
      );
    });

    test('deploy: positional store, no --dry-run', () {
      final args = cliArgsFor(
        _settings(store: 'google_play'),
        BuildAction.deploy,
      );
      expect(args, ['deploy', '-p', 'printdeck-app', 'google_play']);
    });

    test('deployPreview: store + --dry-run', () {
      final args = cliArgsFor(
        _settings(store: 'google_play'),
        BuildAction.deployPreview,
      );
      expect(args, ['deploy', '-p', 'printdeck-app', 'google_play', '--dry-run']);
    });
  });

  // -------------------------------------------------------------------------
  // buildModeArgs — github & foundry specifics
  // -------------------------------------------------------------------------
  group('buildModeArgs (github mode)', () {
    test('includes runner-profile and execution-mode github', () {
      final args = buildModeArgs(
        _settings(executionMode: ExecutionMode.github, runnerProfile: 'self-hosted'),
        dryRun: false,
      );
      expect(args, containsAllInOrder(['--execution-mode', 'github']));
      expect(args, containsAllInOrder(['--runner-profile', 'self-hosted']));
      // github mode never installs local deps
      expect(args, isNot(contains('--install-missing-deps')));
    });

    test('passes github-repo and workflow when set', () {
      final args = buildModeArgs(
        _settings(
          executionMode: ExecutionMode.github,
          githubRepo: 'CepheusLabs/printdeck-app',
          githubWorkflow: 'shared-build.yml',
        ),
        dryRun: false,
      );
      expect(args, containsAllInOrder(['--github-repo', 'CepheusLabs/printdeck-app']));
      expect(args, containsAllInOrder(['--github-workflow', 'shared-build.yml']));
    });

    test('foundry in github mode adds buildroot deps flag + dir', () {
      final on = buildModeArgs(
        _settings(
          product: 'foundry',
          executionMode: ExecutionMode.github,
          setupBuildrootDeps: true,
          buildrootDir: '/opt/buildroot',
        ),
        dryRun: false,
      );
      expect(on, contains('--setup-buildroot-deps'));
      expect(on, containsAllInOrder(['--buildroot-dir', '/opt/buildroot']));

      final off = buildModeArgs(
        _settings(
          product: 'foundry',
          executionMode: ExecutionMode.github,
          setupBuildrootDeps: false,
        ),
        dryRun: false,
      );
      expect(off, contains('--no-setup-buildroot-deps'));
    });

    test('non-foundry github mode has no buildroot flags', () {
      final args = buildModeArgs(
        _settings(product: 'printdeck-app', executionMode: ExecutionMode.github),
        dryRun: false,
      );
      expect(args.where((a) => a.contains('buildroot')), isEmpty);
    });

    test('container mode passes container-profile and mode', () {
      final args = buildModeArgs(
        _settings(
          executionMode: ExecutionMode.container,
          containerProfile: 'default',
          buildMode: 'release',
        ),
        dryRun: false,
      );
      expect(args, containsAllInOrder(['--execution-mode', 'container']));
      expect(args, containsAllInOrder(['--container-profile', 'default']));
      expect(args, containsAllInOrder(['--mode', 'release']));
      // The container/VM is pre-provisioned: never install deps on the dispatch host.
      expect(args, isNot(contains('--install-missing-deps')));
      // No GitHub-only flags leak in.
      expect(args, isNot(contains('--runner-profile')));
    });

    test('container mode threads keep-going toggle', () {
      final keep = buildModeArgs(
        _settings(executionMode: ExecutionMode.container, keepGoing: true),
        dryRun: false,
      );
      expect(keep, contains('--keep-going'));
      final stop = buildModeArgs(
        _settings(executionMode: ExecutionMode.container, keepGoing: false),
        dryRun: false,
      );
      expect(stop, contains('--no-keep-going'));
    });

    test('foundry in local mode still threads buildroot-dir', () {
      final args = buildModeArgs(
        _settings(product: 'foundry', buildrootDir: '/opt/br'),
        dryRun: false,
      );
      expect(args, containsAllInOrder(['--buildroot-dir', '/opt/br']));
    });
  });

  // -------------------------------------------------------------------------
  // redactSecrets
  // -------------------------------------------------------------------------
  group('redactSecrets', () {
    test('leaves an ordinary command untouched', () {
      const cmd = 'bin/cepheus-build build -p printdeck-app --mode release macos';
      expect(redactSecrets(cmd), cmd);
    });

    test('does NOT mask env-var references', () {
      const cmd = 'deploy google_play --service-account \$GOOGLE_PLAY_SA_JSON';
      expect(redactSecrets(cmd), cmd);
    });

    test('masks inline value after a sensitive flag', () {
      final out = redactSecrets('--token abcdefghijklmnopqrstuvwxyz');
      expect(out, '--token ***');
    });

    test('masks KEY=inline-json form', () {
      final out = redactSecrets('SERVICE_ACCOUNT_KEY={"type":"service_account"}');
      expect(out, 'SERVICE_ACCOUNT_KEY=***');
    });

    test('masks --flag=secret form', () {
      final out = redactSecrets('--api-key=0123456789abcdef0123456789');
      expect(out, '--api-key=***');
    });

    test('masks a bare long secret blob', () {
      final out = redactSecrets('echo AKIA0123456789ABCDEFGHIJ');
      expect(out, 'echo ***');
    });

    test('does not mask short non-secret tokens or paths', () {
      const cmd = 'deploy -p anvil /home/u/key.json owner/repo';
      // path contains '/', owner/repo contains '/', neither is a bare blob
      expect(redactSecrets(cmd), cmd);
    });

    test('does not mask a non-sensitive flag with a long value', () {
      const cmd = '--workflow shared-build-pipeline.yml';
      expect(redactSecrets(cmd), cmd);
    });
  });

  // -------------------------------------------------------------------------
  // truncateOutput
  // -------------------------------------------------------------------------
  group('truncateOutput', () {
    test('returns input unchanged when under both caps', () {
      const out = 'line1\nline2\nline3';
      expect(truncateOutput(out, maxLines: 100, maxChars: 1000), out);
    });

    test('keeps the tail and adds a marker when over line cap', () {
      final out = List.generate(50, (i) => 'line$i').join('\n');
      final result = truncateOutput(out, maxLines: 10, maxChars: 100000);
      expect(result, startsWith('… [output truncated:'));
      expect(result, contains('line49')); // tail retained
      expect(result, isNot(contains('\nline0\n'))); // head dropped
    });

    test('respects char cap', () {
      final out = 'x' * 5000;
      final result = truncateOutput(out, maxLines: 100000, maxChars: 1000);
      expect(result, startsWith('… [output truncated:'));
      // marker + newline + <=1000 tail chars
      expect(result.length, lessThan(1100));
    });
  });

}
