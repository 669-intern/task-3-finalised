import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../widgets/styles.dart';

class AssetRegisterPage extends StatefulWidget {
  final Map<String, dynamic> report;

  const AssetRegisterPage({
    super.key,
    required this.report,
  });

  @override
  State<AssetRegisterPage> createState() => _AssetRegisterPageState();
}

class _AssetRegisterPageState extends State<AssetRegisterPage> {
  final SupabaseClient _supabase = Supabase.instance.client;
  final TextEditingController _searchController = TextEditingController();

  List<Map<String, dynamic>> _assets = [];
  List<Map<String, dynamic>> _categories = [];
  List<Map<String, dynamic>> _subcategories = [];
  bool _loading = true;
  bool _categoriesLoading = true;
  bool _saving = false;
  bool _openingCategories = false;
  bool _canViewCategories = false;
  bool _canAddCategories = false;
  bool _canEditCategories = false;
  bool _canDeleteCategories = false;
  String? _error;
  String? _categoryError;
  // Asset register is property-wide, not monthly snapshot data.
  // The two status cards are multi-select filters.
  final Set<String> _selectedStatuses = <String>{};
  // Null means show all main categories or subcategories.
  String? _selectedCategory;
  String? _selectedSubcategory;
  bool _categoryMenuOpen = false;
  String? _expandedCategory;

  // Legacy records can still have a subcategory saved in the category field.
  // Group these for filtering only; no existing Supabase values are changed.
  static const Map<String, String> _legacyMainCategories = {
    'air-conditioning equipment': 'Air-Conditioning Equipment',
    'pump equipment': 'Pump Equipment',
    'mechanical ventilation systems': 'Mechanical Ventilation Systems',
    'fire protection system': 'Fire Protection Systems',
    'fire protection systems': 'Fire Protection Systems',
    'aircond': 'Air-Conditioning Equipment',
    'air conditioning': 'Air-Conditioning Equipment',
    'air-conditioning': 'Air-Conditioning Equipment',
    'sprinkler pump': 'Pump Equipment',
    'suction pump': 'Pump Equipment',
    'mechanical ventilation system': 'Mechanical Ventilation Systems',
    'fire alarm system': 'Fire Protection Systems',
    'fire damper': 'Fire Protection Systems',
    'fire extinguisher': 'Fire Protection Systems',
    'fireman intercom': 'Fire Protection Systems',
    'co2': 'Fire Protection Systems',
    'hose reel system': 'Fire Protection Systems',
    'hydrant system': 'Fire Protection Systems',
    'sprinkler system': 'Fire Protection Systems',
    'lr level': 'Pump Equipment',
    'wet riser': 'Pump Equipment',
    'wet riser system': 'Fire Protection Systems',
  };

  String get _siteId => widget.report['site_id'].toString();
  String get _reportId => widget.report['id'].toString();
  bool get _readOnly => widget.report['status'] != 'draft';

  String _mainCategoryFor(Map<String, dynamic> asset) {
    final category = asset['category']?.toString().trim() ?? '';
    if (category.isEmpty) return 'Uncategorised';
    // Prefer a configured main category over a legacy alias, matching Supabase.
    for (final name in _mainCategories) {
      if (name.trim().toLowerCase() == category.toLowerCase()) return name;
    }
    return _legacyMainCategories[category.toLowerCase()] ?? category;
  }

  String? _subcategoryFor(Map<String, dynamic> asset) {
    final saved = asset['subcategory']?.toString().trim() ?? '';
    if (saved.isNotEmpty) return saved;

    // Legacy categories such as Fire Alarm System are treated as
    // subcategories in the filter until their records are reclassified.
    final category = asset['category']?.toString().trim() ?? '';
    final main = _mainCategoryFor(asset);
    if (category.isNotEmpty && category.toLowerCase() != main.toLowerCase()) {
      return category;
    }
    return null;
  }

  List<String> get _mainCategories => _categories
      .map((row) => row['name']?.toString() ?? '')
      .where((name) => name.isNotEmpty)
      .toList();

  List<String> _subcategoriesFor(String mainCategory) {
    String? categoryId;
    for (final category in _categories) {
      if (category['name']?.toString() == mainCategory) {
        categoryId = category['id']?.toString();
        break;
      }
    }
    if (categoryId == null) return [];

    return _subcategories
        .where((row) => row['category_id']?.toString() == categoryId)
        .map((row) => row['name']?.toString() ?? '')
        .where((name) => name.isNotEmpty)
        .toList();
  }

  void _chooseCategory(String? mainCategory, [String? subcategory]) {
    setState(() {
      _selectedCategory = mainCategory;
      _selectedSubcategory = subcategory;
      _expandedCategory = null;
      _categoryMenuOpen = false;
    });
  }

  List<Map<String, dynamic>> get _filteredAssets {
    final query = _searchController.text.trim().toLowerCase();

    return _assets.where((asset) {
      final status = asset['status']?.toString() ?? 'Active';

      if (_selectedStatuses.isNotEmpty &&
          !_selectedStatuses.contains(status)) {
        return false;
      }

      if (_selectedCategory != null &&
          _mainCategoryFor(asset) != _selectedCategory) {
        return false;
      }
      if (_selectedSubcategory != null &&
          _subcategoryFor(asset) != _selectedSubcategory) {
        return false;
      }

      if (query.isEmpty) return true;

      final searchable = [
        asset['asset_id'],
        asset['asset_item'],
        asset['category'],
        asset['subcategory'],
        asset['location'],
        asset['brand_model'],
        asset['capacity_rating'],
        asset['remarks'],
      ].whereType<Object>().join(' ').toLowerCase();

      return searchable.contains(query);
    }).toList();
  }

  int get _activeCount =>
      _assets.where((asset) => asset['status'] == 'Active').length;

  int get _retiredCount =>
      _assets.where((asset) => asset['status'] == 'Retired').length;

  void _toggleStatus(String? status) {
    setState(() {
      if (status == null) {
        _selectedStatuses.clear();
      } else if (!_selectedStatuses.add(status)) {
        _selectedStatuses.remove(status);
      }
    });
  }

  @override
  void initState() {
    super.initState();

    if (widget.report['site_id'] == null ||
        widget.report['id'] == null) {
      _loading = false;
      _categoriesLoading = false;
      _error = 'The property or monthly report ID is missing.';
    } else {
      _loadAssets();
      _loadCategories();
    }
  }

  @override
  void didUpdateWidget(covariant AssetRegisterPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.report['site_id']?.toString() != widget.report['site_id']?.toString()) {
      _assets = [];
      _categories = [];
      _subcategories = [];
      _canViewCategories = false;
      _canAddCategories = false;
      _canEditCategories = false;
      _canDeleteCategories = false;
      _selectedCategory = null;
      _selectedSubcategory = null;
      _expandedCategory = null;
      _categoryMenuOpen = false;
      _selectedStatuses.clear();
      _searchController.clear();
      if (widget.report['site_id'] == null || widget.report['id'] == null) {
        _loading = false;
        _categoriesLoading = false;
        _error = 'The property or monthly report ID is missing.';
      } else {
        _loadAssets();
        _loadCategories();
      }
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadAssets() async {
    final requestedSite = _siteId;
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final result = await _supabase
          .from('asset_register')
          .select()
          .eq('site_id', requestedSite)
          .order('asset_id');

      if (!mounted || _siteId != requestedSite) return;

      setState(() {
        _assets = List<Map<String, dynamic>>.from(result);
        // Keep the filter valid if the selected asset is edited or deleted.
        if (_selectedCategory != null &&
            !_assets.any(
              (asset) => _mainCategoryFor(asset) == _selectedCategory,
            )) {
          _selectedCategory = null;
          _selectedSubcategory = null;
        } else if (_selectedSubcategory != null &&
            !_assets.any(
              (asset) =>
                  _mainCategoryFor(asset) == _selectedCategory &&
                  _subcategoryFor(asset) == _selectedSubcategory,
            )) {
          _selectedSubcategory = null;
        }
        _loading = false;
      });
    } catch (e) {
      if (!mounted || _siteId != requestedSite) return;

      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _loadCategories() async {
    if (!mounted) return;
    final requestedSite = _siteId;
    setState(() {
      _categoriesLoading = true;
      _categoryError = null;
    });

    List<Map<String, dynamic>> loadedCategories = [];
    List<Map<String, dynamic>> loadedSubcategories = [];
    String? loadError;
    final permissions = <String, bool>{};

    try {
      final categoryRows = await _supabase
          .from('asset_categories')
          .select('id, name, sort_order, asset_id_prefix')
          .eq('site_id', requestedSite)
          .eq('is_active', true)
          .order('sort_order')
          .order('name');
      loadedCategories = List<Map<String, dynamic>>.from(categoryRows);

      final categoryIds = loadedCategories
          .map((row) => row['id']?.toString() ?? '')
          .where((id) => id.isNotEmpty)
          .toList();
      if (categoryIds.isNotEmpty) {
        final subcategoryRows = await _supabase
            .from('asset_subcategories')
            .select('id, category_id, name, sort_order, asset_id_prefix')
            .inFilter('category_id', categoryIds)
            .eq('is_active', true)
            .order('sort_order')
            .order('name');
        loadedSubcategories =
            List<Map<String, dynamic>>.from(subcategoryRows);
      }
    } catch (e) {
      loadError = e.toString();
    }

    // Use the same property-scoped permissions as Supabase RLS.
    try {
      const actions = ['view', 'add', 'edit', 'delete'];
      final results = await Future.wait(actions.map((action) async =>
          await _supabase.rpc('asset_category_permission', params: {
            'p_site_id': requestedSite,
            'p_action': action,
          })));
      for (var i = 0; i < actions.length; i++) {
        permissions[actions[i]] = results[i] == true;
      }
    } catch (e) {
      // Fail closed rather than enabling actions without authorization.
      loadError ??= e.toString();
    }

    if (!mounted || _siteId != requestedSite) return;
    setState(() {
      _categories = permissions['view'] == true ? loadedCategories : [];
      _subcategories = permissions['view'] == true ? loadedSubcategories : [];
      _canViewCategories = permissions['view'] == true;
      _canAddCategories = permissions['add'] == true;
      _canEditCategories = permissions['edit'] == true;
      _canDeleteCategories = permissions['delete'] == true;
      _categoriesLoading = false;
      _categoryError = loadError;
    });
  }

  String? get _categoryStatusMessage {
    if (_categoriesLoading) return 'Loading categories...';
    if (_categoryError != null) {
      return 'Could not load categories: $_categoryError';
    }
    if (!_canViewCategories) {
      return 'You do not have permission to view categories for this property.';
    }
    if (_mainCategories.isEmpty) {
      return _canAddCategories && !_readOnly
          ? 'No main categories yet. Open Edit Categories to add the first one.'
          : 'No main categories have been configured for this property.';
    }
    return null;
  }

  Future<void> _editAsset([Map<String, dynamic>? asset]) async {
    if (_readOnly || _saving) return;
    if (_categoriesLoading || _categoryError != null || !_canViewCategories) {
      _message(_categoryStatusMessage ?? 'Categories are unavailable.',
          error: !_categoriesLoading);
      return;
    }
    if (asset == null && _mainCategories.isEmpty) {
      _message(_categoryStatusMessage ?? 'Add a main category first.');
      if (_canAddCategories) await _editCategories();
      return;
    }

    final formKey = GlobalKey<FormState>();
    final isEditing = asset != null;

    final location = TextEditingController(
      text: asset?['location']?.toString() ?? '',
    );
    final item = TextEditingController(
      text: asset?['asset_item']?.toString() ?? '',
    );
    final qty = TextEditingController(
      text: asset?['qty']?.toString() ?? '1',
    );
    final brandModel = TextEditingController(
      text: asset?['brand_model']?.toString() ?? '',
    );
    final capacity = TextEditingController(
      text: asset?['capacity_rating']?.toString() ?? '',
    );
    final remarks = TextEditingController(
      text: asset?['remarks']?.toString() ?? '',
    );

    String status = asset?['status']?.toString() ?? 'Active';
    String? selectedMainCategory =
        asset == null ? null : _mainCategoryFor(asset);
    String? selectedSubcategory =
        asset == null ? null : _subcategoryFor(asset);

    // Include a legacy selection when editing, even if it is not in the
    // active category list. No existing record is changed until saved.
    final availableMainCategories = <String>{
      ..._mainCategories,
      ?selectedMainCategory,
    }.toList();

    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: !_saving,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: AppColors.white,
          surfaceTintColor: Colors.transparent,
          title: Text(
            isEditing ? 'Edit Asset' : 'Register New Asset',
            style: const TextStyle(
              color: AppColors.black,
              fontWeight: FontWeight.bold,
            ),
          ),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Form(
                key: formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      isEditing
                          ? 'Update the asset details below.'
                          : 'Enter the details for the new property asset.',
                      style: const TextStyle(
                        color: AppColors.grey,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 20),
                    _sectionLabel('ASSET IDENTIFICATION'),
                    const SizedBox(height: 12),

                    if (isEditing)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: InputDecorator(
                          decoration: const InputDecoration(labelText: 'Asset ID'),
                          child: Text(asset['asset_id']?.toString() ?? ''),
                        ),
                      ),

                    _field(item, 'Asset Item',
                        hint: 'e.g. Passenger Lift'),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: DropdownButtonFormField<String>(
                        key: ValueKey('main-${selectedMainCategory ?? ''}'),
                        initialValue: selectedMainCategory,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Main Category',
                        ),
                        items: [
                          for (final name in availableMainCategories)
                            DropdownMenuItem<String>(
                              value: name,
                              child: Text(name),
                            ),
                        ],
                        validator: (value) =>
                            value == null || value.isEmpty
                                ? 'Main Category is required.'
                                : null,
                        onChanged: (value) {
                          setDialogState(() {
                            selectedMainCategory = value;
                            selectedSubcategory = null;
                          });
                        },
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: DropdownButtonFormField<String>(
                        key: ValueKey(
                          'subcategory-${selectedMainCategory ?? ''}-${selectedSubcategory ?? ''}',
                        ),
                        initialValue: selectedSubcategory ?? '',
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Subcategory (Optional)',
                        ),
                        items: [
                          const DropdownMenuItem<String>(
                            value: '',
                            child: Text('None'),
                          ),
                          for (final name in <String>{
                            if (selectedMainCategory != null)
                              ..._subcategoriesFor(selectedMainCategory!),
                            if (selectedSubcategory != null)
                              selectedSubcategory!,
                          })
                            DropdownMenuItem<String>(
                              value: name,
                              child: Text(name),
                            ),
                        ],
                        onChanged: (value) {
                          setDialogState(() {
                            selectedSubcategory =
                                value == null || value.isEmpty ? null : value;
                          });
                        },
                      ),
                    ),
                    const SizedBox(height: 8),
                    _sectionLabel('LOCATION & SPECIFICATIONS'),
                    const SizedBox(height: 12),
                    _field(location, 'Location (Optional)',
                        required: false, hint: 'e.g. Block A, Level 1'),
                    _field(
                      qty,
                      'Quantity',
                      keyboardType: TextInputType.number,
                      validator: (value) {
                        final number = int.tryParse(value?.trim() ?? '');
                        if (number == null || number < 1) {
                          return 'Enter a whole number of at least 1.';
                        }
                        return null;
                      },
                    ),
                    _field(
                      brandModel,
                      'Brand / Model',
                      required: false,
                      hint: 'Optional',
                    ),
                    _field(
                      capacity,
                      'Capacity / Rating',
                      required: false,
                      hint: 'Optional',
                    ),
                    const SizedBox(height: 8),
                    _sectionLabel('STATUS & NOTES'),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: status,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Asset Status',
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: 'Active',
                          child: Text('Active'),
                        ),
                        DropdownMenuItem(
                          value: 'Retired',
                          child: Text('Retired'),
                        ),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          setDialogState(() => status = value);
                        }
                      },
                    ),
                    const SizedBox(height: 16),
                    _field(
                      remarks,
                      'Remarks',
                      required: false,
                      maxLines: 3,
                      hint: 'Additional information (optional)',
                    ),
                  ],
                ),
              ),
            ),
          ),
          actionsPadding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
          actions: [
            TextButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.red,
                foregroundColor: AppColors.white,
              ),
              onPressed: () {
                if (formKey.currentState!.validate()) {
                  Navigator.of(dialogContext).pop(true);
                }
              },
              child: Text(isEditing ? 'Save Changes' : 'Add Asset'),
            ),
          ],
        ),
      ),
    );

    if (saved != true || !mounted) {
      _disposeControllers([
        location, item, qty,
        brandModel, capacity, remarks,
      ]);
      return;
    }

    setState(() => _saving = true);

    try {
      final values = <String, dynamic>{
        'category': selectedMainCategory!,
        'subcategory': selectedSubcategory,
        'location': _nullable(location.text),
        'asset_item': item.text.trim(),
        'qty': int.parse(qty.text.trim()),
        'brand_model': _nullable(brandModel.text),
        'capacity_rating': _nullable(capacity.text),
        'status': status,
        'remarks': _nullable(remarks.text),
      };

      String? generatedAssetId;
      if (isEditing) {
        await _supabase
            .from('asset_register')
            .update(values)
            .eq('id', asset['id'].toString())
            .eq('site_id', _siteId)
            .select('id')
            .single();
      } else {
        final inserted = await _supabase.from('asset_register').insert({
          ...values,
          'site_id': _siteId,
        }).select('asset_id').single();
        generatedAssetId = inserted['asset_id']?.toString();
      }

      await _loadAssets();

      if (!mounted) return;
      _message(isEditing
          ? 'Asset updated successfully.'
          : 'Asset added successfully: ${generatedAssetId ?? ""}');
    } catch (e) {
      if (!mounted) return;
      _message('Could not save asset: $e', error: true);
    } finally {
      _disposeControllers([
        location, item, qty,
        brandModel, capacity, remarks,
      ]);

      if (mounted) setState(() => _saving = false);
    }
  }

  // Keep renames/deletions transactional with the linked asset records.
  Future<void> _renameMainCategory(String id, String name, String prefix) async {
    await _supabase.rpc('asset_category_admin_action', params: {
      'p_action': 'rename_main',
      'p_target_id': id,
      'p_new_name': name,
      'p_new_prefix': prefix,
    });
  }

  Future<void> _renameSubcategory(String id, String name, String? prefix) async {
    await _supabase.rpc('asset_category_admin_action', params: {
      'p_action': 'rename_sub',
      'p_target_id': id,
      'p_new_name': name,
      'p_new_prefix': prefix,
    });
  }

  Future<void> _deleteMainCategory(String id) async {
    await _supabase.rpc('asset_category_admin_action', params: {
      'p_action': 'delete_main',
      'p_target_id': id,
      'p_new_name': null,
    });
  }

  Future<void> _deleteSubcategory(String id) async {
    await _supabase.rpc('asset_category_admin_action', params: {
      'p_action': 'delete_sub',
      'p_target_id': id,
      'p_new_name': null,
    });
  }

  Future<void> _editCategories() async {
    if (_saving || _categoriesLoading || _openingCategories) return;

    final requestedSite = _siteId;
    final requestedReport = _reportId;
    setState(() => _openingCategories = true);

    try {
      // Refresh the real property-scoped permissions before opening the dialog.
      await _loadCategories();
      if (!mounted || _siteId != requestedSite || _reportId != requestedReport) {
        return;
      }
      if (_categoryError != null || !_canViewCategories) {
        _message(_categoryStatusMessage ?? 'Categories are unavailable.',
            error: true);
        return;
      }

      // Check the selected report in Supabase instead of relying on a possibly
      // missing or stale status in the navigation payload.
      final currentReport = await _supabase
          .from('monthly_reports')
          .select('status')
          .eq('id', requestedReport)
          .eq('site_id', requestedSite)
          .maybeSingle();
      if (!mounted || _siteId != requestedSite || _reportId != requestedReport) {
        return;
      }
      if (currentReport == null) {
        _message('The selected monthly report is unavailable or inaccessible.',
            error: true);
        return;
      }
      final reportStatus = currentReport['status']?.toString().trim().toLowerCase();
      if (reportStatus != 'draft') {
        _message('This report is read-only. Open a draft report to edit categories.');
        return;
      }

      await _showCategoryDialog();
    } catch (e) {
      if (mounted && _siteId == requestedSite && _reportId == requestedReport) {
        _message('Could not open Edit Categories: $e', error: true);
      }
    } finally {
      if (mounted) setState(() => _openingCategories = false);
    }
  }

  Future<void> _showCategoryDialog() async {
    if (_saving || !_canViewCategories || _categoriesLoading) return;
    if (_categoryError != null) {
      _message(_categoryStatusMessage ?? 'Could not load categories.', error: true);
      return;
    }

    final mainName = TextEditingController();
    final subName = TextEditingController();
    final editName = TextEditingController();
    final mainPrefix = TextEditingController();
    final subPrefix = TextEditingController();
    final editPrefix = TextEditingController();
    String tab = 'main';
    String? parentId = _categories.isEmpty
        ? null
        : _categories.first['id']?.toString();
    String? editingId;
    String? deletingId;
    bool busy = false;
    String? dialogError;
    String? dialogSuccess;

    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) {
            final parents = _categories;
            if (parentId == null ||
                !parents.any((row) => row['id']?.toString() == parentId)) {
              parentId = parents.isEmpty
                  ? null
                  : parents.first['id']?.toString();
            }

            String parentName = '';
            String parentPrefix = '';
            for (final row in parents) {
              if (row['id']?.toString() == parentId) {
                parentName = row['name']?.toString() ?? '';
                parentPrefix = row['asset_id_prefix']?.toString() ?? '';
                break;
              }
            }

            final showingMain = tab == 'main';
            final rows = showingMain
                ? parents
                : _subcategories
                    .where((row) => row['category_id']?.toString() == parentId)
                    .toList();
            final newController = showingMain ? mainName : subName;
            final newPrefixController = showingMain ? mainPrefix : subPrefix;
            final newText = newController.text.trim();
            final newPrefix = newPrefixController.text.trim().toUpperCase();
            final validNewPrefix = _validAssetPrefix(newPrefix,
                isRequired: showingMain);
            final alreadyExists = rows.any((row) =>
                (row['name']?.toString() ?? '').toLowerCase() ==
                newText.toLowerCase());

            return AlertDialog(
              backgroundColor: AppColors.white,
              surfaceTintColor: Colors.transparent,
              title: const Text(
                'Edit Categories',
                style: TextStyle(
                  color: AppColors.black,
                  fontWeight: FontWeight.bold,
                ),
              ),
              content: SizedBox(
                width: 520,
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                backgroundColor: showingMain
                                    ? AppColors.charcoal
                                    : AppColors.white,
                                foregroundColor: showingMain
                                    ? AppColors.white
                                    : AppColors.grey,
                                side: const BorderSide(color: AppColors.border),
                              ),
                              onPressed: busy
                                  ? null
                                  : () => setDialogState(() {
                                        tab = 'main';
                                        editingId = null;
                                        deletingId = null;
                                        dialogError = null;
                                        dialogSuccess = null;
                                      }),
                              child: const Text('Main Categories'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                backgroundColor: !showingMain
                                    ? AppColors.charcoal
                                    : AppColors.white,
                                foregroundColor: !showingMain
                                    ? AppColors.white
                                    : AppColors.grey,
                                side: const BorderSide(color: AppColors.border),
                              ),
                              onPressed: busy
                                  ? null
                                  : () => setDialogState(() {
                                        tab = 'sub';
                                        editingId = null;
                                        deletingId = null;
                                        dialogError = null;
                                        dialogSuccess = null;
                                      }),
                              child: const Text('Subcategories'),
                            ),
                          ),
                        ],
                      ),
                      if (!showingMain) ...[
                        const SizedBox(height: 16),
                        DropdownButtonFormField<String>(
                          key: ValueKey('parent-${parentId ?? ''}'),
                          initialValue: parentId,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Main Category',
                          ),
                          items: [
                            for (final row in parents)
                              DropdownMenuItem<String>(
                                value: row['id'].toString(),
                                child: Text(row['name'].toString()),
                              ),
                          ],
                          onChanged: busy
                              ? null
                              : (value) => setDialogState(() {
                                    parentId = value;
                                    editingId = null;
                                    deletingId = null;
                                    dialogError = null;
                                    dialogSuccess = null;
                                  }),
                        ),
                      ],
                      const SizedBox(height: 18),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              showingMain ? 'Main Categories' : 'Subcategories',
                              style: const TextStyle(
                                color: AppColors.black,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          Text(
                            '${rows.length} items',
                            style: const TextStyle(
                              color: AppColors.grey,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 300),
                        child: rows.isEmpty
                            ? const Padding(
                                padding: EdgeInsets.symmetric(vertical: 16),
                                child: Text(
                                  'No categories added yet.',
                                  style: TextStyle(color: AppColors.grey),
                                ),
                              )
                            : ListView(
                                shrinkWrap: true,
                                primary: false,
                                children: [
                                  for (final row in rows) ...[
                                    Builder(builder: (context) {
                                      final id = row['id'].toString();
                                      final name = row['name']?.toString() ?? '';
                                      final prefix = row['asset_id_prefix']?.toString() ?? '';
                                      final editedPrefix = editPrefix.text.trim().toUpperCase();
                                      final validEditPrefix = _validAssetPrefix(editedPrefix,
                                          isRequired: showingMain);
                                      final childCount = showingMain
                                          ? _subcategories
                                              .where((s) =>
                                                  s['category_id']?.toString() == id)
                                              .length
                                          : 0;
                                      final linkedCount = showingMain
                                          ? _assets.where((asset) =>
                                              _mainCategoryFor(asset) == name).length
                                          : _assets.where((asset) =>
                                              _mainCategoryFor(asset) == parentName &&
                                              _subcategoryFor(asset) == name).length;
                                      final blocked = linkedCount > 0 ||
                                          (showingMain && childCount > 0);
                                      final duplicateEdit = rows.any((other) =>
                                          other['id']?.toString() != id &&
                                          (other['name']?.toString() ?? '')
                                                  .toLowerCase() ==
                                              editName.text.trim().toLowerCase());
                                      final isEditing = editingId == id;
                                      final isDeleting = deletingId == id;

                                      return Container(
                                        margin: const EdgeInsets.only(bottom: 8),
                                        padding: const EdgeInsets.all(12),
                                        decoration: BoxDecoration(
                                          color: AppColors.white,
                                          border: Border.all(color: AppColors.border),
                                          borderRadius: BorderRadius.circular(10),
                                        ),
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Row(
                                              children: [
                                                Expanded(
                                                  child: Column(
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment.start,
                                                    children: [
                                                      Text(
                                                        name,
                                                        style: const TextStyle(
                                                          color: AppColors.black,
                                                          fontWeight: FontWeight.w500,
                                                        ),
                                                      ),
                                                      Text(
                                                        prefix.isNotEmpty
                                                            ? 'Prefix: $prefix'
                                                            : 'Prefix: $parentPrefix (inherited)',
                                                        style: const TextStyle(
                                                          color: AppColors.grey,
                                                          fontSize: 11,
                                                        ),
                                                      ),
                                                      if (showingMain)
                                                        Text(
                                                          '$childCount subcategories',
                                                          style: const TextStyle(
                                                            color: AppColors.grey,
                                                            fontSize: 11,
                                                          ),
                                                        ),
                                                    ],
                                                  ),
                                                ),
                                                if (_canEditCategories)
                                                  IconButton(
                                                    tooltip: 'Edit',
                                                    visualDensity: VisualDensity.compact,
                                                    icon: const Icon(
                                                      Icons.edit_outlined,
                                                      size: 19,
                                                    ),
                                                    onPressed: busy
                                                        ? null
                                                        : () => setDialogState(() {
                                                              editingId = isEditing
                                                                  ? null
                                                                  : id;
                                                              deletingId = null;
                                                              editName.text = name;
                                                              editPrefix.text = prefix;
                                                              dialogError = null;
                                                              dialogSuccess = null;
                                                            }),
                                                  ),
                                                if (_canDeleteCategories)
                                                  IconButton(
                                                    tooltip: 'Delete',
                                                    visualDensity: VisualDensity.compact,
                                                    color: AppColors.red,
                                                    icon: const Icon(
                                                      Icons.delete_outline,
                                                      size: 19,
                                                    ),
                                                    onPressed: busy
                                                        ? null
                                                        : () => setDialogState(() {
                                                              deletingId = isDeleting
                                                                  ? null
                                                                  : id;
                                                              editingId = null;
                                                              dialogError = null;
                                                              dialogSuccess = null;
                                                            }),
                                                  ),
                                              ],
                                            ),
                                            if (isEditing && _canEditCategories) ...[
                                              const SizedBox(height: 10),
                                              TextField(
                                                controller: editName,
                                                onChanged: (_) =>
                                                    setDialogState(() {}),
                                                decoration: InputDecoration(
                                                  labelText: showingMain
                                                      ? 'Main Category Name'
                                                      : 'Subcategory Name',
                                                ),
                                              ),
                                              const SizedBox(height: 10),
                                              TextField(
                                                controller: editPrefix,
                                                enabled: !busy,
                                                textCapitalization: TextCapitalization.characters,
                                                onChanged: (_) => setDialogState(() {}),
                                                decoration: InputDecoration(
                                                  labelText: showingMain
                                                      ? 'Asset ID Prefix'
                                                      : 'Asset ID Prefix (Optional)',
                                                  hintText: showingMain
                                                      ? 'e.g. AC'
                                                      : 'Inherit $parentPrefix when blank',
                                                  errorText: validEditPrefix ? null
                                                      : 'Use 1 to 10 letters or numbers.',
                                                ),
                                              ),
                                              if (duplicateEdit) ...[
                                                const SizedBox(height: 6),
                                                const Text(
                                                  'This name already exists.',
                                                  style: TextStyle(
                                                    color: AppColors.redDark,
                                                    fontSize: 12,
                                                  ),
                                                ),
                                              ],
                                              const SizedBox(height: 8),
                                              Row(
                                                mainAxisAlignment:
                                                    MainAxisAlignment.end,
                                                children: [
                                                  TextButton(
                                                    onPressed: busy
                                                        ? null
                                                        : () => setDialogState(() =>
                                                            editingId = null),
                                                    child: const Text('Cancel'),
                                                  ),
                                                  FilledButton(
                                                    style: FilledButton.styleFrom(
                                                      backgroundColor: AppColors.red,
                                                    ),
                                                    onPressed: busy || !_canEditCategories ||
                                                            editName.text.trim().isEmpty ||
                                                            duplicateEdit || !validEditPrefix ||
                                                            (editName.text.trim() == name &&
                                                                editedPrefix == prefix)
                                                        ? null
                                                        : () async {
                                                            final newName =
                                                                editName.text.trim();
                                                            setDialogState(() {
                                                              busy = true;
                                                              dialogError = null;
                                                              dialogSuccess = null;
                                                            });
                                                            try {
                                                              if (showingMain) {
                                                                await _renameMainCategory(
                                                                    id, newName, editedPrefix);
                                                                if (mounted &&
                                                                    _selectedCategory == name) {
                                                                  setState(() {
                                                                    _selectedCategory = newName;
                                                                    if (_expandedCategory == name) {
                                                                      _expandedCategory = newName;
                                                                    }
                                                                  });
                                                                }
                                                              } else {
                                                                await _renameSubcategory(
                                                                    id, newName, _nullable(editedPrefix));
                                                                if (mounted &&
                                                                    _selectedCategory == parentName &&
                                                                    _selectedSubcategory == name) {
                                                                  setState(() =>
                                                                      _selectedSubcategory = newName);
                                                                }
                                                              }
                                                              await _loadCategories();
                                                              await _loadAssets();
                                                              if (!dialogContext.mounted) return;
                                                              setDialogState(() {
                                                                editingId = null;
                                                                busy = false;
                                                                dialogSuccess = 'Category updated.';
                                                              });
                                                            } catch (e) {
                                                              if (!dialogContext.mounted) return;
                                                              setDialogState(() {
                                                                busy = false;
                                                                dialogError = 'Could not rename category: $e';
                                                              });
                                                            }
                                                          },
                                                    child: const Text('Save'),
                                                  ),
                                                ],
                                              ),
                                            ],
                                            if (isDeleting && _canDeleteCategories) ...[
                                              const SizedBox(height: 10),
                                              Container(
                                                padding: const EdgeInsets.all(10),
                                                decoration: BoxDecoration(
                                                  color: AppColors.background,
                                                  borderRadius: BorderRadius.circular(8),
                                                ),
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    Text(
                                                      'Delete "$name"?',
                                                      style: const TextStyle(
                                                        fontWeight: FontWeight.w600,
                                                      ),
                                                    ),
                                                    const SizedBox(height: 6),
                                                    Text(
                                                      blocked
                                                          ? showingMain && childCount > 0
                                                              ? 'Remove its subcategories before deleting this main category.'
                                                              : 'This category is used by existing assets. Reassign those assets before deleting it.'
                                                          : 'This unused category will be deleted.',
                                                      style: const TextStyle(
                                                        color: AppColors.grey,
                                                        fontSize: 12,
                                                      ),
                                                    ),
                                                    const SizedBox(height: 8),
                                                    Row(
                                                      mainAxisAlignment:
                                                          MainAxisAlignment.end,
                                                      children: [
                                                        TextButton(
                                                          onPressed: busy
                                                              ? null
                                                              : () => setDialogState(() =>
                                                                  deletingId = null),
                                                          child: const Text('Cancel'),
                                                        ),
                                                        FilledButton(
                                                          style: FilledButton.styleFrom(
                                                            backgroundColor: AppColors.red,
                                                          ),
                                                          onPressed: busy || blocked || !_canDeleteCategories
                                                              ? null
                                                              : () async {
                                                                  setDialogState(() {
                                                                    busy = true;
                                                                    dialogError = null;
                                                                    dialogSuccess = null;
                                                                  });
                                                                  try {
                                                                    if (showingMain) {
                                                                      await _deleteMainCategory(id);
                                                                    } else {
                                                                      await _deleteSubcategory(id);
                                                                    }
                                                                    await _loadCategories();
                                                                    if (!dialogContext.mounted) return;
                                                                    setDialogState(() {
                                                                      deletingId = null;
                                                                      busy = false;
                                                                      dialogSuccess = 'Category deleted.';
                                                                    });
                                                                  } catch (e) {
                                                                    if (!dialogContext.mounted) return;
                                                                    setDialogState(() {
                                                                      busy = false;
                                                                      dialogError = 'Could not delete category: $e';
                                                                    });
                                                                  }
                                                                },
                                                          child: const Text('Delete'),
                                                        ),
                                                      ],
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ],
                                          ],
                                        ),
                                      );
                                    }),
                                  ],
                                ],
                              ),
                      ),
                      if (_canAddCategories) ...[
                        const Divider(height: 28),
                        _sectionLabel(showingMain
                            ? 'ADD MAIN CATEGORY'
                            : 'ADD SUBCATEGORY'),
                        const SizedBox(height: 10),
                        TextField(
                          controller: newController,
                          enabled: !busy,
                          onChanged: (_) => setDialogState(() {}),
                          decoration: InputDecoration(
                            hintText: showingMain
                                ? 'Enter main category name'
                                : 'Enter subcategory name',
                          ),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: newPrefixController,
                          enabled: !busy,
                          textCapitalization: TextCapitalization.characters,
                          onChanged: (_) => setDialogState(() {}),
                          decoration: InputDecoration(
                            labelText: showingMain
                                ? 'Asset ID Prefix'
                                : 'Asset ID Prefix (Optional)',
                            hintText: showingMain ? 'e.g. AC'
                                : 'Inherit $parentPrefix when blank',
                            errorText: newPrefix.isNotEmpty && !validNewPrefix
                                ? 'Use 1 to 10 letters or numbers.' : null,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Align(
                          alignment: Alignment.centerRight,
                          child: FilledButton.icon(
                              style: FilledButton.styleFrom(
                                backgroundColor: AppColors.red,
                                foregroundColor: AppColors.white,
                              ),
                              onPressed: busy || !_canAddCategories || newText.isEmpty ||
                                      alreadyExists || !validNewPrefix ||
                                      (!showingMain && parentId == null)
                                  ? null
                                  : () async {
                                      setDialogState(() {
                                        busy = true;
                                        dialogError = null;
                                        dialogSuccess = null;
                                      });
                                      try {
                                        if (showingMain) {
                                          final inserted = await _supabase
                                              .from('asset_categories')
                                              .insert({
                                                'site_id': _siteId,
                                                'name': newText,
                                                'asset_id_prefix': newPrefix,
                                              })
                                              .select('id')
                                              .single();
                                          parentId = inserted['id']?.toString();
                                        } else {
                                          await _supabase
                                              .from('asset_subcategories')
                                              .insert({
                                                'category_id': parentId!,
                                                'name': newText,
                                                'asset_id_prefix': _nullable(newPrefix),
                                              });
                                        }
                                        await _loadCategories();
                                        if (!dialogContext.mounted) return;
                                        setDialogState(() {
                                          newController.clear();
                                          newPrefixController.clear();
                                          busy = false;
                                          dialogSuccess = showingMain
                                              ? 'Main category added.'
                                              : 'Subcategory added.';
                                        });
                                      } catch (e) {
                                        if (!dialogContext.mounted) return;
                                        setDialogState(() {
                                          busy = false;
                                          dialogError = 'Could not add category: $e';
                                        });
                                      }
                                    },
                              icon: const Icon(Icons.add, size: 18),
                              label: const Text('Add'),
                            ),
                        ),
                        if (alreadyExists && newText.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          const Text(
                            'This category already exists.',
                            style: TextStyle(
                              color: AppColors.redDark,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ],
                      if (dialogError != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          dialogError!,
                          style: const TextStyle(color: AppColors.redDark),
                        ),
                      ] else if (dialogSuccess != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          dialogSuccess!,
                          style: const TextStyle(color: Color(0xFF22683D)),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              actionsPadding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
              actions: [
                TextButton(
                  onPressed: busy
                      ? null
                      : () => Navigator.of(dialogContext).pop(),
                  child: const Text('Close'),
                ),
              ],
            );
          },
        ),
      );
    } finally {
      mainName.dispose();
      subName.dispose();
      editName.dispose();
      mainPrefix.dispose();
      subPrefix.dispose();
      editPrefix.dispose();
    }
  }

  Future<void> _deleteAsset(Map<String, dynamic> asset) async {
    if (_readOnly || _saving) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.white,
        title: const Text('Delete Asset?'),
        content: Text(
          'Delete ${asset['asset_id']} — ${asset['asset_item']}?\n\n'
          'Assets referenced by historical condition or service records '
          'cannot be deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.red,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _saving = true);

    try {
      await _supabase
          .from('asset_register')
          .delete()
          .eq('id', asset['id'].toString())
          .eq('site_id', _siteId);

      await _loadAssets();

      if (!mounted) return;
      _message('Asset deleted successfully.');
    } catch (e) {
      if (!mounted) return;
      _message('Could not delete asset: $e', error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _setRetired(
    Map<String, dynamic> asset,
    bool retired,
  ) async {
    if (_readOnly || _saving) return;

    setState(() => _saving = true);

    try {
      await _supabase
          .from('asset_register')
          .update({'status': retired ? 'Retired' : 'Active'})
          .eq('id', asset['id'].toString())
          .eq('site_id', _siteId);

      await _loadAssets();

      if (!mounted) return;
      _message(retired ? 'Asset retired.' : 'Asset reactivated.');
    } catch (e) {
      if (!mounted) return;
      _message('Could not update asset: $e', error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  bool _validAssetPrefix(String value, {required bool isRequired}) {
    final normalized = value.trim().toUpperCase();
    return normalized.isEmpty
        ? !isRequired
        : RegExp(r'^[A-Z0-9]{1,10}$').hasMatch(normalized);
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    bool required = true,
    TextInputType? keyboardType,
    String? Function(String?)? validator,
    String? hint,
    int maxLines = 1,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: TextFormField(
        controller: controller,
        keyboardType: keyboardType,
        maxLines: maxLines,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          alignLabelWithHint: maxLines > 1,
        ),
        validator: validator ??
            (value) {
              if (required && (value == null || value.trim().isEmpty)) {
                return '$label is required.';
              }
              return null;
            },
      ),
    );
  }

  Widget _sectionLabel(String text) {
    return Text(
      text,
      style: const TextStyle(
        color: AppColors.red,
        fontSize: 11,
        fontWeight: FontWeight.bold,
        letterSpacing: 1.2,
      ),
    );
  }

  String? _nullable(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  void _disposeControllers(List<TextEditingController> controllers) {
    for (final controller in controllers) {
      controller.dispose();
    }
  }

  void _message(String message, {bool error = false}) {
    if (!mounted) return;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor:
              error ? AppColors.redDark : AppColors.charcoal,
        ),
      );
  }

  String _monthLabel() {
    final raw = widget.report['report_month'];

    if (raw == null) return 'Monthly report';

    final date = DateTime.tryParse(raw.toString());
    if (date == null) return 'Monthly report';

    const months = [
      'January', 'February', 'March', 'April',
      'May', 'June', 'July', 'August',
      'September', 'October', 'November', 'December',
    ];

    return '${months[date.month - 1]} ${date.year}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.black,
        foregroundColor: AppColors.white,
        title: const Text('Asset Register'),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1, color: AppColors.red),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _loading || _saving
                ? null
                : () {
                    _loadAssets();
                    _loadCategories();
                  },
            icon: const Icon(Icons.refresh),
          ),
          const SizedBox(width: 8),
        ],
      ),
      floatingActionButton: _readOnly
          ? null
          : FloatingActionButton.extended(
              onPressed: _saving ? null : () => _editAsset(),
              backgroundColor: AppColors.red,
              foregroundColor: AppColors.white,
              icon: const Icon(Icons.add),
              label: const Text('Add Asset'),
            ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1100),
          child: _buildBody(),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.red),
      );
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.error_outline,
                color: AppColors.red,
                size: 44,
              ),
              const SizedBox(height: 12),
              const Text(
                'Unable to load the asset register.',
                style: TextStyle(
                  color: AppColors.black,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              SelectableText(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.grey),
              ),
              const SizedBox(height: 16),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.red,
                ),
                onPressed: _loadAssets,
                child: const Text('Try Again'),
              ),
            ],
          ),
        ),
      );
    }

    final filteredAssets = _filteredAssets;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
      children: [
        _buildHeader(),
        const SizedBox(height: 18),
        _buildSummary(),
        const SizedBox(height: 22),
        _buildFilters(),
        const SizedBox(height: 24),
        Row(
          children: [
            const Expanded(
              child: Text(
                'Property Assets',
                style: TextStyle(
                  color: AppColors.black,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            Text(
              '${filteredAssets.length} records',
              style: const TextStyle(
                color: AppColors.grey,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (_assets.isEmpty)
          _buildEmptyState()
        else if (filteredAssets.isEmpty)
          _buildNoMatches()
        else
          ...filteredAssets.asMap().entries.map(
                (entry) => _buildAssetCard(
                  entry.value,
                  displayNumber: entry.key + 1,
                ),
              ),
        if (_saving) ...[
          const SizedBox(height: 12),
          const LinearProgressIndicator(color: AppColors.red),
        ],
      ],
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: AppColors.charcoal,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.red),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'OPERATIONS',
            style: TextStyle(
              color: AppColors.red,
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Asset Register',
            style: TextStyle(
              color: AppColors.white,
              fontSize: 25,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '${_monthLabel()} • Report ID: $_reportId',
            style: const TextStyle(
              color: Color(0xFFE0E0E0),
              fontSize: 13,
            ),
          ),
          if (_readOnly) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 9,
              ),
              decoration: BoxDecoration(
                color: AppColors.white.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.lock_outline,
                    color: AppColors.white,
                    size: 16,
                  ),
                  SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      'Completed report — editing disabled',
                      style: TextStyle(
                        color: AppColors.white,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSummary() {
    return Column(
      children: [
        SizedBox(
          width: double.infinity,
          child: _summaryCard(
            'Total Assets',
            _assets.length,
            Icons.inventory_2_outlined,
            AppColors.red,
            onTap: () => _toggleStatus(null),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _summaryCard(
                'Active',
                _activeCount,
                Icons.check_circle_outline,
                const Color(0xFF22683D),
                onTap: () => _toggleStatus('Active'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _summaryCard(
                'Retired',
                _retiredCount,
                Icons.archive_outlined,
                AppColors.grey,
                onTap: () => _toggleStatus('Retired'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _summaryCard(
    String label,
    int count,
    IconData icon,
    Color accent, {
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        constraints: const BoxConstraints(minHeight: 106),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: accent, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      color: AppColors.grey,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    '$count',
                    style: const TextStyle(
                      color: AppColors.black,
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFilters() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _searchController,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            hintText: 'Search asset ID, item, category, location...',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: _searchController.text.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear search',
                    onPressed: () {
                      _searchController.clear();
                      setState(() {});
                    },
                    icon: const Icon(Icons.close),
                  ),
          ),
        ),
        const SizedBox(height: 10),
        _buildHierarchicalCategoryFilter(),
        if (_categoryStatusMessage != null) ...[
          const SizedBox(height: 6),
          Text(
            _categoryStatusMessage!,
            style: TextStyle(
              color: _categoryError != null || (!_categoriesLoading && !_canViewCategories)
                  ? AppColors.red
                  : AppColors.grey,
              fontSize: 12,
            ),
          ),
          if (_categoryError != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _saving || _categoriesLoading ? null : _loadCategories,
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('Retry loading categories'),
              ),
            ),
        ],
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text(
                    'Showing:',
                    style: TextStyle(color: AppColors.grey, fontSize: 12),
                  ),
                  if (_selectedStatuses.isEmpty)
                    const Text(
                      'All statuses',
                      style: TextStyle(color: AppColors.grey, fontSize: 12),
                    )
                  else ...[
                    for (final status in ['Active', 'Retired'])
                      if (_selectedStatuses.contains(status))
                        Chip(
                          label: Text(status),
                          visualDensity: VisualDensity.compact,
                          side: const BorderSide(color: AppColors.border),
                        ),
                    TextButton.icon(
                      onPressed: () => _toggleStatus(null),
                      icon: const Icon(Icons.close, size: 16),
                      label: const Text('Clear filter'),
                      style: TextButton.styleFrom(
                        foregroundColor: AppColors.red,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            // Keep the entry point visible; check permission and report status
            // when tapped, and explain any restriction instead of hiding it.
            TextButton.icon(
              onPressed: _saving || _categoriesLoading || _openingCategories
                  ? null
                  : _editCategories,
              icon: const Icon(Icons.settings_outlined, size: 16),
              label: const Text('Edit Categories'),
              style: TextButton.styleFrom(
                foregroundColor: AppColors.red,
                textStyle: const TextStyle(fontWeight: FontWeight.normal),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildHierarchicalCategoryFilter() {
    final label = _selectedCategory == null
        ? 'All Categories'
        : _selectedSubcategory == null
            ? _selectedCategory!
            : '$_selectedCategory  /  $_selectedSubcategory';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: _categoriesLoading || _categoryError != null || !_canViewCategories
              ? null
              : () => setState(() => _categoryMenuOpen = !_categoryMenuOpen),
          child: InputDecorator(
            decoration: const InputDecoration(
              labelText: 'Filter by Main Category',
              border: OutlineInputBorder(),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Icon(
                  _categoryMenuOpen
                      ? Icons.keyboard_arrow_up
                      : Icons.keyboard_arrow_down,
                  color: AppColors.grey,
                ),
              ],
            ),
          ),
        ),
        if (_categoryMenuOpen && !_categoriesLoading &&
            _categoryError == null && _canViewCategories) ...[
          const SizedBox(height: 6),
          Container(
            constraints: const BoxConstraints(maxHeight: 320),
            decoration: BoxDecoration(
              color: AppColors.white,
              border: Border.all(color: AppColors.border),
              borderRadius: BorderRadius.circular(12),
            ),
            clipBehavior: Clip.antiAlias,
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: 4),
              children: [
                ListTile(
                  dense: true,
                  title: const Text('All Categories'),
                  trailing: _selectedCategory == null
                      ? const Icon(Icons.check, color: Color(0xFF22683D))
                      : null,
                  onTap: () => _chooseCategory(null),
                ),
                const Divider(height: 1),
                if (_mainCategories.isEmpty)
                  ListTile(
                    dense: true,
                    title: Text(_categoryStatusMessage ?? 'No main categories.'),
                    onTap: _canAddCategories && !_readOnly && !_saving
                        ? () async {
                            setState(() => _categoryMenuOpen = false);
                            await _editCategories();
                          }
                        : null,
                  ),
                for (final main in _mainCategories) ...[
                  ListTile(
                    dense: true,
                    title: Text(
                      main,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    trailing: _subcategoriesFor(main).isEmpty
                        ? (_selectedCategory == main
                                ? const Icon(
                                    Icons.check,
                                    color: Color(0xFF22683D),
                                  )
                                : null)
                        : Icon(
                            _expandedCategory == main
                                ? Icons.keyboard_arrow_up
                                : Icons.keyboard_arrow_down,
                          ),
                    onTap: () {
                      if (_subcategoriesFor(main).isEmpty) {
                        _chooseCategory(main);
                      } else {
                        setState(() {
                          _expandedCategory =
                              _expandedCategory == main ? null : main;
                        });
                      }
                    },
                  ),
                  if (_expandedCategory == main) ...[
                    if (_subcategoriesFor(main).length > 1)
                      _categorySubOption(
                        'All $main',
                        selected: _selectedCategory == main &&
                            _selectedSubcategory == null,
                        onTap: () => _chooseCategory(main),
                      ),
                    for (final subcategory in _subcategoriesFor(main))
                      _categorySubOption(
                        subcategory,
                        selected: _selectedCategory == main &&
                            _selectedSubcategory == subcategory,
                        onTap: () => _chooseCategory(main, subcategory),
                      ),
                  ],
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _categorySubOption(
    String title, {
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 10, 16, 10),
        child: Row(
          children: [
            Expanded(
              child: Text(title, style: const TextStyle(fontSize: 13)),
            ),
            if (selected)
              const Icon(Icons.check, size: 18, color: Color(0xFF22683D)),
          ],
        ),
      ),
    );
  }

  Widget _buildAssetCard(
    Map<String, dynamic> asset, {
    required int displayNumber,
  }) {
    final retired = asset['status'] == 'Retired';
    final subcategory = _display(asset['subcategory']);
    final brand = _display(asset['brand_model']);
    final capacity = _display(asset['capacity_rating']);
    final remarks = _display(asset['remarks']);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
        boxShadow: [
          BoxShadow(
            color: AppColors.black.withValues(alpha: 0.035),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 46,
                  height: 46,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppColors.red.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '$displayNumber',
                    style: const TextStyle(
                      color: AppColors.red,
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        asset['asset_item']?.toString() ?? 'Unnamed asset',
                        style: const TextStyle(
                          color: AppColors.black,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Asset ID: ${asset['asset_id'] ?? 'Not set'}',
                        style: const TextStyle(
                          color: AppColors.grey,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        '${_display(asset['category'], fallback: 'Uncategorised')}'
                        '${subcategory == null ? '' : '  •  $subcategory'}'
                        '  •  '
                        '${_display(asset['location'], fallback: '-')}',
                        style: const TextStyle(
                          color: AppColors.grey,
                          fontSize: 12,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _statusBadge(retired),
              ],
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Wrap(
                spacing: 24,
                runSpacing: 12,
                children: [
                  _assetDetail('QUANTITY', '${asset['qty'] ?? 0}'),
                  if (brand != null)
                    _assetDetail('BRAND / MODEL', brand),
                  if (capacity != null)
                    _assetDetail('CAPACITY / RATING', capacity),
                ],
              ),
            ),
            if (remarks != null) ...[
              const SizedBox(height: 12),
              _assetDetail('REMARKS', remarks),
            ],
            if (!_readOnly) ...[
              const Divider(height: 28),
              Align(
                alignment: Alignment.centerRight,
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                  TextButton.icon(
                    onPressed: _saving ? null : () => _editAsset(asset),
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('Edit', style: TextStyle(fontWeight: FontWeight.normal)),
                    style: TextButton.styleFrom(foregroundColor: AppColors.red),
                  ),
                  TextButton.icon(
                    onPressed: _saving
                        ? null
                        : () => _setRetired(asset, !retired),
                    icon: Icon(
                      retired
                          ? Icons.settings_backup_restore
                          : Icons.archive_outlined,
                      size: 18,
                    ),
                    label: Text(retired ? 'Reactivate' : 'Retire'),
                    style: TextButton.styleFrom(foregroundColor: AppColors.red),
                  ),
                  TextButton.icon(
                    onPressed: _saving ? null : () => _deleteAsset(asset),
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.red,
                    ),
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('Delete'),
                  ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _statusBadge(bool retired) {
    final color = retired ? AppColors.grey : const Color(0xFF22683D);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        retired ? 'Retired' : 'Active',
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _assetDetail(String label, String value) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 75, maxWidth: 300),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: AppColors.grey,
              fontSize: 10,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            value,
            style: const TextStyle(
              color: AppColors.black,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return _emptyPanel(
      icon: Icons.inventory_2_outlined,
      title: 'No assets registered yet',
      description: _readOnly
          ? 'This report is completed and the asset register is read-only.'
          : 'Register the first asset for this property using the Add Asset button.',
    );
  }

  Widget _buildNoMatches() {
    return _emptyPanel(
      icon: Icons.search_off_outlined,
      title: 'No matching assets',
      description: 'Try another search term or change the status or category filter.',
      action: TextButton(
        onPressed: () {
          _searchController.clear();
          setState(() {
            _selectedStatuses.clear();
            _selectedCategory = null;
            _selectedSubcategory = null;
            _categoryMenuOpen = false;
            _expandedCategory = null;
          });
        },
        child: const Text('Clear filters'),
      ),
    );
  }

  Widget _emptyPanel({
    required IconData icon,
    required String title,
    required String description,
    Widget? action,
  }) {
    return Container(
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          Icon(icon, size: 44, color: AppColors.red),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppColors.black,
              fontSize: 17,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            description,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppColors.grey,
              height: 1.5,
            ),
          ),
          if (action != null) ...[
            const SizedBox(height: 8),
            action,
          ],
        ],
      ),
    );
  }

  String? _display(dynamic value, {String? fallback}) {
    if (value == null || value.toString().trim().isEmpty) {
      return fallback;
    }

    return value.toString().trim();
  }
}