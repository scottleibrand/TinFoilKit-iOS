# Seattle regional data pilot qualification

Checked 2026-11-25 against the existing Seattle candidate’s bounds of `-122.462,47.394,-122.005,47.831`. Its place index has 554,730 OSM records, including 21 hospital-class rows. These checks qualify candidate sources. Publisher files and generated extracts stay in the local build workspace. [Seattle regional candidate](https://github.com/scottleibrand/TinFoilKit-iOS/blob/codex/regional-data-candidate/Scripts/routing/SEATTLE-CANDIDATE.md)

**Pilot decision.** Use the DOH service-area edition for a local lookup prototype because it adds a geographic capability the bundle lacks. Resolve DOH redistribution terms before including the polygons in a published pack or Nearby catalog. Link the official Seattle hub locator for now. Keep CMS as an enrichment candidate for facilities with a verified match.

## Washington DOH drinking-water service areas

This source fills a gap in the current bundle. Its polygons allow a point-in-area lookup that a nearest-POI search cannot establish. The statewide ZIP served 7,729,603 bytes with `Last-Modified` 2026-11-23 14:04:56 UTC, ETag `"fe9fc39e537bdd1:0"`, and measured SHA-256 `d3947549afc751a5f6ac7a7a403ae7125d7f5952097e634afb2d3b037bb2ee67`. Its File Geodatabase has 4,327 features. The live ArcGIS item reports a separate data-edit timestamp of 2026-11-23 18:07:48 UTC. Preserve the edition and any per-feature date separately. [DOH ZIP](https://fortress.wa.gov/doh/base/gis/ServiceAreas.zip) · [Official GIS layer](https://services8.arcgis.com/rGGrs6HCnw87OFOT/arcgis/rest/services/Drinking_Water_Service_Areas/FeatureServer/0)

Clipping the ZIP to the full Seattle bundle bounds produced 66 valid multipolygons for 66 distinct systems, with 33,170 vertices. The measured output was 937,710 bytes of GeoJSON, or 197,459 bytes with Python gzip defaults and `mtime=0`. Its SHA-256 was `8dc74d57d50cddf03f0ddb4d1bcc58889f6ab548657dcab4856bd2851f5193d1`. A public downtown Seattle point matched Seattle Public Utilities (`77050`), whose polygon date is 2016-06-29. A public Bellevue point matched the City of Bellevue (`05575`), dated 2025-11-14. Both lookups ran against the local file.

The owner’s FGDC metadata lists no use constraints and credits DOH. The ArcGIS item does not name a license. Obtain explicit release terms before hosting the extract in a bundle or enabling peer distribution. Credit Washington State Department of Health, Office of Drinking Water. Some systems are unmapped. Treat results as approximate mapped service areas, and preserve multiple matches and gaps. Current outage or water-quality status needs a separate source. [Owner metadata](https://www.arcgis.com/sharing/rest/content/items/b09475f47a5a46ca90fe6a168fb22e6d/info/metadata/metadata.xml?format=default&output=html) · [State licensing guidance](https://data.wa.gov/stories/s/Updates-for-Data-wa-gov-Publishers/bbwv-q5hm/) · [DOH coverage notes](https://doh.wa.gov/community-and-environment/drinking-water/source-water/swap-mapping-tool)

The local check used GDAL 3.10.3 with `ServiceAreas.zip` at an absolute path. Select only system IDs, names, counties and date fields. The source archive also contains contact information, which is omitted from the clipped file. The two `WHERE` values select the publisher’s administrative layer records.

```sh
ogr2ogr -f GeoJSON -nln seattle_water_service_areas -nlt MULTIPOLYGON \
  -t_srs EPSG:4326 -spat -122.462 47.394 -122.005 47.831 -spat_srs EPSG:4326 \
  -clipdst -122.462 47.394 -122.005 47.831 -makevalid \
  -where "WS_Status = 'Active' AND ServiceAreaType = 'Current'" \
  -select WS_ID,WS_Name,County,UpdateDateTime,DataSourceDate \
  -lco RFC7946=YES -lco COORDINATE_PRECISION=6 \
  seattle-water-service-areas.geojson "/vsizip/$PWD/ServiceAreas.zip/ServiceAreas.gdb" ServiceAreas
ogrinfo -ro -dialect SQLite seattle-water-service-areas.geojson \
  -sql 'SELECT WS_ID, WS_Name FROM seattle_water_service_areas WHERE ST_Covers(geometry, MakePoint(-122.3321,47.6062,4326))'
```

## Seattle community emergency hubs

The Seattle Office of Emergency Management public locator’s ArcGIS item `cf8f9b64a37d4000a6e82e65a30fb694` returned 137 rows in 40,459 bytes, with SHA-256 `e3186836c4501784d7dad04c6f3264c9095831d1435a271e8e5b3f2196570f30`. Its reported data edit was 2022-05-04 22:06:59 UTC. It labels 71 records Networked and 66 Not Activated. Those are the publisher’s recorded classifications. Current staffing or availability requires a separate dated report. The same pinned OSM extract has 55 features tagged `emergency=assembly_point`. Only 32 of the locator’s 137 rows were within 50 m of any of those features, which is a proximity comparison. Preserve the hub designation and provenance if using both sources. [Official locator](https://experience.arcgis.com/experience/264f09d3aa3d4f8b841c9073de9fd51c/) · [Public feature item](https://www.arcgis.com/home/item.html?id=cf8f9b64a37d4000a6e82e65a30fb694) · [Bounded query](https://services.arcgis.com/ZOyb2t4B0UYuYNYH/arcgis/rest/services/ConciergeCommunityHubs_2_view/FeatureServer/0/query?where=1%3D1&outFields=ObjectID%2CHubID%2CHubTypeRevised%2CIndexArea%2CSector%2CSiteName%2CSiteAddress&returnGeometry=true&outSR=4326&orderByFields=ObjectID&f=geojson)

The public locator item does not specify a redistribution license. The separate 127-row SeattleWebEOC update-map item was edited in May 2026 and returned an out-of-region point. It links to King County terms that grant rights within the county’s copyright and exclude third-party rights. Confirm which edition Seattle OEM wants redistributed, its terms, and the coordinates to use before packaging. [Update-map feature item](https://www.arcgis.com/home/item.html?id=4aa15906b63c4377aa66d97be8ce1c75) · [Linked GIS terms](https://kingcounty.gov/en/dept/kcit/data-information-services/gis-center/about/terms-conditions-copyrights)

## CMS Hospital General Information

CMS dataset `xubh-q36u`, edition 2026-10-26, supplied 5,435 U.S. rows and 101 Washington rows. The pinned download measured 1,461,350 bytes with SHA-256 `ff2a82a7149975fb86348e7f901aa3bcd9f3701e8b0ecd0ab34702df193ff559`. For the exact `WA` and `SEATTLE` filter, ten records reduced to 719 gzip bytes with facility ID, name, postal address, telephone, type and emergency-service designation. These records contain no coordinates. [CMS dataset](https://data.cms.gov/provider-data/dataset/xubh-q36u) · [Dated CSV](https://data.cms.gov/provider-data/sites/default/files/resources/d3bf87c5505155f549d603688414f3c6_1793059553/Hospital_General_Information_2.csv) · [CMS government data terms](https://data.cms.gov/provider-data/topics/long-term-care-hospitals/about-using-government-data)

An offline comparison against the eight OSM hospital-class rows with a Seattle address found five unique exact street-address matches after normalizing abbreviations and removing mailboxes. IDs `500005`, `500008`, `500064`, `500138` and `504009` remain for review. Campus and entrance addresses can differ. Use the federal data as attributed enrichment for a verified hospital match instead of treating address comparisons as authority for new coordinates. The reported emergency-service designation belongs with facility reference data. Availability during an incident needs a separately dated source.
