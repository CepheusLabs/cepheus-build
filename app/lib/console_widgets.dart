part of 'main.dart';

class _LogFilterBar extends StatelessWidget {
  const _LogFilterBar({
    required this.value,
    required this.visibleCount,
    required this.totalCount,
    required this.onChanged,
    required this.onCopyVisible,
    required this.onCopyAll,
  });

  final _LogFilter value;
  final int visibleCount;
  final int totalCount;
  final ValueChanged<_LogFilter> onChanged;
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
          message: 'Copy filtered output',
          child: ClButton.iconOnly(
            icon: ClIcons.copy,
            size: ClButtonSize.sm,
            kind: ClButtonKind.outlined,
            onPressed: onCopyVisible,
          ),
        ),
        Tooltip(
          message: 'Copy full output',
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

/// Opens the OS folder chooser (NSOpenPanel on macOS) and returns the selected
/// absolute path, or null if the user cancels. Thin wrapper over the public
/// `file_picker` API (imported by the library in `main.dart`).
Future<String?> _pickDirectory({String? dialogTitle}) async {
  final result = await FilePicker.platform.getDirectoryPath(
    dialogTitle: dialogTitle,
    lockParentWindow: true,
  );
  return (result == null || result.isEmpty) ? null : result;
}

/// A compact "browse" affordance placed beside a path text field. The field
/// stays the primary input; this only offers a folder chooser. [onPicked] is
/// invoked with the chosen path (never null). Errors are surfaced via
/// [onError]. Disabled when [enabled] is false (e.g. while a run is active).
class _FolderPickButton extends StatelessWidget {
  const _FolderPickButton({
    required this.enabled,
    required this.onPicked,
    required this.onError,
    this.dialogTitle,
  });

  final bool enabled;
  final ValueChanged<String> onPicked;
  final ValueChanged<String> onError;
  final String? dialogTitle;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Browse for folder',
      child: ClButton.iconOnly(
        icon: ClIcons.folder,
        size: ClButtonSize.sm,
        kind: ClButtonKind.outlined,
        onPressed: enabled
            ? () async {
                try {
                  final picked = await _pickDirectory(dialogTitle: dialogTitle);
                  if (picked != null) onPicked(picked);
                } on Object catch (error) {
                  onError('Folder picker failed: $error');
                }
              }
            : null,
      ),
    );
  }
}

/// Lays out a path [TextField] with a trailing [_FolderPickButton]. The text
/// field expands; the picker is a fixed-width adornment that never steals the
/// field's role as the primary input.
class _PathFieldRow extends StatelessWidget {
  const _PathFieldRow({required this.field, required this.picker});

  final Widget field;
  final Widget picker;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(child: field),
        const SizedBox(width: 8),
        picker,
      ],
    );
  }
}

/// True when [message] reads like an error worth surfacing prominently. Used by
/// [_ErrorMessageBanner] so only failures get the persistent banner treatment;
/// neutral status text stays in the status strip.
bool _messageLooksLikeError(String message) {
  final lower = message.toLowerCase();
  return lower.contains('could not') ||
      lower.contains('failed') ||
      lower.contains('error') ||
      lower.contains('not found');
}

/// A dismissible banner that renders only when [message] looks like an error.
/// Anything else collapses to nothing, leaving the status strip to report it.
class _ErrorMessageBanner extends StatelessWidget {
  const _ErrorMessageBanner({required this.message, required this.onDismiss});

  final String? message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final text = message;
    if (text == null || !_messageLooksLikeError(text)) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: ClBanner(
        kind: ClBannerKind.bad,
        title: 'Something went wrong',
        body: text,
        onDismiss: onDismiss,
      ),
    );
  }
}

/// A self-contained running indicator: a small spinner plus a live `m:ss`
/// elapsed counter that ticks every second. All timer state lives inside this
/// widget so the host State never has to own it.
class _ElapsedIndicator extends StatefulWidget {
  const _ElapsedIndicator({required this.startedAt});

  final DateTime startedAt;

  @override
  State<_ElapsedIndicator> createState() => _ElapsedIndicatorState();
}

class _ElapsedIndicatorState extends State<_ElapsedIndicator> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String get _elapsedLabel {
    final elapsed = DateTime.now().difference(widget.startedAt);
    final seconds = elapsed.inSeconds < 0 ? 0 : elapsed.inSeconds;
    final minutes = seconds ~/ 60;
    final remaining = (seconds % 60).toString().padLeft(2, '0');
    return '$minutes:$remaining';
  }

  @override
  Widget build(BuildContext context) {
    final brand = context.brandColors;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 13,
          height: 13,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation(brand.primary),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          'running $_elapsedLabel',
          style: context.dataTiny.copyWith(color: brand.ink2),
        ),
      ],
    );
  }
}

/// Presents a Forge confirmation dialog and resolves to true only when the user
/// confirms. Used to gate destructive or outward-facing actions.
Future<bool> _confirm(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Confirm',
}) async {
  final result = await ClDialog.confirm(
    context: context,
    title: title,
    body: message,
    icon: ClIcons.warning,
    confirmLabel: confirmLabel,
    confirmKind: ClButtonKind.destructive,
  );
  return result ?? false;
}
