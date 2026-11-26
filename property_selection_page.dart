import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'property_sites_service.dart';
import 'profile_page.dart';
import 'widgets/styles.dart';
import 'widgets/app_common_app_bar.dart';

class PropertySelectionPage extends StatefulWidget {
  final void Function(
    BuildContext context,
    Map<String, dynamic> site,
    String accessToken,
  ) onSiteOpened;

  const PropertySelectionPage({
    super.key,
    required this.onSiteOpened,
  });

  @override
  State<PropertySelectionPage> createState() => _PropertySelectionPageState();
}

class _PropertySelectionPageState extends State<PropertySelectionPage> {
  final TextEditingController _searchController = TextEditingController();
  final ImagePicker _imagePicker = ImagePicker();

  StreamSubscription<AuthState>? _authSubscription;

  List<Map<String, dynamic>> _sites = [];
  String _searchQuery = '';
  bool _loading = true;
  bool _loadInFlight = false;
  String? _loadError;
  String? _profileImageUrl;

  String? _viewerRole;
  String? _loadedUserId;
  bool _sessionExpired = false;
  String? _busySiteId;

  bool get _isAdmin => _viewerRole == 'admin';

  static const String _totalUnitsHelp =
      'Enter the total number of units across the entire property, '
      'including residential, commercial, retail, and any other unit types. '
      'Provide the overall total as a whole number.';

  @override
  void initState() {
    super.initState();

    _authSubscription =
        Supabase.instance.client.auth.onAuthStateChange.listen((data) {
      if (!mounted) return;

      if (data.event == AuthChangeEvent.signedOut) {
        setState(() {
          _sites = [];
          _viewerRole = null;
          _loadedUserId = null;
        });
        return;
      }

      if (data.event == AuthChangeEvent.signedIn) {
        final userId = data.session?.user.id;
        if (userId != null && userId != _loadedUserId) {
          _loadSites();
          _loadProfilePicture();
        }
      }
    });

    _loadSites();
    _loadProfilePicture();
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadProfilePicture() async {
    final supabase = Supabase.instance.client;
    final user = supabase.auth.currentUser;

    if (user == null) {
      if (mounted) {
        setState(() => _profileImageUrl = null);
      }
      return;
    }

    try {
      final response = await supabase
          .from('user_profiles')
          .select('avatar_url')
          .eq('id', user.id)
          .maybeSingle();

      final path = response?['avatar_url']?.toString().trim() ?? '';
      String? signedUrl;

      if (path.isNotEmpty) {
        try {
          signedUrl = await supabase.storage
              .from('profile-photos')
              .createSignedUrl(path, 3600);
        } catch (e) {
          debugPrint('Could not load profile picture: $e');
        }
      }

      if (!mounted || supabase.auth.currentUser?.id != user.id) return;

      setState(() {
        _profileImageUrl = signedUrl;
      });
    } catch (e) {
      debugPrint('Could not load profile picture: $e');
    }
  }

  Future<void> _loadSites() async {
    if (!mounted || _loadInFlight) return;

    _loadInFlight = true;

    setState(() {
      _loading = true;
      _loadError = null;
      _sessionExpired = false;
    });

    try {
      final result = await PropertySitesService.listSitesAuthenticated();
      final sites = List<Map<String, dynamic>>.of(result.sites);

      sites.sort((a, b) {
        final dateA = DateTime.tryParse(
              a['created_at']?.toString() ?? '',
            ) ??
            DateTime.fromMillisecondsSinceEpoch(0);

        final dateB = DateTime.tryParse(
              b['created_at']?.toString() ?? '',
            ) ??
            DateTime.fromMillisecondsSinceEpoch(0);

        return dateB.compareTo(dateA);
      });

      if (!mounted) return;

      setState(() {
        _sites = sites;
        _viewerRole = result.viewerRole;
        _loadedUserId = Supabase.instance.client.auth.currentUser?.id;
        _loading = false;
      });
    } on AuthRequiredException catch (e) {
      if (!mounted) return;

      setState(() {
        _sites = [];
        _viewerRole = null;
        _loading = false;
        _sessionExpired = true;
        _loadError = e.message;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _loading = false;
        _loadError = e.toString().replaceFirst('Exception: ', '');
      });
    } finally {
      _loadInFlight = false;
    }
  }

  Future<void> _signInAgain() async {
    try {
      await Supabase.instance.client.auth.signOut();
    } catch (_) {
      // AuthGate handles the authentication state.
    }
  }

  void _handleSessionExpired(String message) {
    if (!mounted) return;

    setState(() {
      _sites = [];
      _viewerRole = null;
      _sessionExpired = true;
      _loadError = message;
    });
  }

  List<Map<String, dynamic>> get _filteredSites {
    final query = _searchQuery.trim().toLowerCase();

    if (query.isEmpty) {
      return _sites;
    }

    return _sites.where((site) {
      final name = site['site_name']?.toString().toLowerCase() ?? '';
      return name.contains(query);
    }).toList();
  }

  InputDecoration _inputDecoration(
    String hint,
    IconData icon, {
    Widget? suffixIcon,
  }) {
    return InputDecoration(
      hintText: hint,
      prefixIcon: Icon(icon, color: AppColors.red),
      suffixIcon: suffixIcon,
      filled: true,
      fillColor: const Color(0xFFF8F8F8),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: 14,
        vertical: 15,
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Color(0xFFE0E0E0)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Color(0xFFE0E0E0)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: AppColors.red, width: 1.5),
      ),
    );
  }

  Widget _fieldLabel(String label, {bool required = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Text(
        required ? '$label *' : label,
        style: const TextStyle(
          color: AppColors.black,
          fontWeight: FontWeight.w700,
          fontSize: 13,
        ),
      ),
    );
  }

  Widget _textField(
    TextEditingController controller,
    String label,
    String hint,
    IconData icon, {
    bool required = false,
    TextInputType keyboardType = TextInputType.text,
    int maxLines = 1,
    int? maxLength,
    List<TextInputFormatter>? inputFormatters,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _fieldLabel(label, required: required),
          TextField(
            controller: controller,
            keyboardType: keyboardType,
            inputFormatters: inputFormatters,
            maxLines: maxLines,
            maxLength: maxLength,
            decoration: _inputDecoration(hint, icon).copyWith(
              counterText: '',
            ),
          ),
        ],
      ),
    );
  }

  Widget _totalUnitsDescription() {
    return const Padding(
      padding: EdgeInsets.only(bottom: 16),
      child: Text(
        _totalUnitsHelp,
        style: TextStyle(
          color: AppColors.grey,
          fontSize: 12,
          height: 1.5,
        ),
      ),
    );
  }

  Widget _sectionHeader(String number, String title, String subtitle) {
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 18),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.red,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Text(
              number,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: AppColors.black,
                    fontWeight: FontWeight.w900,
                    fontSize: 17,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: AppColors.grey,
                    fontSize: 12,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // CREATE PROPERTY
  //
  // Only the picture, site name and total units are collected here.
  // Address, rates, billing and committee details now live in the Site Profile
  // section of each property's monthly report (see site_profile_page.dart).
  // ---------------------------------------------------------------------------

  Future<void> _showCreatePropertyDialog() async {
    if (!_isAdmin) return;

    final siteName = TextEditingController();
    final totalUnits = TextEditingController();

    Uint8List? selectedImage;
    String? selectedImageType;
    String? createdSiteId;

    bool saving = false;
    String? errorMessage;

    final created = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, dialogSetState) {
            Future<void> choosePicture() async {
              try {
                final XFile? image = await _imagePicker.pickImage(
                  source: ImageSource.gallery,
                  imageQuality: 85,
                );

                if (image == null || !dialogContext.mounted) return;

                final bytes = await image.readAsBytes();

                if (bytes.isEmpty || bytes.length > 5 * 1024 * 1024) {
                  dialogSetState(() {
                    errorMessage =
                        'Please choose a non-empty image smaller than 5 MB.';
                  });
                  return;
                }

                final filename = image.name.toLowerCase();

                final String? contentType = filename.endsWith('.png')
                    ? 'image/png'
                    : filename.endsWith('.webp')
                        ? 'image/webp'
                        : filename.endsWith('.jpg') ||
                                filename.endsWith('.jpeg')
                            ? 'image/jpeg'
                            : null;

                if (contentType == null) {
                  dialogSetState(() {
                    errorMessage =
                        'Please choose a JPEG, PNG, or WebP image.';
                  });
                  return;
                }

                dialogSetState(() {
                  selectedImage = bytes;
                  selectedImageType = contentType;
                  errorMessage = null;
                });
              } catch (e) {
                if (!dialogContext.mounted) return;

                dialogSetState(() {
                  errorMessage =
                      'Could not select the picture: '
                      '${e.toString().replaceFirst('Exception: ', '')}';
                });
              }
            }

            return AlertDialog(
              backgroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
              contentPadding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
              title: const Text(
                'Create New Property',
                style: TextStyle(
                  color: AppColors.black,
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                ),
              ),
              content: SizedBox(
                width: 540,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Enter the property name and total units. Address, '
                        'billing rates and committee members are added later '
                        'in the Site Profile section of a monthly report.',
                        style: TextStyle(
                          color: AppColors.grey,
                          height: 1.5,
                          fontSize: 13,
                        ),
                      ),

                      const SizedBox(height: 20),
                      _sectionHeader(
                        '0',
                        'Property Picture',
                        'Choose an optional cover picture for this property.',
                      ),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF8F8F8),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: const Color(0xFFE0E0E0),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (selectedImage != null)
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.memory(
                                  selectedImage!,
                                  width: double.infinity,
                                  height: 170,
                                  fit: BoxFit.cover,
                                ),
                              )
                            else
                              Container(
                                width: double.infinity,
                                height: 120,
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: const Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      Icons.add_photo_alternate_outlined,
                                      size: 36,
                                      color: AppColors.grey,
                                    ),
                                    SizedBox(height: 8),
                                    Text(
                                      'No picture selected',
                                      style: TextStyle(
                                        color: AppColors.grey,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                Expanded(
                                  child: OutlinedButton.icon(
                                    onPressed: saving ? null : choosePicture,
                                    icon: const Icon(
                                      Icons.photo_library_outlined,
                                    ),
                                    label: Text(
                                      selectedImage == null
                                          ? 'Choose Picture'
                                          : 'Change Picture',
                                    ),
                                  ),
                                ),
                                if (selectedImage != null) ...[
                                  const SizedBox(width: 8),
                                  IconButton(
                                    tooltip: 'Remove selected picture',
                                    onPressed: saving
                                        ? null
                                        : () {
                                            dialogSetState(() {
                                              selectedImage = null;
                                              selectedImageType = null;
                                              errorMessage = null;
                                            });
                                          },
                                    icon: const Icon(
                                      Icons.delete_outline,
                                      color: Colors.red,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            const Text(
                              'Optional. JPEG, PNG, or WebP. Maximum 5 MB.',
                              style: TextStyle(
                                color: AppColors.grey,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),

                      _sectionHeader(
                        '1',
                        'Property',
                        'The name and overall unit count of this property.',
                      ),
                      _textField(
                        siteName,
                        'Site Name',
                        'e.g. Quadro Residences KLCC',
                        Icons.apartment_outlined,
                        required: true,
                        maxLength: 150,
                      ),
                      _textField(
                        totalUnits,
                        'Total Units',
                        'Enter the overall number of units',
                        Icons.domain_outlined,
                        required: true,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                      ),
                      _totalUnitsDescription(),

                      if (errorMessage != null) ...[
                        const SizedBox(height: 4),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFFEEEE),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            errorMessage!,
                            style: const TextStyle(
                              color: Colors.red,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              actions: [
                TextButton(
                  onPressed: saving
                      ? null
                      : () => Navigator.pop(dialogContext, false),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.red,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 13,
                    ),
                  ),
                  onPressed: saving
                      ? null
                      : () async {
                          if (createdSiteId != null) {
                            if (selectedImage == null ||
                                selectedImageType == null) {
                              dialogSetState(() {
                                errorMessage =
                                    'The property already exists. '
                                    'Choose a picture to retry its upload, '
                                    'or cancel and refresh the property list.';
                              });
                              return;
                            }

                            dialogSetState(() {
                              saving = true;
                              errorMessage = null;
                            });

                            try {
                              await PropertySitesService
                                  .uploadSiteImageAuthenticated(
                                siteId: createdSiteId!,
                                imageBytes: selectedImage!,
                                contentType: selectedImageType!,
                              );

                              if (dialogContext.mounted) {
                                Navigator.pop(dialogContext, true);
                              }
                            } catch (e) {
                              dialogSetState(() {
                                saving = false;
                                errorMessage =
                                    'Property created, but picture upload '
                                    'failed: ${e.toString().replaceFirst('Exception: ', '')}';
                              });
                            }
                            return;
                          }

                          final name = siteName.text.trim();
                          final parsedTotalUnits =
                              int.tryParse(totalUnits.text.trim());

                          if (name.isEmpty) {
                            dialogSetState(() {
                              errorMessage = 'Site Name is required.';
                            });
                            return;
                          }

                          if (parsedTotalUnits == null ||
                              parsedTotalUnits <= 0) {
                            dialogSetState(() {
                              errorMessage =
                                  'Total Units must be a whole number '
                                  'greater than zero.';
                            });
                            return;
                          }

                          dialogSetState(() {
                            saving = true;
                            errorMessage = null;
                          });

                          try {
                            final response = await PropertySitesService
                                .createSiteAuthenticated(
                              siteName: name,
                              totalUnits: parsedTotalUnits,
                            );

                            final siteData = response['site'] is Map
                                ? Map<String, dynamic>.from(
                                    response['site'] as Map,
                                  )
                                : response;

                            final id = siteData['id']?.toString();

                            if (id == null || id.isEmpty) {
                              throw Exception(
                                'Property creation response did not '
                                'include its ID.',
                              );
                            }

                            createdSiteId = id;

                            if (selectedImage != null &&
                                selectedImageType != null) {
                              await PropertySitesService
                                  .uploadSiteImageAuthenticated(
                                siteId: createdSiteId!,
                                imageBytes: selectedImage!,
                                contentType: selectedImageType!,
                              );
                            }

                            if (dialogContext.mounted) {
                              Navigator.pop(dialogContext, true);
                            }
                          } catch (e) {
                            dialogSetState(() {
                              saving = false;
                              errorMessage = createdSiteId != null
                                  ? 'Property created, but the picture '
                                      'could not be uploaded. You can retry '
                                      'the picture upload without creating '
                                      'another property. Details: '
                                      '${e.toString().replaceFirst('Exception: ', '')}'
                                  : e.toString().replaceFirst(
                                      'Exception: ',
                                      '',
                                    );
                            });
                          }
                        },
                  child: saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Text(
                          createdSiteId != null
                              ? 'Retry Picture Upload'
                              : 'Create Property',
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                ),
              ],
            );
          },
        );
      },
    );

    siteName.dispose();
    totalUnits.dispose();

    final propertyExists = created == true || createdSiteId != null;

    if (propertyExists && mounted) {
      await _loadSites();

      if (!mounted) return;

      final pictureUploaded = created == true && selectedImage != null;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            created == true
                ? (pictureUploaded
                    ? 'Property created successfully with picture.'
                    : 'Property created successfully.')
                : 'Property created, but its picture was not uploaded. '
                    'Use Edit to add the picture.',
          ),
          backgroundColor: created == true ? Colors.green : Colors.orange,
        ),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // OPEN PROPERTY
  // ---------------------------------------------------------------------------

  Future<void> _openSite(Map<String, dynamic> site) async {
    final siteId = site['id']?.toString() ?? '';
    if (siteId.isEmpty || _busySiteId != null) return;

    setState(() => _busySiteId = siteId);

    String? accessToken;

    try {
      accessToken = await PropertySitesService.openSiteAuthenticated(
        siteId: siteId,
      );
    } on AuthRequiredException catch (e) {
      _handleSessionExpired(e.message);
    } on PropertyAccessDeniedException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message)),
        );
        _loadSites();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.toString().replaceFirst('Exception: ', '')),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busySiteId = null);
    }

    if (accessToken == null || !mounted) return;

    widget.onSiteOpened(context, site, accessToken);
  }

  // ---------------------------------------------------------------------------
  // EDIT PROPERTY
  //
  // Only the site name and picture are edited here. The saved site
  // information, committee and total units are loaded and sent back unchanged
  // so that this dialog never overwrites what is maintained in Site Profile.
  // ---------------------------------------------------------------------------

  Future<void> _editSite(Map<String, dynamic> site) async {
    if (!_isAdmin) return;

    final siteId = site['id']?.toString() ?? '';
    if (siteId.isEmpty || _busySiteId != null) return;

    setState(() => _busySiteId = siteId);

    Map<String, dynamic> details;

    try {
      details = await PropertySitesService.getSiteAuthenticated(
        siteId: siteId,
      );
    } on AuthRequiredException catch (e) {
      _handleSessionExpired(e.message);
      if (mounted) setState(() => _busySiteId = null);
      return;
    } catch (e) {
      if (mounted) {
        setState(() => _busySiteId = null);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.toString().replaceFirst('Exception: ', '')),
          ),
        );
      }
      return;
    }

    if (!mounted) return;

    setState(() => _busySiteId = null);

    // Everything below is preserved exactly as saved.
    final existingInfo = Map<String, dynamic>.from(
      details['site_information'] is Map
          ? details['site_information'] as Map
          : <String, dynamic>{},
    );

    final existingTotalUnits = int.tryParse(
      (details['total_units'] ?? existingInfo['total_units'] ?? '')
          .toString(),
    );

    final preservedInfo = <String, dynamic>{...existingInfo}
      ..remove('total_units');

    final preservedCommittee = <Map<String, dynamic>>[
      if (details['management_committee'] is List)
        for (final member in details['management_committee'] as List)
          if (member is Map) Map<String, dynamic>.from(member),
    ];

    final nameController = TextEditingController(
      text: details['site_name']?.toString() ?? '',
    );

    Uint8List? replacementImage;
    String? replacementContentType;
    bool removeCurrentImage = false;
    bool saving = false;
    String? saveError;

    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          Future<void> chooseImage() async {
            try {
              final picked = await _imagePicker.pickImage(
                source: ImageSource.gallery,
                imageQuality: 85,
              );

              if (picked == null) return;

              final bytes = await picked.readAsBytes();
              final fileName = picked.name.toLowerCase();

              String? type;
              if (fileName.endsWith('.jpg') ||
                  fileName.endsWith('.jpeg')) {
                type = 'image/jpeg';
              } else if (fileName.endsWith('.png')) {
                type = 'image/png';
              } else if (fileName.endsWith('.webp')) {
                type = 'image/webp';
              }

              if (bytes.isEmpty ||
                  bytes.length > 5 * 1024 * 1024 ||
                  type == null) {
                if (!dialogContext.mounted) return;
                setDialogState(() {
                  saveError =
                      'Choose a valid JPEG, PNG, or WebP image under 5 MB.';
                });
                return;
              }

              if (!dialogContext.mounted) return;

              setDialogState(() {
                replacementImage = bytes;
                replacementContentType = type;
                removeCurrentImage = false;
                saveError = null;
              });
            } catch (e) {
              if (!dialogContext.mounted) return;

              setDialogState(() {
                saveError =
                    'Could not select the picture: '
                    '${e.toString().replaceFirst('Exception: ', '')}';
              });
            }
          }

          final currentImageUrl = details['image_url']?.toString() ?? '';

          return AlertDialog(
            backgroundColor: Colors.white,
            title: const Text(
              'Edit Property',
              style: TextStyle(
                fontWeight: FontWeight.w900,
                color: AppColors.black,
              ),
            ),
            content: SizedBox(
              width: 560,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _sectionHeader(
                      '1',
                      'Property',
                      'Update the property name. Address, rates, units and '
                          'committee are edited in the Site Profile section '
                          'of a monthly report.',
                    ),
                    _textField(
                      nameController,
                      'Site Name',
                      'Property name',
                      Icons.apartment_outlined,
                      required: true,
                      maxLength: 150,
                    ),
                    const Divider(height: 30),
                    _sectionHeader(
                      '2',
                      'Property Picture',
                      'Choose a replacement or remove the existing image.',
                    ),
                    if (replacementImage != null)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Image.memory(
                          replacementImage!,
                          height: 150,
                          width: double.infinity,
                          fit: BoxFit.cover,
                        ),
                      )
                    else if (currentImageUrl.isNotEmpty &&
                        !removeCurrentImage)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Image.network(
                          currentImageUrl,
                          height: 150,
                          width: double.infinity,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => const SizedBox(
                            height: 70,
                            child: Center(
                              child: Text('Current picture unavailable'),
                            ),
                          ),
                        ),
                      )
                    else
                      const Text('No property picture selected.'),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed: saving ? null : chooseImage,
                          icon: const Icon(Icons.photo_library_outlined),
                          label: const Text('Choose Picture'),
                        ),
                        if (currentImageUrl.isNotEmpty ||
                            replacementImage != null)
                          TextButton.icon(
                            onPressed: saving
                                ? null
                                : () => setDialogState(() {
                                      replacementImage = null;
                                      replacementContentType = null;
                                      removeCurrentImage = true;
                                    }),
                            icon: const Icon(
                              Icons.delete_outline,
                              color: Colors.red,
                            ),
                            label: const Text(
                              'Remove Picture',
                              style: TextStyle(color: Colors.red),
                            ),
                          ),
                      ],
                    ),
                    if (saveError != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        saveError!,
                        style: const TextStyle(color: Colors.red),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: saving
                    ? null
                    : () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.red,
                  foregroundColor: Colors.white,
                ),
                onPressed: saving
                    ? null
                    : () async {
                        if (nameController.text.trim().isEmpty) {
                          setDialogState(
                            () => saveError = 'Site Name is required.',
                          );
                          return;
                        }

                        if (existingTotalUnits == null ||
                            existingTotalUnits <= 0) {
                          setDialogState(() {
                            saveError =
                                'This property has no saved total units. '
                                'Open a monthly report, go to Site Profile '
                                'and enter the total units first.';
                          });
                          return;
                        }

                        setDialogState(() {
                          saving = true;
                          saveError = null;
                        });

                        try {
                          await PropertySitesService.updateSiteAuthenticated(
                            siteId: siteId,
                            siteName: nameController.text.trim(),
                            totalUnits: existingTotalUnits,
                            siteInformation: preservedInfo,
                            managementCommittee: preservedCommittee,
                          );

                          if (replacementImage != null) {
                            await PropertySitesService
                                .uploadSiteImageAuthenticated(
                              siteId: siteId,
                              imageBytes: replacementImage!,
                              contentType: replacementContentType!,
                            );
                          } else if (removeCurrentImage) {
                            await PropertySitesService
                                .removeSiteImageAuthenticated(
                              siteId: siteId,
                            );
                          }

                          if (dialogContext.mounted) {
                            Navigator.pop(dialogContext, true);
                          }
                        } catch (e) {
                          setDialogState(() {
                            saving = false;
                            saveError = e.toString().replaceFirst(
                              'Exception: ',
                              '',
                            );
                          });
                        }
                      },
                child: saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text('Save Changes'),
              ),
            ],
          );
        },
      ),
    );

    nameController.dispose();

    if (saved == true && mounted) {
      await _loadSites();

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Property updated successfully.'),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // DELETE PROPERTY
  // ---------------------------------------------------------------------------

  Future<void> _confirmDeleteSite(Map<String, dynamic> site) async {
    if (!_isAdmin || _busySiteId != null) return;

    final siteId = site['id']?.toString() ?? '';
    if (siteId.isEmpty) return;

    final name = site['site_name']?.toString() ?? 'Unnamed Property';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        title: const Text(
          'Delete Property?',
          style: TextStyle(
            color: AppColors.black,
            fontWeight: FontWeight.w900,
          ),
        ),
        content: Text(
          'Are you sure you want to permanently delete "$name"?\n\n'
          'Properties with existing monthly reports cannot be deleted. '
          'Other linked records may also be affected or prevent deletion. '
          'This action cannot be undone.',
          style: const TextStyle(height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton.icon(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            icon: const Icon(Icons.delete_outline, size: 18),
            label: const Text('Delete Property'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.red,
              foregroundColor: Colors.white,
            ),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted || _busySiteId != null) return;

    setState(() => _busySiteId = siteId);

    try {
      await PropertySitesService.deleteSiteAuthenticated(siteId: siteId);

      if (!mounted) return;
      await _loadSites();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Property deleted successfully.'),
          backgroundColor: Colors.green,
        ),
      );
    } on AuthRequiredException catch (e) {
      _handleSessionExpired(e.message);
    } on PropertyAccessDeniedException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Could not delete property: '
              '${e.toString().replaceFirst('Exception: ', '')}',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busySiteId = null);
    }
  }

  String _formatDate(dynamic value) {
    final date = DateTime.tryParse(value?.toString() ?? '');
    if (date == null) return 'Date unavailable';

    final local = date.toLocal();

    return '${local.day.toString().padLeft(2, '0')}/'
        '${local.month.toString().padLeft(2, '0')}/'
        '${local.year}';
  }

  @override
  Widget build(BuildContext context) {
    final isSearching = _searchQuery.trim().isNotEmpty;
    final sites = _filteredSites;
    final propertyCountLabel = sites.length == 1
        ? '1 PROPERTY'
        : '${sites.length} PROPERTIES';

    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppCommonAppBar(
        title: 'Properties',
        onRefresh: _loadSites,
        profileImageUrl: _profileImageUrl,
        onProfile: () async {
          await Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => const ProfilePage(),
            ),
          );
          if (mounted) {
            await _loadProfilePicture();
          }
        },
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1600),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const SizedBox(height: 12),
              const Text(
                'PROPERTY\nMANAGEMENT',
                style: TextStyle(
                  color: AppColors.black,
                  fontSize: 13,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 2.2,
                ),
              ),
              const SizedBox(height: 12),
              LayoutBuilder(
                builder: (context, constraints) {
                  final heading = Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Select a Property',
                        style: TextStyle(
                          color: AppColors.black,
                          fontSize: 34,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -1,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        _isAdmin
                            ? 'Choose an existing site or set up a new property '
                                'to manage its monthly reports.'
                            : 'Choose one of your assigned properties to manage '
                                'its monthly reports.',
                        style: const TextStyle(
                          color: AppColors.grey,
                          fontSize: 15,
                          height: 1.6,
                        ),
                      ),
                    ],
                  );

                  final addButton = ElevatedButton.icon(
                    onPressed: _showCreatePropertyDialog,
                    icon: const Icon(Icons.add, size: 20),
                    label: const Text('Add Property'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.red,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 16,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  );

                  if (constraints.maxWidth < 700) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        heading,
                        if (_isAdmin) ...[
                          const SizedBox(height: 16),
                          addButton,
                        ],
                      ],
                    );
                  }

                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(child: heading),
                      if (_isAdmin) ...[
                        const SizedBox(width: 24),
                        addButton,
                      ],
                    ],
                  );
                },
              ),
              const SizedBox(height: 30),

              TextField(
                controller: _searchController,
                onChanged: (value) {
                  setState(() => _searchQuery = value);
                },
                decoration: InputDecoration(
                  hintText: 'Search property or site name',
                  prefixIcon: const Icon(
                    Icons.search,
                    color: AppColors.red,
                  ),
                  suffixIcon: _searchQuery.isNotEmpty
                      ? IconButton(
                          tooltip: 'Clear search',
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _searchQuery = '');
                          },
                          icon: const Icon(Icons.close),
                        )
                      : null,
                  filled: true,
                  fillColor: Colors.white,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: Color(0xFFE0E0E0)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: Color(0xFFE0E0E0)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(
                      color: AppColors.red,
                      width: 1.5,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 32),

              Row(
                children: [
                  Container(width: 4, height: 22, color: AppColors.red),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      isSearching ? 'SEARCH RESULTS' : 'ALL PROPERTIES',
                      style: const TextStyle(
                        color: AppColors.black,
                        fontSize: 13,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.5,
                      ),
                    ),
                  ),
                  if (_loading)
                    const SizedBox(
                      width: 15,
                      height: 15,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    Text(
                      propertyCountLabel,
                      style: const TextStyle(
                        color: AppColors.grey,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),

              if (_loading && _sites.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_sessionExpired)
                _emptyState(
                  icon: Icons.lock_clock_outlined,
                  title: 'Session expired',
                  message: _loadError ??
                      'Your session has expired. Please sign in again.',
                  actionLabel: 'Sign In Again',
                  onAction: _signInAgain,
                )
              else if (_loadError != null && _sites.isEmpty)
                _emptyState(
                  icon: Icons.cloud_off_outlined,
                  title: 'Could not load properties',
                  message: _loadError!,
                  actionLabel: 'Try Again',
                  onAction: _loadSites,
                )
              else if (sites.isEmpty)
                _emptyState(
                  icon: isSearching
                      ? Icons.search_off_outlined
                      : Icons.apartment_outlined,
                  title: isSearching
                      ? 'No matching properties'
                      : _isAdmin
                          ? 'No properties yet'
                          : 'No properties assigned',
                  message: isSearching
                      ? 'Try another property or site name.'
                      : _isAdmin
                          ? 'Create your first property to get started.'
                          : 'Your account has no property assignments yet. '
                              'Ask an administrator to assign you to a '
                              'property, then refresh this page.',
                  actionLabel: !isSearching && !_isAdmin ? 'Refresh' : null,
                  onAction: !isSearching && !_isAdmin ? _loadSites : null,
                )
              else
                LayoutBuilder(
                  builder: (context, constraints) {
                    final width = constraints.maxWidth;
                    final columns = width >= 1050
                        ? 3
                        : width >= 650
                            ? 2
                            : 1;

                    return GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: sites.length,
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        crossAxisSpacing: 18,
                        mainAxisSpacing: 18,
                        mainAxisExtent: 342,
                      ),
                      itemBuilder: (context, index) => _siteCard(sites[index]),
                    );
                  },
                ),

              const SizedBox(height: 28),
              const Center(
                child: Text(
                  'APEX CHOICE  •  PROPERTY REPORTING',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppColors.grey,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.1,
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }

  Widget _siteCard(Map<String, dynamic> site) {
    final name = site['site_name']?.toString() ?? 'Unnamed Property';
    final imageUrl = site['image_url']?.toString() ?? '';
    final siteId = site['id']?.toString() ?? '';
    final isBusy = _busySiteId != null && _busySiteId == siteId;
    final anyBusy = _busySiteId != null;

    final fallbackImage = Container(
      color: const Color(0xFFE8EDF2),
      alignment: Alignment.center,
      child: const Icon(
        Icons.apartment_outlined,
        size: 64,
        color: Color(0xFF83909D),
      ),
    );

    return Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: Color(0xFFE2E2E2)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: anyBusy ? null : () => _openSite(site),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 180,
              child: imageUrl.isNotEmpty
                  ? Image.network(
                      imageUrl,
                      width: double.infinity,
                      height: 180,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => fallbackImage,
                    )
                  : fallbackImage,
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.black,
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Created ${_formatDate(site['created_at'])}',
                      style: const TextStyle(
                        color: AppColors.grey,
                        fontSize: 12,
                      ),
                    ),
                    const Spacer(),
                    const Divider(height: 1, color: Color(0xFFEAEAEA)),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        const Text(
                          'Open Property',
                          style: TextStyle(
                            color: AppColors.red,
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const Spacer(),
                        if (_isAdmin)
                          IconButton(
                            tooltip: 'Edit property',
                            onPressed: anyBusy ? null : () => _editSite(site),
                            icon: const Icon(
                              Icons.edit_outlined,
                              color: AppColors.red,
                              size: 20,
                            ),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 36,
                              minHeight: 36,
                            ),
                          ),
                        if (_isAdmin)
                          IconButton(
                            tooltip: 'Delete property',
                            onPressed:
                                anyBusy ? null : () => _confirmDeleteSite(site),
                            icon: const Icon(
                              Icons.delete_outline,
                              color: AppColors.red,
                              size: 20,
                            ),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 36,
                              minHeight: 36,
                            ),
                          ),
                        const SizedBox(width: 8),
                        if (isBusy)
                          const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        else
                          const Icon(
                            Icons.arrow_forward,
                            color: AppColors.red,
                            size: 21,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _emptyState({
    required IconData icon,
    required String title,
    required String message,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 36),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE5E5E5)),
      ),
      child: Column(
        children: [
          Icon(icon, size: 44, color: AppColors.red),
          const SizedBox(height: 14),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppColors.black,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppColors.grey,
              height: 1.5,
            ),
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: onAction,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.red,
                foregroundColor: Colors.white,
              ),
              child: Text(actionLabel),
            ),
          ],
        ],
      ),
    );
  }
}