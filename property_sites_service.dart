import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

/// Thrown when there is no valid Supabase Auth session (missing, expired and
/// unrefreshable, or rejected by the server with 401).
class AuthRequiredException implements Exception {
  final String message;

  const AuthRequiredException([
    this.message = 'Your session has expired. Please sign in again.',
  ]);

  @override
  String toString() => message;
}

/// Thrown when the server rejects an authenticated request with 403.
class PropertyAccessDeniedException implements Exception {
  final String message;

  const PropertyAccessDeniedException([
    this.message = 'You do not have permission to perform this action.',
  ]);

  @override
  String toString() => message;
}

/// Result of the authenticated property listing.
class AuthenticatedSiteList {
  /// Role as determined by the BACKEND from the verified JWT
  /// ('admin' or 'staff'). Used for UI display only.
  final String? viewerRole;
  final List<Map<String, dynamic>> sites;

  const AuthenticatedSiteList({required this.viewerRole, required this.sites});
}

/// Site Profile permissions returned by the authenticated backend.
/// Every permission is specific to the selected property.
class SiteProfilePermissions {
  final bool canView;
  final bool canAdd;
  final bool canEdit;
  final bool canDelete;

  const SiteProfilePermissions({
    required this.canView,
    required this.canAdd,
    required this.canEdit,
    required this.canDelete,
  });

  bool get canSave => canAdd || canEdit || canDelete;

  factory SiteProfilePermissions.fromMap(Map<String, dynamic> value) {
    return SiteProfilePermissions(
      canView: value['can_view_site_profile'] == true,
      canAdd: value['can_add_site_profile'] == true,
      canEdit: value['can_edit_site_profile'] == true,
      canDelete: value['can_delete_site_profile'] == true,
    );
  }
}

class AuthenticatedSiteProfile {
  final Map<String, dynamic> site;
  final SiteProfilePermissions permissions;

  const AuthenticatedSiteProfile({
    required this.site,
    required this.permissions,
  });
}

class PropertySitesService {
  static const String _functionName = 'property-sites';

  // Committee history is monthly. Always send the first day of the month.
  static String _firstOfMonth(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-01';

  static List<Map<String, dynamic>> _committeeRows(
    Map<String, dynamic> response,
  ) {
    final rows = response['members'];
    if (rows is! List) {
      throw Exception('Invalid committee history returned by server.');
    }
    return rows
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList();
  }

  // ---------------------------------------------------------------------------
  // AUTHENTICATED (Supabase Auth JWT) METHODS
  //
  // These call authenticated Edge Function actions.
  // The user ID is never sent from the client; the backend must read it from
  // the verified JWT.
  // ---------------------------------------------------------------------------

  /// Action: `list_my_sites`
  /// Backend: admin -> all properties; staff -> only properties assigned to
  /// the JWT's user.
  /// Response: { "viewer_role": "admin"|"staff", "sites": [...] }
  static Future<AuthenticatedSiteList> listSitesAuthenticated() async {
    final response = await _request({
      'action': 'list_my_sites',
    }, userJwt: await _currentJwt());

    final sites = response['sites'];

    if (sites is! List) {
      throw Exception('Invalid property list returned by server.');
    }

    return AuthenticatedSiteList(
      viewerRole: response['viewer_role']?.toString(),
      sites: sites
          .whereType<Map>()
          .map((site) => Map<String, dynamic>.from(site))
          .toList(),
    );
  }

  /// Action: `open_site_authenticated`
  /// Backend: verify JWT, active profile, admin OR staff assigned to
  /// `site_id`, then return { "access_token": "site token" } of the same
  /// kind the legacy `authorize` action returns, so existing report screens
  /// keep working. No passcode involved.
  static Future<String> openSiteAuthenticated({required String siteId}) async {
    final response = await _request({
      'action': 'open_site_authenticated',
      'site_id': siteId,
    }, userJwt: await _currentJwt());

    final token = response['access_token'];

    if (token is! String || token.isEmpty) {
      throw Exception('The server did not return a site access token.');
    }

    return token;
  }

  /// Action: `get_site_authenticated` (Admin or assigned Staff with View).
  /// Returns both the property data and server-authoritative permissions.
  /// This method is for the Site Profile page; Admin-only property management
  /// methods below stay unchanged for other call sites.
  static Future<AuthenticatedSiteProfile> getSiteProfileAuthenticated({
    required String siteId,
  }) async {
    final response = await _request({
      'action': 'get_site_authenticated',
      'site_id': siteId,
    }, userJwt: await _currentJwt());

    final site = response['site'];
    final permissions = response['permissions'];
    if (site is! Map || permissions is! Map) {
      throw Exception('Invalid authenticated Site Profile returned by server.');
    }

    return AuthenticatedSiteProfile(
      site: Map<String, dynamic>.from(site),
      permissions: SiteProfilePermissions.fromMap(
        Map<String, dynamic>.from(permissions),
      ),
    );
  }

  /// Action: `update_site_authenticated` (server checks each Site Profile
  /// permission separately for the assigned Staff/property pair).
  /// Admins continue to have full Site Profile access.
  static Future<Map<String, dynamic>> updateSiteProfileAuthenticated({
    required String siteId,
    required String siteName,
    required int totalUnits,
    required Map<String, dynamic> siteInformation,
    required List<Map<String, dynamic>> managementCommittee,
  }) async {
    if (totalUnits <= 0) {
      throw ArgumentError.value(
        totalUnits,
        'totalUnits',
        'Must be a whole number greater than zero.',
      );
    }

    final response = await _request({
      'action': 'update_site_authenticated',
      'site_id': siteId,
      'site_name': siteName,
      'total_units': totalUnits,
      'site_information': siteInformation,
      'management_committee': managementCommittee,
      // Membership updates are separate. Saving the profile must not
      // reintroduce deleted names from an out-of-date legacy JSON snapshot.
      'preserve_committee_history': true,
    }, userJwt: await _currentJwt());

    final site = response['site'];
    if (site is! Map) {
      throw Exception('Invalid updated Site Profile returned by server.');
    }
    return Map<String, dynamic>.from(site);
  }

  // ---------------------------------------------------------------------------
  // DATED MANAGEMENT COMMITTEE
  // These actions are backed by site_committee_membership_history and must
  // not be replaced by changes to property_sites.management_committee JSON.
  // ---------------------------------------------------------------------------

  /// Loads all versions, including removed and upcoming memberships.
  /// Requires Site Profile View permission for this property.
  static Future<List<Map<String, dynamic>>> getCommitteeHistoryAuthenticated({
    required String siteId,
  }) async {
    final response = await _request({
      'action': 'get_committee_history_authenticated',
      'site_id': siteId,
    }, userJwt: await _currentJwt());
    return _committeeRows(response);
  }

  /// Return only members applicable to a selected monthly report.
  /// The Edge Function validates the report's property and the user's access.
  /// Used by the PDF in the next integration step.
  static Future<List<Map<String, dynamic>>> getCommitteeForReportAuthenticated({
    required String reportId,
    String? siteId,
  }) async {
    final response = await _request({
      'action': 'get_committee_for_report_authenticated',
      'report_id': reportId,
      'site_id': ?siteId,
    }, userJwt: await _currentJwt());
    return _committeeRows(response);
  }

  /// Creates a new member with a start month (first day of month).
  static Future<void> addCommitteeMemberAuthenticated({
    required String siteId,
    required String name,
    required String designation,
    required DateTime effectiveFrom,
    int? displayOrder,
  }) async {
    final response = await _request({
      'action': 'add_committee_member_authenticated',
      'site_id': siteId,
      'name': name.trim(),
      'designation': designation.trim(),
      'effective_from': _firstOfMonth(effectiveFrom),
      'display_order': ?displayOrder,
    }, userJwt: await _currentJwt());
    if (response['success'] != true) {
      throw Exception('The server did not confirm that the member was added.');
    }
  }

  /// Ends membership starting with removedFrom, EXCLUDING that month.
  /// Historical months strictly before removedFrom remain unchanged.
  static Future<void> removeCommitteeMemberAuthenticated({
    required String siteId,
    required String membershipId,
    required DateTime removedFrom,
  }) async {
    final response = await _request({
      'action': 'remove_committee_member_authenticated',
      'site_id': siteId,
      'membership_id': membershipId,
      'removed_from': _firstOfMonth(removedFrom),
    }, userJwt: await _currentJwt());
    if (response['success'] != true) {
      throw Exception('The server did not confirm the removal month.');
    }
  }

  /// Corrects the first month for an existing historical membership.
  static Future<void> correctCommitteeStartAuthenticated({
    required String siteId,
    required String membershipId,
    required DateTime effectiveFrom,
  }) async {
    final response = await _request({
      'action': 'correct_committee_start_authenticated',
      'site_id': siteId,
      'membership_id': membershipId,
      'effective_from': _firstOfMonth(effectiveFrom),
    }, userJwt: await _currentJwt());
    if (response['success'] != true) {
      throw Exception('The server did not confirm the start month.');
    }
  }

  /// Correct an existing membership version or create a new dated detail
  /// version. If splitFrom is null, this is an intentional correction to the
  /// selected historical record; if set, months before splitFrom stay intact.
  static Future<void> editCommitteeMemberAuthenticated({
    required String siteId,
    required String membershipId,
    required String name,
    required String designation,
    required DateTime effectiveFrom,
    required DateTime? removedFrom,
    required String expectedUpdatedAt,
    DateTime? splitFrom,
  }) async {
    final response = await _request({
      'action': 'edit_committee_member_authenticated',
      'site_id': siteId,
      'membership_id': membershipId,
      'name': name.trim(),
      'designation': designation.trim(),
      'effective_from': _firstOfMonth(effectiveFrom),
      'removed_from': removedFrom == null ? null : _firstOfMonth(removedFrom),
      'split_from': splitFrom == null ? null : _firstOfMonth(splitFrom),
      'expected_updated_at': expectedUpdatedAt,
    }, userJwt: await _currentJwt());
    if (response['success'] != true) {
      throw Exception('The server did not confirm that the member was edited.');
    }
  }

  /// Creates a new membership version with the same member_id and a fresh
  /// effective month. The earlier inactive months remain unchanged.
  static Future<void> restoreCommitteeMemberAuthenticated({
    required String siteId,
    required String membershipId,
    required DateTime effectiveFrom,
  }) async {
    final response = await _request({
      'action': 'restore_committee_member_authenticated',
      'site_id': siteId,
      'membership_id': membershipId,
      'effective_from': _firstOfMonth(effectiveFrom),
    }, userJwt: await _currentJwt());
    if (response['success'] != true) {
      throw Exception('The server did not confirm that the member was restored.');
    }
  }

  /// Permanently removes all recorded periods for the same member_id.
  /// Caller must obtain an explicit confirmation from the user.
  static Future<void> deleteCommitteeMemberHistoryAuthenticated({
    required String siteId,
    required String membershipId,
    required String expectedUpdatedAt,
  }) async {
    final response = await _request({
      'action': 'delete_committee_member_authenticated',
      'site_id': siteId,
      'membership_id': membershipId,
      'expected_updated_at': expectedUpdatedAt,
    }, userJwt: await _currentJwt());
    if (response['success'] != true) {
      throw Exception('The server did not confirm permanent deletion.');
    }
  }

  /// Action: `admin_create_site` (backend must require an active admin).
  /// `totalUnits` is the overall unit count for the entire property.
  /// Response: { "id": "..." } or { "site": { "id": "..." } }
  static Future<Map<String, dynamic>> createSiteAuthenticated({
    required String siteName,
    required int totalUnits,
    Map<String, dynamic> siteInformation = const {},
    List<Map<String, dynamic>> managementCommittee = const [],
    List<Map<String, dynamic>> siteTeam = const [],
  }) async {
    if (totalUnits <= 0) {
      throw ArgumentError.value(
        totalUnits,
        'totalUnits',
        'Must be a whole number greater than zero.',
      );
    }

    return _request({
      'action': 'admin_create_site',
      'site_name': siteName,
      'total_units': totalUnits,
      'site_information': siteInformation,
      'management_committee': managementCommittee,
      'site_team': siteTeam,
    }, userJwt: await _currentJwt());
  }

  /// Action: `admin_get_site` (admin only). Response: { "site": {...} }
  static Future<Map<String, dynamic>> getSiteAuthenticated({
    required String siteId,
  }) async {
    final response = await _request({
      'action': 'admin_get_site',
      'site_id': siteId,
    }, userJwt: await _currentJwt());

    final site = response['site'];

    if (site is! Map) {
      throw Exception('Invalid property information returned by server.');
    }

    return Map<String, dynamic>.from(site);
  }

  /// Action: `admin_update_site` (admin only).
  /// `totalUnits` is the overall unit count for the entire property.
  /// Response: { "site": {...} }
  static Future<Map<String, dynamic>> updateSiteAuthenticated({
    required String siteId,
    required String siteName,
    required int totalUnits,
    required Map<String, dynamic> siteInformation,
    required List<Map<String, dynamic>> managementCommittee,
  }) async {
    if (totalUnits <= 0) {
      throw ArgumentError.value(
        totalUnits,
        'totalUnits',
        'Must be a whole number greater than zero.',
      );
    }

    final response = await _request({
      'action': 'admin_update_site',
      'site_id': siteId,
      'site_name': siteName,
      'total_units': totalUnits,
      'site_information': siteInformation,
      'management_committee': managementCommittee,
    }, userJwt: await _currentJwt());

    final site = response['site'];

    if (site is! Map) {
      throw Exception(
        'Invalid updated property information returned by server.',
      );
    }

    return Map<String, dynamic>.from(site);
  }

  /// Action: `admin_upload_image` (admin only).
  static Future<Map<String, dynamic>> uploadSiteImageAuthenticated({
    required String siteId,
    required Uint8List imageBytes,
    required String contentType,
  }) async {
    _validateImage(imageBytes, contentType);

    return _request({
      'action': 'admin_upload_image',
      'site_id': siteId,
      'image_base64': base64Encode(imageBytes),
      'content_type': contentType,
    }, userJwt: await _currentJwt());
  }

  /// Action: `admin_remove_image` (admin only).
  static Future<void> removeSiteImageAuthenticated({
    required String siteId,
  }) async {
    await _request({
      'action': 'admin_remove_image',
      'site_id': siteId,
    }, userJwt: await _currentJwt());
  }

  /// Action: `admin_delete_site` (backend must require an active admin).
  /// The Edge Function must define safe handling for related site records.
  static Future<void> deleteSiteAuthenticated({
    required String siteId,
  }) async {
    if (siteId.trim().isEmpty) {
      throw ArgumentError.value(siteId, 'siteId', 'Cannot be empty.');
    }

    final response = await _request({
      'action': 'admin_delete_site',
      'site_id': siteId,
    }, userJwt: await _currentJwt());

    if (response['success'] != true) {
      throw Exception('The server did not confirm property deletion.');
    }
  }

  // ---------------------------------------------------------------------------
  // LEGACY (passcode / site access token) METHODS - unchanged.
  // Keep until the authenticated flow has been tested.
  // ---------------------------------------------------------------------------

  static Future<List<Map<String, dynamic>>> listSites() async {
    final response = await _request({'action': 'list'});

    final sites = response['sites'];

    if (sites is! List) {
      throw Exception('Invalid property list returned by server.');
    }

    return sites
        .whereType<Map>()
        .map((site) => Map<String, dynamic>.from(site))
        .toList();
  }

  static Future<Map<String, dynamic>> createSite({
    required String siteName,
    required String passcode,
    Map<String, dynamic> siteInformation = const {},
    List<Map<String, dynamic>> managementCommittee = const [],
    List<Map<String, dynamic>> siteTeam = const [],
  }) async {
    return _request({
      'action': 'create',
      'site_name': siteName,
      'passcode': passcode,
      'site_information': siteInformation,
      'management_committee': managementCommittee,
      'site_team': siteTeam,
    });
  }

  static Future<Map<String, dynamic>> uploadSiteImage({
    required String siteId,
    required String accessToken,
    required Uint8List imageBytes,
    required String contentType,
  }) async {
    _validateImage(imageBytes, contentType);

    final response = await _request({
      'action': 'upload_image',
      'site_id': siteId,
      'image_base64': base64Encode(imageBytes),
      'content_type': contentType,
    }, accessToken: accessToken);

    return response;
  }

  static Future<void> removeSiteImage({
    required String siteId,
    required String accessToken,
  }) async {
    await _request({
      'action': 'remove_image',
      'site_id': siteId,
    }, accessToken: accessToken);
  }

  static Future<String> authorizeSite({
    required String siteId,
    required String passcode,
  }) async {
    final response = await _request({
      'action': 'authorize',
      'site_id': siteId,
      'passcode': passcode,
    });

    final token = response['access_token'];

    if (token is! String || token.isEmpty) {
      throw Exception('The server did not return a site access token.');
    }

    return token;
  }

  static Future<Map<String, dynamic>> getSite({
    required String siteId,
    required String accessToken,
  }) async {
    final response = await _request({
      'action': 'get_site',
      'site_id': siteId,
    }, accessToken: accessToken);

    final site = response['site'];

    if (site is! Map) {
      throw Exception('Invalid property information returned by server.');
    }

    return Map<String, dynamic>.from(site);
  }

  static Future<Map<String, dynamic>> updateSite({
    required String siteId,
    required String accessToken,
    required String siteName,
    required Map<String, dynamic> siteInformation,
    required List<Map<String, dynamic>> managementCommittee,
  }) async {
    final response = await _request({
      'action': 'update_site',
      'site_id': siteId,
      'site_name': siteName,
      'site_information': siteInformation,
      'management_committee': managementCommittee,
    }, accessToken: accessToken);

    final site = response['site'];

    if (site is! Map) {
      throw Exception(
        'Invalid updated property information returned by server.',
      );
    }

    return Map<String, dynamic>.from(site);
  }

  // ---------------------------------------------------------------------------
  // HELPERS
  // ---------------------------------------------------------------------------

  static void _validateImage(Uint8List imageBytes, String contentType) {
    if (imageBytes.isEmpty || imageBytes.length > 5 * 1024 * 1024) {
      throw Exception('Choose an image smaller than 5 MB.');
    }

    if (!['image/jpeg', 'image/png', 'image/webp'].contains(contentType)) {
      throw Exception('Only JPEG, PNG, and WebP images are supported.');
    }
  }

  /// Returns the current Supabase Auth access token (JWT), refreshing the
  /// session first if it has expired.
  static Future<String> _currentJwt() async {
    final auth = Supabase.instance.client.auth;
    Session? session = auth.currentSession;

    if (session == null) {
      throw const AuthRequiredException();
    }

    if (session.isExpired) {
      try {
        final refreshed = await auth.refreshSession();
        session = refreshed.session;
      } catch (_) {
        session = null;
      }

      if (session == null) {
        throw const AuthRequiredException();
      }
    }

    return session.accessToken;
  }

  static Future<Map<String, dynamic>> _request(
    Map<String, dynamic> body, {
    String? accessToken,
    String? userJwt,
  }) async {
    final supabaseUrl = 'https://inovaclxtkcfnnzzymii.supabase.co';
    final publishableKey = 'sb_publishable_GyzVcvCNrR4Y0kS5_iCuww_Tdlc7vVM';

    if (supabaseUrl.isEmpty || publishableKey.isEmpty) {
      throw Exception(
        'Missing SUPABASE_URL or SUPABASE_PUBLISHABLE_KEY '
        'build configuration.',
      );
    }

    final headers = <String, String>{
      'Content-Type': 'application/json',
      'apikey': publishableKey,
    };

    if (userJwt != null) {
      // Authenticated flow: the backend verifies this JWT.
      headers['Authorization'] = 'Bearer $userJwt';
    } else if (accessToken != null) {
      // Legacy flow: site access token.
      headers['Authorization'] = 'Bearer $accessToken';
    } else {
      // Legacy public directory requests still need a valid Supabase API key.
      headers['Authorization'] = 'Bearer $publishableKey';
    }

    final response = await http.post(
      Uri.parse('$supabaseUrl/functions/v1/$_functionName'),
      headers: headers,
      body: jsonEncode(body),
    );

    Map<String, dynamic> result;

    try {
      final decoded = jsonDecode(response.body);
      result = decoded is Map
          ? Map<String, dynamic>.from(decoded)
          : <String, dynamic>{};
    } catch (_) {
      if (userJwt != null && response.statusCode == 401) {
        throw const AuthRequiredException();
      }

      throw Exception(
        'Property service returned an invalid response '
        '(${response.statusCode}).',
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final serverMessage = result['error']?.toString();

      if (userJwt != null) {
        if (response.statusCode == 401) {
          throw AuthRequiredException(
            serverMessage ?? 'Your session has expired. Please sign in again.',
          );
        }

        if (response.statusCode == 403) {
          throw PropertyAccessDeniedException(
            serverMessage ??
                'You do not have permission to perform this action.',
          );
        }
      }

      throw Exception(
        serverMessage ?? 'Property request failed (${response.statusCode}).',
      );
    }

    return result;
  }
}