import 'finance_helpers.dart';

/// Result of walking the arrears chain up to a given report.
class ArrearsCarryForward {
  /// True only for the first report that has arrears data. That month's
  /// opening is a confirmed amount entered once; later openings are derived.
  final bool openingEditable;

  /// Closing arrears of the preceding report for the same property.
  /// Null when this is the first report with arrears data.
  final double? previousClosing;

  const ArrearsCarryForward({
    required this.openingEditable,
    required this.previousClosing,
  });
}

/// Formulas shared by the Finance pages. They mirror the workbook:
///   Billing = Service Charge + Sinking Fund + Other Income
///   Collection = Service Charge + Sinking Fund + Other + Open Credit
///   Closing arrears = Opening + Billing - Collection + Adjustments
///   Opening arrears = previous month's closing (after the first anchor).
class FinanceCalc {
  FinanceCalc._();

  // `collection_open_credit` is a collection-side field, not billing.
  // Keep its existing database name to avoid a schema change.
  static double billed(Map<String, dynamic>? row) {
    if (row == null) return 0;

    return FinanceHelpers.moneyValue(row['billing_service_charge']) +
        FinanceHelpers.moneyValue(row['billing_sinking_fund']) +
        FinanceHelpers.moneyValue(row['billing_other']);
  }

  static double collected(Map<String, dynamic>? row) {
    if (row == null) return 0;

    return FinanceHelpers.moneyValue(row['collection_service_charge']) +
        FinanceHelpers.moneyValue(row['collection_sinking_fund']) +
        FinanceHelpers.moneyValue(row['collection_other']) +
        FinanceHelpers.moneyValue(row['collection_open_credit']);
  }

  static double closing({
    required double opening,
    required double billed,
    required double collected,
    required double adjustments,
  }) => opening + billed - collected + adjustments;

  /// Walks every report for this property up to [reportMonth], in date order.
  ///
  /// The first saved arrears row anchors the chain. Subsequent openings use
  /// the previous calculated closing except for existing rows explicitly
  /// marked with opening_arrears_override = true. These legacy overrides are
  /// retained so existing historical records are not silently rewritten.
  /// Months without billing/arrears rows contribute zero activity.
  /// The chain continues across financial years.
  static Future<ArrearsCarryForward> arrearsCarryForward({
    required String reportId,
    required DateTime reportMonth,
  }) async {
    final client = FinanceHelpers.supabase;
    final endOfMonth = DateTime(reportMonth.year, reportMonth.month + 1, 0);

    final currentReport = await client
        .from('monthly_reports')
        .select('id, report_month, site_id')
        .eq('id', reportId)
        .maybeSingle();

    if (currentReport == null) {
      throw Exception('Monthly report was not found.');
    }

    final siteId = currentReport['site_id'];
    if (siteId == null) {
      throw Exception('Monthly report has no property ID.');
    }

    final reports = await client
        .from('monthly_reports')
        .select('id, report_month, site_id')
        .eq('site_id', siteId)
        .lte('report_month', FinanceHelpers.dateString(endOfMonth))
        .order('report_month', ascending: true);

    final ids = <String>[for (final report in reports) report['id'].toString()];
    final currentIndex = ids.indexOf(reportId);

    if (currentIndex == -1) {
      throw Exception(
        'Monthly report was not found in this property\u2019s report history.',
      );
    }

    final chain = ids.sublist(0, currentIndex + 1);

    final arrearsRows = await client
        .from('finance_arrears_reconciliation')
        .select(
          'report_id, opening_arrears, opening_arrears_override, adjustments',
        )
        .inFilter('report_id', chain);

    final billingRows = await client
        .from('finance_billing_collection')
        .select()
        .inFilter('report_id', chain);

    final arrearsByReport = <String, Map<String, dynamic>>{
      for (final row in arrearsRows)
        row['report_id'].toString(): Map<String, dynamic>.from(row),
    };

    final billingByReport = <String, Map<String, dynamic>>{
      for (final row in billingRows)
        row['report_id'].toString(): Map<String, dynamic>.from(row),
    };

    final anchorIndex = chain.indexWhere(
      (id) => arrearsByReport.containsKey(id),
    );

    // No earlier arrears row exists: the current month is the opening anchor.
    if (anchorIndex == -1 || anchorIndex == currentIndex) {
      return const ArrearsCarryForward(
        openingEditable: true,
        previousClosing: null,
      );
    }

    double? runningClosing;

    for (var i = anchorIndex; i < currentIndex; i++) {
      final id = chain[i];
      final savedArrears = arrearsByReport[id];
      final useSavedOpening = i == anchorIndex ||
          savedArrears?['opening_arrears_override'] == true;

      // Match ai_financial_metrics: only the first saved opening and
      // explicitly overridden historical openings break the carry-forward.
      if (useSavedOpening && savedArrears?['opening_arrears'] == null) {
        throw StateError('Missing confirmed opening arrears for a prior month.');
      }
      final opening = useSavedOpening
          ? FinanceHelpers.moneyValue(savedArrears!['opening_arrears'])
          : (runningClosing ?? 0);
      final adjustments = FinanceHelpers.moneyValue(
        savedArrears?['adjustments'],
      );

      runningClosing = closing(
        opening: opening,
        billed: billed(billingByReport[id]),
        collected: collected(billingByReport[id]),
        adjustments: adjustments,
      );
    }

    return ArrearsCarryForward(
      openingEditable: false,
      previousClosing: runningClosing,
    );
  }
}
