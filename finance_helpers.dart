import 'package:supabase_flutter/supabase_flutter.dart';

class FinanceHelpers {
  static final SupabaseClient supabase = Supabase.instance.client;

  static double moneyValue(dynamic value) {
    if (value == null) return 0;
    if (value is num) return value.toDouble();

    return double.tryParse(
          value.toString().replaceAll(',', '').replaceAll('RM', '').trim(),
        ) ??
        0;
  }

  static String money(double value) => 'RM ${value.toStringAsFixed(2)}';

  static String dateString(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
}