import 'package:flutter/material.dart';

/// Reusable, read-only month-by-month history presentation.
/// The parent page supplies records that have already been filtered by
/// property, reporting month, and the user's search/filter selections.
class MonthlyHistorySection<T> extends StatelessWidget {
  const MonthlyHistorySection({
    super.key,
    required this.recordsByMonth,
    required this.recordBuilder,
    this.itemName = 'record',
    this.sectionId = 'history',
  });

  /// Example: {'October 2026': [item1, item2]}.
  final Map<String, List<T>> recordsByMonth;
  final Widget Function(String month, T record, int number) recordBuilder;
  final String itemName;
  final String sectionId;

  static DateTime _parseMonth(String label) {
    const names = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December',
    ];
    final parts = label.trim().split(RegExp(r'\s+'));
    if (parts.length != 2) return DateTime(1900);
    final month = names.indexOf(parts.first) + 1;
    final year = int.tryParse(parts.last);
    if (month == 0 || year == null) return DateTime(1900);
    return DateTime(year, month);
  }

  @override
  Widget build(BuildContext context) {
    if (recordsByMonth.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text('No historical records found.'),
      );
    }

    final groups = recordsByMonth.entries.toList()
      ..sort((a, b) => _parseMonth(b.key).compareTo(_parseMonth(a.key)));

    return Column(
      children: [
        for (final group in groups)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFE0E0E0)),
              ),
              child: ExpansionTile(
                key: PageStorageKey<String>('$sectionId-${group.key}'),
                shape: const Border(),
                collapsedShape: const Border(),
                title: Text(group.key,
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Text(
                  '${group.value.length} $itemName${group.value.length == 1 ? '' : 's'}',
                ),
                childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                children: [
                  for (var i = 0; i < group.value.length; i++)
                    recordBuilder(group.key, group.value[i], i + 1),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
