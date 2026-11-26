import 'package:flutter/material.dart';

import 'maintenance_works.dart';
import 'complaints_resolution.dart';
import 'agm_egm_resolutions.dart';
import 'lift_incidents.dart';
import 'asset_register.dart';
import 'service_condition_history.dart';
import 'staff.dart';
import '../widgets/styles.dart';

class OperationsPage extends StatelessWidget {
  final Map<String, dynamic> report;

  const OperationsPage({super.key, required this.report});

  static const sections = [
    (
      'maintenance_works',
      'Maintenance & Works',
      'Track repairs, maintenance requests and work orders.',
      Icons.handyman_outlined,
    ),
    (
      'complaints',
      'Complaints',
      'Track resident complaints and their resolutions.',
      Icons.support_agent_outlined,
    ),
    (
      'agm_egm_resolutions',
      'AGM/EGM Resolutions',
      'Track meeting resolutions and follow-up actions.',
      Icons.groups_outlined,
    ),
    (
      'lift_incidents',
      'Lift Incidents',
      'Record lift breakdowns, incidents and mantrap events.',
      Icons.elevator_outlined,
    ),
    (
      'asset_register',
      'Asset Register',
      'Maintain an inventory of property assets.',
      Icons.inventory_2_outlined,
    ),

    (
      'service_condition_history',
      'Service & Condition History',
      'Review asset servicing, inspections and condition history.',
      Icons.fact_check_outlined,
    ),
    (
      'staff',
      'Staff',
      'Manage staff deployment, shifts and manpower records.',
      Icons.people_outline,
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
        ? 'Monthly operations records'
        : '${_monthName(parsedDate.month)} ${parsedDate.year}';

    return Scaffold(
      appBar: AppBar(title: const Text('Operations')),
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
                        Icons.handyman_outlined,
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
                            'Operations Management',
                            style: Theme.of(context).textTheme.headlineSmall
                                ?.copyWith(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Manage property maintenance, assets, staffs and '
                            'operational records.',
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
                'Operations Sections',
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
                          height: 200,
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
  ) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          if (sectionId == 'maintenance_works') {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => MaintenanceWorksPage(report: report),
              ),
            );
          } else if (sectionId == 'complaints') {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ComplaintsResolutionPage(report: report),
              ),
            );
          } else if (sectionId == 'agm_egm_resolutions') {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => AgmEgmResolutionsPage(report: report)
              ),
            );
          } else if (sectionId == 'lift_incidents') {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => LiftIncidentsPage(report: report),
              ),
            );
          } else if (sectionId == 'asset_register') {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => AssetRegisterPage(report: report),
              ),
            );
          } else if (sectionId == 'service_condition_history') {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ServiceConditionHistoryPage(report: report),
              ),
            );
          } else if (sectionId == 'staff') {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => StaffPage(report: report),
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
              const Spacer(),
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
