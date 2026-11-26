
import 'package:flutter/material.dart';

import '../widgets/styles.dart';
import 'finance_billing.dart';
import 'finance_arrears.dart';
import 'finance_transfers.dart';
import 'finance_fixed_deposits.dart';
import 'finance_expenditures.dart';
import 'finance_defaulters.dart';
import 'finance_utilities.dart';

class FinanceSection {
  static const billingCollection = 'billing_collection';
  static const arrearsReconciliation = 'arrears_reconciliation';
  static const sinkingFundTransfers = 'sinking_fund_transfers';
  static const fixedDeposits = 'fixed_deposits';
  static const approvedExpenditure = 'approved_expenditure';
  static const defaulters = 'defaulters';
  static const utilities = 'utilities';
}

class FinancePage extends StatelessWidget {
  final Map<String, dynamic> report;

  const FinancePage({
    super.key,
    required this.report,
  });

  static const sections = [
    (
      FinanceSection.billingCollection,
      'Billing & Collection',
      'Manage monthly billing, collections and payment records.',
      Icons.receipt_long_outlined,
    ),
    (
      FinanceSection.arrearsReconciliation,
      'Arrears Reconciliation',
      'Review opening balances, adjustments and closing arrears.',
      Icons.account_balance_wallet_outlined,
    ),
    (
      FinanceSection.sinkingFundTransfers,
      'Sinking Fund Transfers',
      'Record transfers and reconcile sinking fund collections.',
      Icons.swap_horiz,
    ),
    (
      FinanceSection.fixedDeposits,
      'Fixed Deposits',
      'Manage deposit placements, maturity dates and balances.',
      Icons.savings_outlined,
    ),
    (
      FinanceSection.approvedExpenditure,
      'Approved Expenditure',
      'Review and manage approved expenditure records.',
      Icons.fact_check_outlined,
    ),
    (
      FinanceSection.defaulters,
      'Defaulters',
      'Manage outstanding balances and actions taken for defaulters.',
      Icons.person_off_outlined,
    ),
    (
      FinanceSection.utilities,
      'Utilities',
      'Manage monthly utility expenses and related records.',
      Icons.electrical_services_outlined,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final reportDate = report['report_month'] ??
        report['month'] ??
        report['report_date'];

    final parsedDate = reportDate == null
        ? null
        : DateTime.tryParse(reportDate.toString());

    final monthLabel = parsedDate == null
        ? 'Monthly financial records'
        : '${_monthName(parsedDate.month)} ${parsedDate.year}';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Finance'),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1100),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: AppColors.red,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Icon(
                        Icons.account_balance_outlined,
                        color: Colors.white,
                        size: 32,
                      ),
                    ),
                    const SizedBox(width: 18),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Financial Management',
                            style: Theme.of(context)
                                .textTheme
                                .headlineSmall
                                ?.copyWith(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Manage your property finances in one place.',
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(
                                  color: Colors.white.withValues(alpha: 0.9),
                                ),
                          ),
                          const SizedBox(height: 10),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 5,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              monthLabel,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 28),
              Text(
                'Finance Sections',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: AppColors.black,
                    ),
              ),
              const SizedBox(height: 6),
              Text(
                'Choose a section to view or update its records.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: AppColors.grey,
                    ),
              ),
              const SizedBox(height: 18),
              LayoutBuilder(
                builder: (context, constraints) {
                  final columns = constraints.maxWidth >= 800
                      ? 3
                      : constraints.maxWidth >= 520
                          ? 2
                          : 1;

                  final cardWidth = (constraints.maxWidth -
                          (columns - 1) * 16) /
                      columns;

                  return Wrap(
                    spacing: 16,
                    runSpacing: 16,
                    children: [
                      for (final section in sections)
                        SizedBox(
                          width: cardWidth,
                          child: _sectionCard(
                            context,
                            section.$1,
                            section.$2,
                            section.$3,
                            section.$4,
                          ),
                        ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionCard(
    BuildContext context,
    String section,
    String title,
    String description,
    IconData icon,
  ) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => FinanceSectionPage(
              section: section,
              report: report,
            ),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.red.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      icon,
                      color: AppColors.red,
                      size: 25,
                    ),
                  ),
                  const Spacer(),
                  const Icon(
                    Icons.arrow_outward,
                    color: AppColors.grey,
                    size: 19,
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Text(
                title,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: AppColors.black,
                    ),
              ),
              const SizedBox(height: 8),
              Text(
                description,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: AppColors.grey,
                      height: 1.5,
                    ),
              ),
              const SizedBox(height: 12),
              const Row(
                children: [
                  Text(
                    'Open section',
                    style: TextStyle(
                      color: AppColors.red,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                  SizedBox(width: 6),
                  Icon(
                    Icons.arrow_forward,
                    size: 15,
                    color: AppColors.red,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _monthName(int month) {
    const months = [
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

    return months[month - 1];
  }
}


class FinanceSectionPage extends StatelessWidget {
  final String section;
  final Map<String, dynamic> report;

  const FinanceSectionPage({
    super.key,
    required this.section,
    required this.report,
  });

  String get title => switch (section) {
        FinanceSection.billingCollection => 'Billing & Collection',
        FinanceSection.arrearsReconciliation => 'Arrears Reconciliation',
        FinanceSection.sinkingFundTransfers => 'Sinking Fund Transfers',
        FinanceSection.fixedDeposits => 'Fixed Deposits',
        FinanceSection.approvedExpenditure => 'Approved Expenditure',
        FinanceSection.defaulters => 'Defaulters',
        FinanceSection.utilities => 'Utilities',
        _ => 'Finance',
      };

  Widget _buildSection() {
    switch (section) {
      case FinanceSection.billingCollection:
        return FinanceBilling(report: report);
      case FinanceSection.arrearsReconciliation:
        return FinanceArrears(report: report);
      case FinanceSection.sinkingFundTransfers:
        return FinanceTransfers(report: report);
      case FinanceSection.fixedDeposits:
        return FinanceFixedDeposits(report: report);
      case FinanceSection.approvedExpenditure:
        return FinanceExpenditures(report: report);
      case FinanceSection.defaulters:
        return FinanceDefaulters(report: report);
      case FinanceSection.utilities:
        return FinanceUtilities(report: report);
      default:
        return const Text('Unknown finance section.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1100),
          child: _buildSection(),
        ),
      ),
    );
  }
}