import 'package:flutter/material.dart';

import '../widgets/styles.dart';
import 'finance_helpers.dart';

/// One field to display for each earlier version of a record.
class FinanceHistoryField {
  final String key;
  final String label;
  final String Function(dynamic value) format;

  const FinanceHistoryField(this.key, this.label, this.format);
}

/// Shows the earlier versions of a finance record that were captured by the
/// `finance_record_history` database trigger (see the SQL migration).
Future<void> showFinanceRecordHistory({
  required BuildContext context,
  required String tableName,
  required String recordId,
  required String title,
  required List<FinanceHistoryField> fields,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _FinanceHistoryDialog(
      tableName: tableName,
      recordId: recordId,
      title: title,
      fields: fields,
    ),
  );
}

class _FinanceHistoryDialog extends StatefulWidget {
  final String tableName;
  final String recordId;
  final String title;
  final List<FinanceHistoryField> fields;

  const _FinanceHistoryDialog({
    required this.tableName,
    required this.recordId,
    required this.title,
    required this.fields,
  });

  @override
  State<_FinanceHistoryDialog> createState() => _FinanceHistoryDialogState();
}

class _FinanceHistoryDialogState extends State<_FinanceHistoryDialog> {
  List<Map<String, dynamic>> _entries = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final result = await FinanceHelpers.supabase
          .from('finance_record_history')
          .select('operation, changed_at, old_row')
          .eq('table_name', widget.tableName)
          .eq('record_id', widget.recordId)
          .order('changed_at', ascending: false);

      if (!mounted) return;

      setState(() {
        _entries = List<Map<String, dynamic>>.from(result);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _error = 'Unable to load history: $e';
        _loading = false;
      });
    }
  }

  String _timestamp(dynamic value) {
    final parsed = DateTime.tryParse(value?.toString() ?? '');
    if (parsed == null) return '-';

    final d = parsed.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');

    return '${two(d.day)}/${two(d.month)}/${d.year} '
        '${two(d.hour)}:${two(d.minute)}';
  }

  Widget _entry(Map<String, dynamic> entry) {
    final isDelete = entry['operation'] == 'DELETE';
    final oldRow = entry['old_row'] is Map
        ? Map<String, dynamic>.from(entry['old_row'] as Map)
        : <String, dynamic>{};

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isDelete
                ? 'Deleted on ${_timestamp(entry['changed_at'])}'
                : 'Replaced on ${_timestamp(entry['changed_at'])}',
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              color: AppColors.red,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 2),
          const Text(
            'Values before this change:',
            style: TextStyle(color: AppColors.grey, fontSize: 12),
          ),
          const SizedBox(height: 8),
          for (final field in widget.fields)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 120,
                    child: Text(
                      field.label,
                      style: const TextStyle(
                        color: AppColors.grey,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      field.format(oldRow[field.key]),
                      style: const TextStyle(
                        color: AppColors.black,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    Widget body;

    if (_loading) {
      body = const Padding(
        padding: EdgeInsets.symmetric(vertical: 32),
        child: Center(child: CircularProgressIndicator()),
      );
    } else if (_error != null) {
      body = Text(_error!, style: const TextStyle(color: Colors.red));
    } else if (_entries.isEmpty) {
      body = const Text(
        'No earlier versions have been recorded for this entry. '
        'Any change made from now on will be kept here.',
        style: TextStyle(color: AppColors.grey),
      );
    } else {
      body = Column(children: _entries.map(_entry).toList());
    }

    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 460,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 420),
          child: SingleChildScrollView(child: body),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}