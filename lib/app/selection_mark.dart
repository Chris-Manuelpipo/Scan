import 'package:flutter/material.dart';

/// Tinted overlay and check circle on a selectable thumbnail.
class SelectionMark extends StatelessWidget {
  const SelectionMark({super.key, required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ColoredBox(
      color: selected
          ? colors.primary.withValues(alpha: 0.25)
          : Colors.transparent,
      child: Align(
        alignment: Alignment.topRight,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(
            selected ? Icons.check_circle : Icons.radio_button_unchecked,
            color: selected ? colors.primary : Colors.white,
            shadows: const [Shadow(blurRadius: 4)],
          ),
        ),
      ),
    );
  }
}
