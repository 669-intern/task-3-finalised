import 'package:flutter/material.dart';

import '../widgets/styles.dart';
import 'occupancy.dart';
import 'unit_movement.dart';
import 'renovation_works.dart';
import 'sub_sales_units.dart';

class OccupancyUnitPage extends StatelessWidget {
  final Map<String, dynamic> report;

  const OccupancyUnitPage({super.key, required this.report});

  static const sections = [
    (
      'Occupancy',
      'Manage occupancy counts, total units and occupancy rates.',
      Icons.apartment_outlined,
    ),
    (
      'Unit Movement',
      'Record move-ins and move-outs and track unit movements.',
      Icons.swap_horiz_outlined,
    ),
    (
      'Renovation Works',
      'Track renovation details, deposits and refund status.',
      Icons.construction_outlined,
    ),
    (
      'Sub-Sales Units',
      'Record sub-sales transactions and ownership changes.',
      Icons.real_estate_agent_outlined,
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
        ? 'Selected month'
        : '${_monthName(parsedDate.month)} ${parsedDate.year}';

    return Scaffold(
      appBar: AppBar(title: const Text('Occupancy & Unit Management')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1100),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              // Header banner
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
                        Icons.apartment_outlined,
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
                            'Occupancy & Unit Management',
                            style: Theme.of(context).textTheme.headlineSmall
                                ?.copyWith(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Manage occupancy, unit movements and renovation works in one place.',
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

              // Section heading
              Text(
                'Management Sections',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: AppColors.black,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Choose a section to view or update its records.',
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: AppColors.grey),
              ),

              const SizedBox(height: 18),
              // 1 row × 3 columns
              LayoutBuilder(
                builder: (context, constraints) {
                  const spacing = 16.0;
                  final cardWidth = (constraints.maxWidth - spacing * 2) / 3;

                  return Wrap(
                    spacing: spacing,
                    runSpacing: spacing,
                    children: [
                      for (final section in sections)
                        SizedBox(
                          width: cardWidth,
                          child: _sectionCard(
                            context,
                            section.$1,
                            section.$2,
                            section.$3,
                          ),
                        ),
                    ],
                  );
                },
              ),

              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionCard(
    BuildContext context,
    String title,
    String description,
    IconData icon,
  ) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          final Widget page;

          switch (title) {
            case 'Occupancy':
              page = Occupancy(report: report);
              break;
            case 'Unit Movement':
              page = UnitMovement(report: report);
              break;
            case 'Renovation Works':
              page = RenovationWorks(report: report);
              break;
            case 'Sub-Sales Units':
              page = SubSalesUnits(report: report);
              break;
            default:
              return;
          }

          Navigator.push(context, MaterialPageRoute(builder: (_) => page));
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
