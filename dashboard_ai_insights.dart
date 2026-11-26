import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../widgets/styles.dart';

/// Admin-only Gemini insights. Mount from the existing active-admin Finance gate.
/// All financial figures are still calculated by the existing backend.
class AiFinancialInsightsSection extends StatefulWidget {
  final String siteId;
  final String siteName;

  /// Initial reporting month (YYYY-MM). The AI card has its own From/To filters.
  final String reportingMonth;

  const AiFinancialInsightsSection({
    super.key,
    required this.siteId,
    required this.siteName,
    required this.reportingMonth,
  });

  @override
  State<AiFinancialInsightsSection> createState() =>
      _AiFinancialInsightsSectionState();
}

class _AiFinancialInsightsSectionState
    extends State<AiFinancialInsightsSection> {
  final SupabaseClient _supabase = Supabase.instance.client;
  static const _background = Colors.white;
  static const _monthNames = <String>[
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

  String? _fromMonth;
  String? _toMonth;
  List<String> _reportMonths = const [];
  bool _loadingMonths = false;
  String? _monthsError;
  int _monthsRequestSequence = 0;
  String _detail = 'short';
  bool _generating = false;
  bool _expanded = true;
  String? _error;
  Map<String, dynamic>? _insights;
  int _requestSequence = 0;

  // The property filter belongs to this card, not the parent dashboard.
  String? _selectedSiteId;
  Map<String, String>? _availableSites;
  bool _loadingSites = false;
  String? _sitesError;
  int _sitesRequestSequence = 0;

  Map<String, String> get _siteOptions =>
      _availableSites ??
      <String, String>{
        if (widget.siteId.isNotEmpty) widget.siteId: widget.siteName,
      };

  String? get _activeSiteId =>
      _siteOptions.containsKey(_selectedSiteId) ? _selectedSiteId : null;

  String get _activeSiteName =>
      _siteOptions[_activeSiteId] ?? 'Select a property';

  @override
  void initState() {
    super.initState();
    _selectedSiteId = widget.siteId.isEmpty ? null : widget.siteId;
    _loadProperties();
  }

  Future<void> _loadProperties() async {
    if (_loadingSites || _generating) return;
    final request = ++_sitesRequestSequence;
    setState(() {
      _loadingSites = true;
      _sitesError = null;
    });

    try {
      final session = _supabase.auth.currentSession;
      if (session == null) throw StateError('Your login session has expired.');

      // Use the existing authenticated property directory. No hardcoded names,
      // service-role key, or new database permissions are required.
      final response = await _supabase.functions.invoke(
        'property-sites',
        body: <String, dynamic>{'action': 'list_my_sites'},
        headers: <String, String>{
          'Authorization': 'Bearer ${session.accessToken}',
        },
      );
      dynamic decoded = response.data;
      if (decoded is String) decoded = jsonDecode(decoded);
      if (decoded is! Map ||
          decoded['viewer_role'] != 'admin' ||
          decoded['sites'] is! List) {
        throw StateError('Unable to load the administrator property list.');
      }
      final entries = <MapEntry<String, String>>[];
      for (final raw in decoded['sites'] as List) {
        if (raw is! Map) continue;
        final id = raw['id']?.toString().trim() ?? '';
        final name = raw['site_name']?.toString().trim() ?? '';
        if (id.isNotEmpty && name.isNotEmpty) {
          entries.add(MapEntry(id, name));
        }
      }
      entries.sort(
        (a, b) => a.value.toLowerCase().compareTo(b.value.toLowerCase()),
      );
      final properties = Map<String, String>.fromEntries(entries);
      if (!mounted || request != _sitesRequestSequence) return;
      setState(() {
        _availableSites = properties;
        if (!properties.containsKey(_selectedSiteId)) {
          // Prefer the dashboard property; otherwise require an explicit choice.
          _selectedSiteId = properties.containsKey(widget.siteId)
              ? widget.siteId
              : null;
          _requestSequence++;
          _insights = null;
          _error = null;
        }
        _loadingSites = false;
      });
      await _loadReportMonths();
    } catch (_) {
      if (!mounted || request != _sitesRequestSequence) return;
      setState(() {
        _loadingSites = false;
        _sitesError = 'Unable to load properties. Please try again.';
      });
      await _loadReportMonths();
    }
  }

  @override
  void didUpdateWidget(covariant AiFinancialInsightsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    final siteChanged = oldWidget.siteId != widget.siteId;
    final monthChanged = oldWidget.reportingMonth != widget.reportingMonth;
    if (siteChanged) {
      // Follow a changed dashboard property, but keep card selections independent.
      _selectedSiteId = _siteOptions.containsKey(widget.siteId)
          ? widget.siteId
          : null;
    }
    if (siteChanged || monthChanged) {
      _requestSequence++;
      _insights = null;
      _error = null;
      _generating = false;
      _loadReportMonths();
    }
  }

  @override
  void dispose() {
    _sitesRequestSequence++;
    _monthsRequestSequence++;
    _requestSequence++;
    super.dispose();
  }

  Future<void> _loadReportMonths() async {
    final siteId = _activeSiteId;
    final request = ++_monthsRequestSequence;
    setState(() {
      _reportMonths = const [];
      _fromMonth = null;
      _toMonth = null;
      _monthsError = null;
      _loadingMonths = siteId != null;
    });
    if (siteId == null) return;

    try {
      // Read only report dates for the selected property, through existing RLS.
      if (_supabase.auth.currentSession == null) {
        throw StateError('Your login session has expired.');
      }
      final rows = await _supabase
          .from('monthly_reports')
          .select('report_month')
          .eq('site_id', siteId)
          .order('report_month');
      final months =
          rows
              .map((row) => _monthKey(row['report_month']))
              .whereType<String>()
              .toSet()
              .toList()
            ..sort();
      if (!mounted ||
          request != _monthsRequestSequence ||
          siteId != _activeSiteId) {
        return;
      }
      final preferred = _monthKey(widget.reportingMonth);
      // Default to the dashboard month where available, otherwise the nearest
      // preceding saved report (or the first report when none precedes it).
      String? initial;
      if (months.isNotEmpty) {
        initial = months.last;
        if (preferred != null) {
          final preceding = months.where((m) => m.compareTo(preferred) <= 0);
          initial = preceding.isEmpty ? months.first : preceding.last;
        }
      }
      setState(() {
        _reportMonths = months;
        _fromMonth = initial;
        _toMonth = initial;
        _loadingMonths = false;
      });
    } catch (_) {
      if (!mounted ||
          request != _monthsRequestSequence ||
          siteId != _activeSiteId) {
        return;
      }
      setState(() {
        _loadingMonths = false;
        _monthsError = 'Unable to load report months. Please try again.';
      });
    }
  }

  String? _monthKey(dynamic raw) {
    final value = raw?.toString();
    if (value == null || value.length < 7) return null;
    final match = RegExp(r'^\d{4}-(0[1-9]|1[0-2])(?:$|-)').firstMatch(value);
    return match == null ? null : value.substring(0, 7);
  }

  String _monthLabel(String month) {
    final key = _monthKey(month);
    final date = key == null ? null : DateTime.tryParse('$key-01');
    return date == null ? month : '${_monthNames[date.month - 1]} ${date.year}';
  }

  bool get _validPeriod =>
      _fromMonth != null &&
      _toMonth != null &&
      _reportMonths.contains(_fromMonth) &&
      _reportMonths.contains(_toMonth) &&
      _fromMonth!.compareTo(_toMonth!) <= 0;

  bool get _canGenerate =>
      _activeSiteId != null &&
      _validPeriod &&
      !_generating &&
      !_loadingSites &&
      !_loadingMonths;

  String get _periodLabel {
    final start = _fromMonth;
    final end = _toMonth;
    if (start == null || end == null) return 'Select report months';
    return start == end
        ? _monthLabel(end)
        : '${_monthLabel(start)} – ${_monthLabel(end)}';
  }

  void _selectionChanged(VoidCallback change) {
    if (_generating) return;
    _requestSequence++;
    setState(() {
      change();
      _insights = null;
      _error = null;
    });
  }

  void _chooseFrom(String? month) {
    if (month == null ||
        month == _fromMonth ||
        !_reportMonths.contains(month)) {
      return;
    }
    _selectionChanged(() {
      _fromMonth = month;
      if (_toMonth == null || _toMonth!.compareTo(month) < 0) _toMonth = month;
    });
  }

  void _chooseTo(String? month) {
    if (month == null || month == _toMonth || !_reportMonths.contains(month)) {
      return;
    }
    _selectionChanged(() {
      _toMonth = month;
      if (_fromMonth == null || _fromMonth!.compareTo(month) > 0) {
        _fromMonth = month;
      }
    });
  }

  void _chooseDetail(String detail) {
    if (detail != _detail) _selectionChanged(() => _detail = detail);
  }

  void _chooseProperty(String? siteId) {
    if (siteId == null ||
        siteId == _activeSiteId ||
        _generating ||
        !_siteOptions.containsKey(siteId) ||
        _loadingSites) {
      return;
    }
    _selectionChanged(() => _selectedSiteId = siteId);
    _loadReportMonths();
  }

  Future<void> _generateInsights() async {
    final siteId = _activeSiteId;
    final month = _toMonth;
    final fromMonth = _fromMonth;
    if (siteId == null || month == null || fromMonth == null || !_canGenerate) {
      return;
    }
    final request = ++_requestSequence;
    // Preserve the existing API contract; both bounds now come from this card.
    const range = 'full';
    final detail = _detail;
    setState(() {
      _generating = true;
      _error = null;
      _insights = null;
    });

    try {
      final session = _supabase.auth.currentSession;
      if (session == null) throw StateError('Your login session has expired.');

      // Only ONE property is submitted. No client-generated financial totals.
      final response = await _supabase.functions.invoke(
        'ai-financial-insights',
        body: <String, dynamic>{
          'action': 'insights',
          'site_id': siteId,
          'month': month,
          'range': range,
          'from_month': fromMonth,
          'detail': detail,
        },
        headers: <String, String>{
          'Authorization': 'Bearer ${session.accessToken}',
        },
      );

      dynamic decoded = response.data;
      if (decoded is String) decoded = jsonDecode(decoded);
      if (decoded is! Map) {
        throw StateError('The AI service returned an unexpected response.');
      }
      final payload = Map<String, dynamic>.from(decoded);
      if (payload['success'] != true) {
        throw StateError(payload['error']?.toString() ?? 'AI analysis failed.');
      }

      // Do not claim the analysis is from Gemini if the Edge Function was
      // accidentally configured to use another provider.
      final model = payload['model']?.toString() ?? '';
      if (model.isNotEmpty && !model.toLowerCase().contains('gemini')) {
        throw StateError(
          'The AI Edge Function is not returning a Gemini model. '
          'Check AI_PROVIDER, GEMINI_MODEL and GEMINI_API_KEY in Supabase.',
        );
      }

      if (payload['insights'] is! Map) {
        throw StateError('The AI service returned no structured insights.');
      }
      final insights = Map<String, dynamic>.from(payload['insights'] as Map);
      final financialData = payload['financial_data'] is Map
          ? Map<String, dynamic>.from(payload['financial_data'] as Map)
          : <String, dynamic>{};
      if (!mounted || request != _requestSequence) return;
      final returnedSite =
          payload['site_id']?.toString() ??
          financialData['site_id']?.toString();
      if (returnedSite != null && returnedSite != siteId) {
        throw StateError('The AI service returned a different property.');
      }
      final returnedEnd = _monthKey(financialData['selected_month']);
      if (returnedEnd != null && returnedEnd != month) {
        throw StateError(
          'The AI service returned a different reporting month.',
        );
      }
      final returnedStart = _monthKey(financialData['from_month']);
      if (returnedStart != null && returnedStart.compareTo(fromMonth) < 0) {
        throw StateError(
          'The AI service returned data before the selected analysis period.',
        );
      }
      if (returnedStart != null && returnedStart.compareTo(month) > 0) {
        throw StateError('The AI service returned an invalid analysis period.');
      }
      // Validate the returned range before displaying the insights.
      setState(() {
        _insights = insights;
        _generating = false;
      });
    } catch (error) {
      if (!mounted || request != _requestSequence) return;
      setState(() {
        _error = _friendlyError(error);
        _generating = false;
      });
    }
  }

  String _friendlyError(Object error) {
    if (error is FunctionException) {
      final details = error.details;
      final providerStatus = details is Map ? details['provider_status'] : null;
      final code = details is Map ? details['code'] : null;
      if (code == 'gemini_unavailable' ||
          [500, 502, 503, 504].contains(providerStatus) ||
          error.status == 503 ||
          error.status == 504) {
        return 'Gemini is temporarily unavailable. Please try again.';
      }
      if (error.status == 429) {
        return 'AI usage limit reached. Please try again later.';
      }
      if (error.status == 401) {
        return 'Your session has expired. Please sign in again.';
      }
      if (error.status == 403) return 'Administrator access is required.';
      if (error.status == 404) {
        return 'No financial report for the selected property and months.';
      }
      if (error.status == 409) {
        return 'The selected financial data requires review.';
      }
      if (error.status == 400) {
        return 'Check the selected property and reporting months.';
      }
      return 'Unable to generate AI insights. Please try again.';
    }
    if (error is StateError) return error.message.toString();
    return 'Unable to generate AI insights. Please check your connection and try again.';
  }

  List<String> _messages(String key) {
    final value = _insights?[key];
    if (value is! List) return const [];
    return value
        .whereType<String>()
        .where((item) => item.trim().isNotEmpty)
        .toList();
  }

  Widget _insightItem(String message, IconData icon, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: color, size: 17),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                message,
                style: const TextStyle(
                  color: AppColors.black,
                  fontSize: 13,
                  height: 1.45,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Display the existing Gemini action schema as compact, categorised advice.
  // No financial calculations or AI controls are changed here.
  Widget _actionItem(Map<String, dynamic> action) {
    final rawTitle = action['title']?.toString().trim() ?? '';
    final detail = action['detail']?.toString().trim() ?? '';
    if (rawTitle.isEmpty || detail.isEmpty) return const SizedBox.shrink();

    final title = rawTitle.replaceFirst(RegExp(r'[.:\s]+$'), '');
    final tone = action['tone']?.toString() ?? 'info';
    final Color color;
    final IconData icon;
    switch (tone) {
      case 'warning':
        color = const Color(0xFFBC424A);
        icon = Icons.warning_amber_rounded;
        break;
      case 'trend':
        color = const Color(0xFFB97918);
        icon = Icons.show_chart_rounded;
        break;
      case 'positive':
        color = const Color(0xFF27854E);
        icon = Icons.check_circle_outline_rounded;
        break;
      default:
        color = const Color(0xFF427EBB);
        icon = Icons.calendar_month_outlined;
        break;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.11),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(icon, color: color, size: 18),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: '$title. ',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    TextSpan(text: detail),
                  ],
                ),
                style: const TextStyle(
                  color: AppColors.black,
                  fontSize: 13,
                  height: 1.48,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Gemini returns one finding per line. The server appends data-quality notes.
  // Keep section headings and use real bullet rows.
  Widget _explanationBullets(String explanation) {
    const headings = <String>{
      'FINANCIAL PERFORMANCE',
      'ANOMALY FLAGGED FOR REVIEW',
      'DATA QUALITY',
    };
    final lines = explanation
        .split(RegExp(r'\r?\n'))
        .map(
          (line) => line.trim().replaceFirst(
            RegExp(r'^(?:[•*–-]\s+|\d+[.)]\s+)'),
            '',
          ),
        )
        .where((line) => line.isNotEmpty);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final line in lines)
          if (headings.contains(line.toUpperCase()))
            Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 5),
              child: Text(
                line,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppColors.black,
                ),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 7, right: 10),
                    child: Icon(Icons.circle, size: 5, color: AppColors.grey),
                  ),
                  Expanded(
                    child: Text(
                      line,
                      style: const TextStyle(
                        color: AppColors.grey,
                        fontSize: 13,
                        height: 1.5,
                      ),
                    ),
                  ),
                ],
              ),
            ),
      ],
    );
  }

  Widget _sectionLabel(String label) => Text(
    label,
    style: const TextStyle(
      color: AppColors.black,
      fontSize: 13,
      fontWeight: FontWeight.w700,
    ),
  );

  Widget _findingItem(Map<String, dynamic> finding) {
    final title =
        finding['title']?.toString().trim().replaceFirst(
          RegExp(r'[.:\s]+$'),
          '',
        ) ??
        '';
    final detail = finding['detail']?.toString().trim() ?? '';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 7, right: 10),
            child: Icon(Icons.circle, size: 5, color: AppColors.grey),
          ),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  if (title.isNotEmpty)
                    TextSpan(
                      text: '$title. ',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        color: AppColors.black,
                      ),
                    ),
                  TextSpan(text: detail),
                ],
              ),
              style: const TextStyle(
                color: AppColors.grey,
                fontSize: 13,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _insightContent() {
    if (_generating) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Flexible(
              child: Text('Generating financial insights with Gemini...'),
            ),
          ],
        ),
      );
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 2, right: 8),
              child: Icon(Icons.info_outline, color: AppColors.error, size: 17),
            ),
            Expanded(
              child: Text(
                _error!,
                style: const TextStyle(
                  color: AppColors.error,
                  fontSize: 13,
                  height: 1.45,
                ),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: _canGenerate ? _generateInsights : null,
              style: TextButton.styleFrom(foregroundColor: AppColors.red),
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }
    if (_insights == null) return const SizedBox.shrink();

    final highlights = _messages('highlights');
    final risks = _messages('risks');
    final recommendations = _messages('recommendations');
    final summary = _insights?['summary']?.toString() ?? '';
    final headline = _insights?['headline']?.toString().trim() ?? '';
    final explanation = _insights?['explanation']?.toString().trim() ?? '';
    final rawFindings = _insights?['findings'];
    final findings = rawFindings is List
        ? rawFindings
              .whereType<Map>()
              .map((value) => Map<String, dynamic>.from(value))
              .where(
                (value) =>
                    value['detail']?.toString().trim().isNotEmpty ?? false,
              )
              .toList()
        : <Map<String, dynamic>>[];
    final qualityNote =
        _insights?['data_quality_note']?.toString().trim() ?? '';
    final rawActions = _insights?['actions'];
    final actions = rawActions is List
        ? rawActions
              .whereType<Map>()
              .map((value) => Map<String, dynamic>.from(value))
              .where(
                (value) =>
                    (value['title']?.toString().trim().isNotEmpty ?? false) &&
                    (value['detail']?.toString().trim().isNotEmpty ?? false),
              )
              .toList()
        : <Map<String, dynamic>>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (findings.isNotEmpty || explanation.isNotEmpty) ...[
          _sectionLabel('Key Insights'),
          const SizedBox(height: 4),
          if (findings.isNotEmpty) ...[
            for (final finding in findings) _findingItem(finding),
            if (qualityNote.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                qualityNote,
                style: const TextStyle(
                  color: AppColors.grey,
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
            ],
          ] else
            _explanationBullets(explanation),
        ] else if (headline.isEmpty)
          Text(
            summary,
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 14,
              color: AppColors.black,
              height: 1.45,
            ),
          ),
        if (actions.isNotEmpty) ...[
          const Divider(height: 20),
          _sectionLabel('Recommended Actions'),
          for (var i = 0; i < actions.length; i++) ...[
            if (i > 0) const Divider(height: 1),
            _actionItem(actions[i]),
          ],
        ] else if (highlights.isNotEmpty ||
            risks.isNotEmpty ||
            recommendations.isNotEmpty) ...[
          // Compatibility with an older deployed Edge Function response.
          const Divider(height: 20),
          _sectionLabel('Recommended Actions'),
          for (final message in highlights)
            _insightItem(
              message,
              Icons.trending_up_rounded,
              const Color(0xFF22683D),
            ),
          for (final message in risks)
            _insightItem(
              message,
              Icons.warning_amber_rounded,
              const Color(0xFFB45309),
            ),
          for (final message in recommendations)
            _insightItem(
              message,
              Icons.fact_check_outlined,
              const Color(0xFF2478E9),
            ),
        ],
        const SizedBox(height: 12),
        const Row(
          children: [
            Icon(Icons.info_outline, color: AppColors.grey, size: 14),
            SizedBox(width: 6),
            Expanded(
              child: Text(
                'Generated by Gemini from saved figures across all seven Finance sections. '
                'Review the underlying data before acting.',
                style: TextStyle(color: AppColors.grey, fontSize: 11),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _optionButton(
    String label,
    String value,
    String current,
    ValueChanged<String> onChanged,
  ) {
    final selected = value == current;
    return Semantics(
      selected: selected,
      child: OutlinedButton(
        onPressed: _generating ? null : () => onChanged(value),
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 40),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          foregroundColor: selected ? Colors.white : AppColors.black,
          backgroundColor: selected ? AppColors.black : Colors.white,
          disabledForegroundColor: selected
              ? const Color(0xFF666666)
              : const Color(0xFF888888),
          disabledBackgroundColor: selected
              ? const Color(0xFFE0E0E0)
              : const Color(0xFFF5F5F5),
          side: BorderSide(
            color: selected && !_generating
                ? AppColors.black
                : AppColors.border,
          ),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
        ),
        child: Text(label, textAlign: TextAlign.center),
      ),
    );
  }

  Widget _filterLabel(String label) => Padding(
    padding: const EdgeInsets.only(bottom: 7),
    child: Text(
      label,
      style: const TextStyle(
        color: AppColors.grey,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
    ),
  );

  Widget _propertyFilter() {
    final options = _siteOptions;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _filterLabel('Property'),
        Container(
          constraints: const BoxConstraints(minHeight: 40),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            children: [
              Expanded(
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _activeSiteId,
                    isExpanded: true,
                    isDense: true,
                    icon: const Icon(
                      Icons.keyboard_arrow_down_rounded,
                      size: 20,
                      color: AppColors.black,
                    ),
                    borderRadius: BorderRadius.circular(8),
                    dropdownColor: Colors.white,
                    style: const TextStyle(
                      color: AppColors.black,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                    hint: Text(
                      _loadingSites
                          ? 'Loading properties...'
                          : 'Select a property',
                      overflow: TextOverflow.ellipsis,
                    ),
                    items: options.entries
                        .map(
                          (entry) => DropdownMenuItem<String>(
                            value: entry.key,
                            child: Text(
                              entry.value,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: _generating || _loadingSites || options.isEmpty
                        ? null
                        : _chooseProperty,
                  ),
                ),
              ),
              if (_loadingSites) ...[
                const SizedBox(width: 10),
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ],
            ],
          ),
        ),
        if (_sitesError != null) ...[
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                _sitesError!,
                style: const TextStyle(color: AppColors.error, fontSize: 11),
              ),
              TextButton(
                onPressed: _generating || _loadingSites
                    ? null
                    : _loadProperties,
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.red,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  minimumSize: const Size(0, 32),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('Retry'),
              ),
            ],
          ),
        ] else if (!_loadingSites && options.isEmpty) ...[
          const SizedBox(height: 6),
          const Text(
            'No properties available.',
            style: TextStyle(color: AppColors.grey, fontSize: 11),
          ),
        ],
      ],
    );
  }

  Widget _monthFilter(
    String label,
    String? selected,
    ValueChanged<String?> onChanged,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _filterLabel(label),
        Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.border),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: _reportMonths.contains(selected) ? selected : null,
              isExpanded: true,
              isDense: true,
              menuMaxHeight: 340,
              icon: const Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 20,
                color: AppColors.black,
              ),
              borderRadius: BorderRadius.circular(8),
              dropdownColor: Colors.white,
              style: const TextStyle(
                color: AppColors.black,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
              hint: Text(
                _loadingMonths ? 'Loading...' : 'Month / Year',
                overflow: TextOverflow.ellipsis,
              ),
              items: _reportMonths
                  .map(
                    (month) => DropdownMenuItem<String>(
                      value: month,
                      child: Text(
                        _monthLabel(month),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(),
              onChanged:
                  _generating ||
                      _loadingSites ||
                      _loadingMonths ||
                      _reportMonths.isEmpty
                  ? null
                  : onChanged,
            ),
          ),
        ),
      ],
    );
  }

  Widget _periodFilter() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      LayoutBuilder(
        builder: (context, constraints) {
          final from = _monthFilter('From', _fromMonth, _chooseFrom);
          final to = _monthFilter('To', _toMonth, _chooseTo);
          if (constraints.maxWidth < 300) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [from, const SizedBox(height: 12), to],
            );
          }
          return Row(
            children: [
              Expanded(child: from),
              const SizedBox(width: 12),
              Expanded(child: to),
            ],
          );
        },
      ),
      if (_loadingMonths) ...[
        const SizedBox(height: 8),
        const LinearProgressIndicator(minHeight: 2),
      ] else if (_monthsError != null) ...[
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              _monthsError!,
              style: const TextStyle(color: AppColors.error, fontSize: 11),
            ),
            TextButton(
              onPressed: _generating ? null : _loadReportMonths,
              child: const Text('Retry'),
            ),
          ],
        ),
      ] else if (_activeSiteId != null && _reportMonths.isEmpty) ...[
        const SizedBox(height: 6),
        const Text(
          'No saved report months for this property.',
          style: TextStyle(color: AppColors.grey, fontSize: 11),
        ),
      ],
    ],
  );

  Widget _detailFilter(bool canGenerate) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _filterLabel('Insight detail'),
      LayoutBuilder(
        builder: (context, constraints) {
          final options = Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _optionButton('Short', 'short', _detail, _chooseDetail),
              _optionButton('Detailed', 'detailed', _detail, _chooseDetail),
            ],
          );
          // Keep all three buttons on one row when there is enough space.
          // On narrow screens or at large text sizes, allow them to wrap.
          if (constraints.maxWidth <
              320 * MediaQuery.textScalerOf(context).scale(1)) {
            return Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              runSpacing: 8,
              children: [options, _generateButton(canGenerate)],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(child: options),
              const SizedBox(width: 12),
              _generateButton(canGenerate),
            ],
          );
        },
      ),
    ],
  );

  Widget _generateButton(bool canGenerate) => FilledButton.icon(
    onPressed: canGenerate ? _generateInsights : null,
    style: FilledButton.styleFrom(
      backgroundColor: AppColors.red,
      foregroundColor: Colors.white,
      disabledBackgroundColor: const Color(0xFFF5D6D9),
      disabledForegroundColor: const Color(0xFF8C4249),
      minimumSize: const Size(0, 40),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
    ),
    icon: Icon(
      _generating ? Icons.hourglass_top_rounded : Icons.auto_awesome_rounded,
      size: 16,
    ),
    label: Text(_generating ? 'Generating' : 'Generate AI'),
  );

  @override
  Widget build(BuildContext context) {
    final canGenerate = _canGenerate;
    final hasContent = _generating || _error != null || _insights != null;
    return Container(
      width: double.infinity,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            color: _background,
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: AppColors.red,
                        borderRadius: BorderRadius.circular(11),
                      ),
                      child: const Icon(
                        Icons.auto_awesome_outlined,
                        size: 22,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'AI Financial Insights',
                            style: TextStyle(
                              color: AppColors.black,
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          SizedBox(height: 3),
                          Text(
                            'Gemini • Admin only',
                            style: TextStyle(
                              color: AppColors.grey,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: _expanded
                          ? 'Collapse insights'
                          : 'Expand insights',
                      onPressed: () => setState(() => _expanded = !_expanded),
                      icon: Icon(
                        _expanded
                            ? Icons.keyboard_arrow_up_rounded
                            : Icons.keyboard_arrow_down_rounded,
                        color: AppColors.black,
                      ),
                    ),
                  ],
                ),
                if (_expanded) ...[
                  const SizedBox(height: 18),
                  _propertyFilter(),
                  const SizedBox(height: 16),
                  _periodFilter(),
                  const SizedBox(height: 16),
                  _detailFilter(canGenerate),
                  if (hasContent) ...[
                    const SizedBox(height: 12),
                    const Divider(height: 1, color: AppColors.border),
                    const SizedBox(height: 12),
                    _insightContent(),
                  ],
                ] else ...[
                  const SizedBox(height: 10),
                  Text(
                    '$_activeSiteName  •  $_periodLabel',
                    style: const TextStyle(
                      color: AppColors.grey,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
