import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../widgets/styles.dart';

/// The monthly reports whose records are visible from the open report:
/// the open report itself plus earlier reports of the SAME property.
class HistoricalScope {
  final Set<String> reportIds;
  final Map<String, DateTime?> months;
  final String? notice;

  const HistoricalScope({
    required this.reportIds,
    required this.months,
    this.notice,
  });
}

class HistoricalRecords {
  HistoricalRecords._();

  static const List<String> _monthNames = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];

  static String monthLabel(DateTime month) =>
      '${_monthNames[month.month - 1]} ${month.year}';

  static DateTime? monthOf(Map<String, dynamic> report) {
    final raw =
        report['report_month'] ?? report['month'] ?? report['report_date'];

    if (raw == null) return null;

    final parsed = DateTime.tryParse(raw.toString());
    if (parsed == null) return null;

    return DateTime(parsed.year, parsed.month);
  }

  static DateTime? parseDate(dynamic value) {
    if (value == null) return null;

    final parsed = DateTime.tryParse(value.toString());
    if (parsed == null) return null;

    return DateTime(parsed.year, parsed.month, parsed.day);
  }

  static String formatDate(DateTime date) =>
      '${date.day.toString().padLeft(2, '0')}/'
      '${date.month.toString().padLeft(2, '0')}/'
      '${date.year}';

  /// Inclusive date-range test. With no range set everything matches; with a
  /// range set, a record that has no date cannot match.
  static bool inRange(dynamic value, DateTime? from, DateTime? to) {
    if (from == null && to == null) return true;

    final date = parseDate(value);
    if (date == null) return false;

    if (from != null && date.isBefore(from)) return false;
    if (to != null && date.isAfter(to)) return false;

    return true;
  }

  /// Finds the open report plus earlier reports of the same property
  /// (monthly_reports.site_id). Nothing is copied or created.
  static Future<HistoricalScope> loadScope(
    SupabaseClient supabase,
    Map<String, dynamic> report,
  ) async {
    final reportId = report['id']?.toString() ?? '';
    final siteId = report['site_id']?.toString() ?? '';
    final currentMonth = monthOf(report);

    final ids = <String>{reportId};
    final months = <String, DateTime?>{reportId: currentMonth};
    String? notice;

    if (siteId.isEmpty) {
      notice = 'This report has no property (site) ID, so only this '
          'report\'s records are shown.';
    } else if (currentMonth == null) {
      notice = 'This report has no reporting month, so earlier months '
          'cannot be determined.';
    } else {
      try {
        final reports = await supabase
            .from('monthly_reports')
            .select()
            .eq('site_id', siteId);

        for (final raw in reports) {
          final other = Map<String, dynamic>.from(raw as Map);
          final id = other['id']?.toString();

          if (id == null || id.isEmpty || id == reportId) continue;

          final month = monthOf(other);

          if (month != null && !month.isAfter(currentMonth)) {
            ids.add(id);
            months[id] = month;
          }
        }
      } catch (e) {
        notice = 'Earlier months could not be loaded: $e';
      }
    }

    return HistoricalScope(reportIds: ids, months: months, notice: notice);
  }

  /// Orders carried-forward rows: most recent earlier month first, then by
  /// line number within each month.
  static int compareCarried(
    Map<String, dynamic> a,
    Map<String, dynamic> b,
    Map<String, DateTime?> months,
  ) {
    final ma = months[a['report_id']?.toString()];
    final mb = months[b['report_id']?.toString()];

    if (ma != null && mb != null && ma != mb) return mb.compareTo(ma);

    final la = (a['line_no'] as num?)?.toInt() ?? 0;
    final lb = (b['line_no'] as num?)?.toInt() ?? 0;

    return la.compareTo(lb);
  }

  /// Builds the filter bar, the "This month" group and the "Carried forward"
  /// group for a list page. [current] and [carried] must already be
  /// date-filtered by the caller.
  static List<Widget> buildList({
    required BuildContext context,
    required String dateLabel,
    required DateTime? from,
    required DateTime? to,
    required ValueChanged<DateTime?> onFromChanged,
    required ValueChanged<DateTime?> onToChanged,
    required VoidCallback onClear,
    required List<Map<String, dynamic>> current,
    required List<Map<String, dynamic>> carried,
    required bool hasAnyRecords,
    required Widget emptyState,
    required Widget Function(Map<String, dynamic> record) currentCard,
    required Widget Function(Map<String, dynamic> record) carriedCard,
    required String Function(Map<String, dynamic> record) originLabel,
    String? notice,
  }) {
    final filterActive = from != null || to != null;

    return [
      HistoricalDateFilterBar(
        label: dateLabel,
        from: from,
        to: to,
        onFromChanged: onFromChanged,
        onToChanged: onToChanged,
        onClear: onClear,
      ),
      const SizedBox(height: 14),
      if (notice != null) ...[
        Text(notice, style: TextStyle(color: Colors.orange.shade800)),
        const SizedBox(height: 10),
      ],
      if (!hasAnyRecords)
        emptyState
      else if (current.isEmpty && carried.isEmpty)
        const HistoricalNoMatches()
      else ...[
        if (current.isNotEmpty || !filterActive) ...[
          const HistoricalGroupHeader(
            title: 'This month',
            subtitle: 'Recorded in this report. These can be edited here.',
          ),
          if (current.isEmpty)
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text(
                'No records have been added in this report yet.',
                style: TextStyle(color: AppColors.grey),
              ),
            )
          else
            ...current.map(currentCard),
        ],
        if (carried.isNotEmpty) ...[
          const SizedBox(height: 8),
          const HistoricalGroupHeader(
            title: 'Carried forward from earlier months',
            subtitle: 'Historical records with their original dates. '
                'Read-only here.',
          ),
          for (final record in carried)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                HistoricalBadge(label: originLabel(record)),
                const SizedBox(height: 6),
                carriedCard(record),
              ],
            ),
        ],
      ],
    ];
  }
}

class HistoricalBadge extends StatelessWidget {
  final String label;

  const HistoricalBadge({super.key, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.grey.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.lock_outline, size: 13, color: AppColors.grey),
          const SizedBox(width: 5),
          Text(
            label,
            style: const TextStyle(
              color: AppColors.grey,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class HistoricalGroupHeader extends StatelessWidget {
  final String title;
  final String subtitle;

  const HistoricalGroupHeader({
    super.key,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: AppColors.black,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
            style: const TextStyle(color: AppColors.grey, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class HistoricalNoMatches extends StatelessWidget {
  const HistoricalNoMatches({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: const Column(
        children: [
          Icon(Icons.search_off_outlined, size: 40, color: AppColors.grey),
          SizedBox(height: 10),
          Text(
            'No records in this date range',
            style: TextStyle(
              color: AppColors.black,
              fontWeight: FontWeight.bold,
            ),
          ),
          SizedBox(height: 4),
          Text(
            'Change or clear the date filter to see more records.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.grey),
          ),
        ],
      ),
    );
  }
}

/// From / To date range filter (inclusive). Clear resets both dates.
class HistoricalDateFilterBar extends StatelessWidget {
  final String label;
  final DateTime? from;
  final DateTime? to;
  final ValueChanged<DateTime?> onFromChanged;
  final ValueChanged<DateTime?> onToChanged;
  final VoidCallback onClear;

  const HistoricalDateFilterBar({
    super.key,
    required this.label,
    required this.from,
    required this.to,
    required this.onFromChanged,
    required this.onToChanged,
    required this.onClear,
  });

  Future<void> _pick(
    BuildContext context,
    DateTime? current,
    ValueChanged<DateTime?> onChanged,
  ) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: current ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );

    if (picked != null) onChanged(picked);
  }

  @override
  Widget build(BuildContext context) {
    final active = from != null || to != null;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          const Icon(Icons.date_range_outlined,
              size: 20, color: AppColors.red),
          Text(
            label,
            style: const TextStyle(
              color: AppColors.black,
              fontWeight: FontWeight.w600,
            ),
          ),
          OutlinedButton(
            onPressed: () => _pick(context, from, onFromChanged),
            child: Text(
              from == null
                  ? 'From: any'
                  : 'From: ${HistoricalRecords.formatDate(from!)}',
            ),
          ),
          OutlinedButton(
            onPressed: () => _pick(context, to, onToChanged),
            child: Text(
              to == null
                  ? 'To: any'
                  : 'To: ${HistoricalRecords.formatDate(to!)}',
            ),
          ),
          if (active)
            TextButton.icon(
              onPressed: onClear,
              icon: const Icon(Icons.clear, size: 18),
              label: const Text('Clear'),
            ),
        ],
      ),
    );
  }
}