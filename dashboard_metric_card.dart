import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'styles.dart';

/// Shared responsive wrapping grid; Finance uses a compact card width.
class DashboardMetricGrid extends StatelessWidget {
  final List<Widget> children;
  final double? minCardWidth;
  final double gap;

  const DashboardMetricGrid({
    super.key,
    required this.children,
    this.minCardWidth,
    this.gap = 12,
  });

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(builder: (context, bounds) {
      final int columns = minCardWidth == null
          ? math.min(children.length,
              bounds.maxWidth >= 980 ? children.length :
              bounds.maxWidth >= 500 ? 2 : 1)
          : math.min(children.length, math.max(1,
              ((bounds.maxWidth + gap) / (minCardWidth! + gap)).floor()));
      final width = (bounds.maxWidth - (columns - 1) * gap) / columns;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [for (final child in children)
          SizedBox(width: width, child: child)],
      );
    });
  }
}

/// Consistent border, surface and corner radius for dashboard KPIs.
class DashboardMetricSurface extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double minHeight;
  final bool selected;
  final VoidCallback? onTap;

  const DashboardMetricSurface({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.minHeight = 108,
    this.selected = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(14);
    return Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: selected ? AppColors.red : AppColors.border,
            width: selected ? 1.5 : 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        child: Container(
          constraints: BoxConstraints(minHeight: minHeight),
          padding: padding,
          child: child,
        ),
      ),
    );
  }
}
