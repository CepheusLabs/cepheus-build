part of 'main.dart';

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
