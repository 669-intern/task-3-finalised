import 'package:flutter/material.dart';

import 'service_providers.dart';
import 'license_regulatory.dart';
import 'compliance_best_practices.dart';
import 'insurance_policies.dart' as insurance;
import 'insurance_claims.dart' as claims;
import '../widgets/styles.dart';

class ContractsCompliancePage extends StatelessWidget {
  final Map<String, dynamic> report;

  const ContractsCompliancePage({super.key, required this.report});

  static const sections = [
    (
      'service_providers',
      'Service Providers',
      'Manage service providers, contracts, contacts and renewal dates.',
      Icons.business_outlined,
    ),
    (
      'licences_regulatory',
      'Licences & Regulatory',
      'Track property licences, permits, regulatory requirements and renewals.',
      Icons.gavel_outlined,
    ),
    (
      'compliance_best_practices',
      'Compliance & Best Practices',
      'Monitor compliance requirements, inspections and best practices.',
      Icons.fact_check_outlined,
    ),
    (
      'insurance_policies',
      'Insurance Policies',
      'Manage insurance policies, coverage details and renewal dates.',
      Icons.policy_outlined,
    ),
    (
      'insurance_claims',
      'Insurance Claims',
      'Track insurance claims, submissions, progress and settlements.',
      Icons.assignment_outlined,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final reportDate =
        report['report_month'] ?? report['month'] ?? report['report_date'];

    final parsedDate = reportDate == null
        ? null
        : DateTime.tryParse(reportDate.toString());

    final monthLabel = parsedDate == null
        ? 'Contracts & compliance records'
        : '${_monthName(parsedDate.month)} ${parsedDate.year}';

    return Scaffold(
      appBar: AppBar(title: const Text('Contracts & Compliance')),
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
                        Icons.verified_user_outlined,
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
                            'Contracts & Compliance Management',
                            style: Theme.of(context).textTheme.headlineSmall
                                ?.copyWith(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Manage service providers, regulatory '
                            'requirements, compliance and insurance records.',
                            style: Theme.of(context).textTheme.bodyMedium
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
                'Contracts & Compliance Sections',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: AppColors.black,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Choose a section to manage its records.',
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: AppColors.grey),
              ),
              const SizedBox(height: 18),
              LayoutBuilder(
                builder: (context, constraints) {
                  final columns = constraints.maxWidth >= 800
                      ? 3
                      : constraints.maxWidth >= 520
                      ? 2
                      : 1;

                  final cardWidth =
                      (constraints.maxWidth - (columns - 1) * 16) / columns;

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
                            report,
                          ),
                        ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionCard(
    BuildContext context,
    String sectionId,
    String title,
    String description,
    IconData icon,
    Map<String, dynamic> report,
  ) {
    return SizedBox(
      height: 230,
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () {
            if (sectionId == 'service_providers') {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ServiceProvidersPage(report: report),
                ),
              );
            } else if (sectionId == 'licences_regulatory') {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => LicenseRegulatoryPage(report: report),
                ),
              );
            } else if (sectionId == 'compliance_best_practices') {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ComplianceBestPracticesPage(report: report),
                ),
              );
            } else if (sectionId == 'insurance_policies') {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                     insurance.InsurancePoliciesPage(report: report),
                ),
              );
            } else if (sectionId == 'insurance_claims') {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => claims.InsuranceClaimsPage(report: report,
                  ),
                ),
              );
            } else {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('$title will be implemented next.')),
              );
            }
          },
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
                      child: Icon(icon, color: AppColors.red, size: 25),
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
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: AppColors.black,
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: Text(
                    description,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: AppColors.grey,
                      height: 1.5,
                    ),
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
                    Icon(Icons.arrow_forward, size: 15, color: AppColors.red),
                  ],
                ),
              ],
            ),
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
