import 'package:flutter/material.dart';
import 'styles.dart';

/// Shared presentation only. The parent owns draft/applied filter state.
class DashboardFilters extends StatelessWidget {
  final List<DashboardFilterField> fields;
  final VoidCallback? onApply;
  final VoidCallback? onReset;
  final bool dirty;
  final bool compact;
  final bool showReset;

  const DashboardFilters({
    super.key,
    required this.fields,
    required this.onApply,
    required this.onReset,
    this.dirty = false,
    this.compact = false,
    this.showReset = true,
  });

  Widget _compactField(DashboardFilterField field) => DashboardFilterField(
    label: field.label,
    summary: field.summary,
    onTap: field.onTap,
    compact: true,
  );

  Widget _compactLayout(double width) {
    const gap = 8.0;
    final apply = FilledButton(
      onPressed: onApply,
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.black,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 12),
        minimumSize: const Size(76, 44),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      child: const Text('Apply', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
    );
    final reset = OutlinedButton(onPressed: onReset, child: const Text('Reset'));
    if (width >= 760 && fields.length == 3) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(flex: 2, child: _compactField(fields[0])),
          const SizedBox(width: gap),
          Expanded(child: _compactField(fields[1])),
          const SizedBox(width: gap),
          Expanded(child: _compactField(fields[2])),
          const SizedBox(width: gap),
          apply,
          if (showReset) ...[const SizedBox(width: gap), reset],
        ],
      );
    }
    final twoColumns = width >= 290 && fields.length == 3;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (twoColumns) ...[
        _compactField(fields[0]),
        const SizedBox(height: gap),
        Row(children: [
          Expanded(child: _compactField(fields[1])),
          const SizedBox(width: gap),
          Expanded(child: _compactField(fields[2])),
        ]),
      ] else
        for (var i = 0; i < fields.length; i++) ...[
          if (i > 0) const SizedBox(height: gap),
          _compactField(fields[i]),
        ],
      const SizedBox(height: gap),
      Wrap(alignment: WrapAlignment.end, spacing: gap, runSpacing: gap,
        children: [if (showReset) reset, apply]),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(compact ? 10 : 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(compact ? 10 : 14),
        border: Border.all(color: AppColors.border),
      ),
      child: LayoutBuilder(
        builder: (context, bounds) {
          if (compact) return _compactLayout(bounds.maxWidth);
          const gap = 12.0;
          final width = bounds.maxWidth;
          final columns = width >= 660 ? 3 : width >= 520 ? 2 : 1;
          final itemWidth = (width - (columns - 1) * gap) / columns;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.filter_alt_outlined,
                      color: AppColors.red, size: 19),
                  SizedBox(width: 8),
                  Text('FILTERS', style: TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w800,
                    letterSpacing: 0.8, color: AppColors.black,
                  )),
                ],
              ),
              const SizedBox(height: 13),
              Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (final field in fields)
                    SizedBox(width: itemWidth, child: field),
                ],
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 10,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton.icon(
                    onPressed: onApply,
                    icon: const Icon(Icons.check_rounded, size: 18),
                    label: const Text('Apply Filters'),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.red,
                      foregroundColor: Colors.white,
                    ),
                  ),
                  if (showReset) OutlinedButton(onPressed: onReset, child: const Text('Reset')),
                  if (dirty)
                    const Text('Press Apply Filters to update the charts.',
                      style: TextStyle(fontSize: 11, color: AppColors.grey)),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

class DashboardFilterField extends StatelessWidget {
  final String label;
  final String summary;
  final VoidCallback? onTap;
  final bool compact;

  const DashboardFilterField({
    super.key,
    required this.label,
    required this.summary,
    required this.onTap,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(compact ? 8 : 10);
    final summaryText = Text(
      summary,
      overflow: TextOverflow.ellipsis,
      maxLines: 1,
      style: TextStyle(fontSize: compact ? 12 : 13, fontWeight: FontWeight.w600),
    );
    return Material(
      color: Colors.white,
      borderRadius: radius,
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: compact ? 10 : 13, vertical: compact ? 7 : 11),
          decoration: BoxDecoration(
            borderRadius: radius,
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: compact ? 10 : 11,
                  color: AppColors.grey,
                  fontWeight: FontWeight.w700,
                ),
              ),
              SizedBox(height: compact ? 2 : 4),
              Row(
                children: [
                  Expanded(
                    child: compact ? Tooltip(message: summary, child: summaryText) : summaryText,
                  ),
                  const SizedBox(width: 6),
                  Icon(
                    Icons.keyboard_arrow_down_rounded,
                    color: AppColors.grey,
                    size: compact ? 17 : 20,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
