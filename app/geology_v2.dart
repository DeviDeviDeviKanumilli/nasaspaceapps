// Data model for the optional `geology_v2` block of app_bundle.json (block_version geo-2.0-app-1).
// Pure Dart (no Flutter import) so it can be unit-tested with `dart run`. Unknown keys are ignored;
// a bundle without `geology_v2` parses to null, so older bundles keep working.
// Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.

List<T> _list<T>(dynamic v, T Function(dynamic) f) => v == null ? <T>[] : (v as List).map(f).toList();
List<String> _strs(dynamic v) => _list(v, (e) => e.toString());
double? _num(dynamic v) => v == null ? null : (v as num).toDouble();

class ComparisonRow {
  final String property, role, roleLabel, marsEvidenceType, marsStatement, earthStatus;
  final String? marsSite, earthSource, earthText;
  final List<String> citations;
  ComparisonRow.fromJson(Map<String, dynamic> j)
      : property = j['property'] as String,
        role = j['role'] as String,
        roleLabel = (j['role_label'] ?? j['role']) as String,
        marsSite = j['mars_site'] as String?,
        marsEvidenceType = j['mars_evidence_type'] as String,
        marsStatement = j['mars_statement'] as String,
        citations = _strs(j['citations']),
        earthStatus = j['earth_status'] as String,
        earthSource = j['earth_source'] as String?,
        earthText = j['earth_text'] as String?;
  /// True when the Earth side has evidence for this property (no scores involved).
  bool get earthRecorded => earthStatus.startsWith('recorded') || earthStatus.startsWith('corroborated');
}

class GeoProperty {
  final String code, role, roleLabel, evidenceType, statement;
  final String? marsSite;
  final List<String> citations;
  GeoProperty.fromJson(Map<String, dynamic> j)
      : code = j['code'] as String,
        role = j['role'] as String,
        roleLabel = (j['role_label'] ?? j['role']) as String,
        marsSite = j['mars_site'] as String?,
        evidenceType = j['evidence_type'] as String,
        statement = j['statement'] as String,
        citations = _strs(j['citations']);
}

class GeoReference {
  final String id, name;
  final String? siteNote;
  final List<String> notComparable;
  final List<GeoProperty> properties;
  GeoReference.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        name = j['name'] as String,
        siteNote = j['site_note'] as String?,
        notComparable = _strs(j['not_comparable']),
        properties = _list(j['properties'], (e) => GeoProperty.fromJson(e as Map<String, dynamic>));
}

class FeaturedCase {
  final String id, region, reference, title, outcome, unitName, unitLink, note;
  final double? preserveAreaKm2, shareWithin500mOfIntrusion;
  final List<ComparisonRow> comparison;
  final List<String> conflicts;
  FeaturedCase.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        region = j['region'] as String,
        reference = j['reference'] as String,
        title = j['title'] as String,
        outcome = j['outcome'] as String,
        unitName = j['unit_name'] as String,
        unitLink = j['unit_link'] as String,
        note = (j['note'] ?? '') as String,
        preserveAreaKm2 = _num(j['preserve_area_km2']),
        shareWithin500mOfIntrusion = _num(j['share_within_500m_of_intrusive_contact']),
        comparison = _list(j['comparison'], (e) => ComparisonRow.fromJson(e as Map<String, dynamic>)),
        conflicts = _strs(j['conflicts']);
}

class GeoUnitCard {
  final String id, region, reference, unitName, unitLink, state, exposureNote;
  final String? unitAge;
  final int polygons;
  final double areaKm2, steepGroundKm2, publicSteepGroundKm2;
  final double? nearestDistanceKm;
  final List<double>? nearestPoint;
  final List<String> supportingRecorded, conflicts, publicLandsWithSteepGround, notComparable, unmeasured;
  final int supportingTotal;
  final List<ComparisonRow> comparison;
  GeoUnitCard.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        region = j['region'] as String,
        reference = j['reference'] as String,
        unitName = j['unit_name'] as String,
        unitLink = j['unit_link'] as String,
        state = (j['state'] ?? '') as String,
        unitAge = j['unit_age'] as String?,
        polygons = j['polygons'] as int,
        areaKm2 = _num(j['area_km2'])!,
        nearestDistanceKm = _num(j['nearest_distance_km']),
        nearestPoint = j['nearest_point'] == null ? null : _list(j['nearest_point'], (e) => (e as num).toDouble()),
        steepGroundKm2 = _num(j['steep_ground_km2']) ?? 0,
        publicSteepGroundKm2 = _num(j['public_steep_ground_km2']) ?? 0,
        publicLandsWithSteepGround = _strs(j['public_lands_with_steep_ground']),
        exposureNote = (j['exposure_note'] ?? '') as String,
        supportingRecorded = _strs(j['supporting_recorded']),
        supportingTotal = j['supporting_total'] as int,
        conflicts = _strs(j['conflicts']),
        notComparable = _strs(j['not_comparable']),
        unmeasured = _strs(j['unmeasured']),
        comparison = _list(j['comparison'], (e) => ComparisonRow.fromJson(e as Map<String, dynamic>));
}

class ControlResult {
  final String region, reference, method;
  final double? precision, recall;
  ControlResult.fromJson(Map<String, dynamic> j)
      : region = j['region'] as String,
        reference = j['reference'] as String,
        method = j['method'] as String,
        precision = _num(j['precision']),
        recall = _num(j['recall']);
}

class GeologyV2Block {
  final String blockVersion;
  final List<GeoReference> references;
  final List<FeaturedCase> featured;
  final List<GeoUnitCard> units;
  final List<ControlResult> controls;
  final Map<String, String> citations;
  final List<String> limitations;
  GeologyV2Block.fromJson(Map<String, dynamic> j)
      : blockVersion = j['block_version'] as String,
        references = _list(j['references'], (e) => GeoReference.fromJson(e as Map<String, dynamic>)),
        featured = _list(j['featured'], (e) => FeaturedCase.fromJson(e as Map<String, dynamic>)),
        units = _list(j['units'], (e) => GeoUnitCard.fromJson(e as Map<String, dynamic>)),
        controls = _list(j['controls'], (e) => ControlResult.fromJson(e as Map<String, dynamic>)),
        citations = ((j['citations'] ?? {}) as Map<String, dynamic>).map((k, v) => MapEntry(k, v.toString())),
        limitations = _strs(j['limitations']);

  /// Returns null for bundles that do not carry the block (older exports).
  static GeologyV2Block? fromBundle(Map<String, dynamic> bundle) =>
      bundle['geology_v2'] == null ? null : GeologyV2Block.fromJson(bundle['geology_v2'] as Map<String, dynamic>);

  List<GeoUnitCard> unitsFor(String region, String reference) =>
      units.where((u) => u.region == region && u.reference == reference).toList();
}
