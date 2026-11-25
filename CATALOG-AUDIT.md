# Content pack catalog audit

Checked on 2026-11-24 against the iOS catalog at `391b4b9` and the pinned desktop setup at `6417927`. iOS has nine pack series and eleven pinned editions. Four series overlap the desktop library by archive family: water treatment, field medicine, Appropedia, and iFixit. iOS also supplies curated English and Spanish Wikipedia archives. Desktop offers a broader default library, optional full English Wikipedia and discovery through `kit search`. iOS can import ZIM files the user obtains separately. [iOS catalog](Sources/TinfoilKit/PackCatalog.json) · [Desktop catalog](https://github.com/tudor-city-ventures/tinfoil-kit/blob/64179271bcebffc5d76f1e3d13d2592e0089b6b1/kit.json) · [Desktop guide](https://github.com/tudor-city-ventures/tinfoil-kit/blob/64179271bcebffc5d76f1e3d13d2592e0089b6b1/GUIDE.md#changing-whats-in-the-kit)

## Pinned editions

For each configured download URL, a GET with `Range: bytes=1-1` returned HTTP 206, one byte and the total length below. Canonical Kiwix `.sha256` and `.meta4` files agreed with every catalog SHA-256 pin. Each Metalink named the exact edition and matched the total length from the configured host. The older Simple English and Spanish editions were verified through their dated filenames and sidecars. Kiwix's current OPDS feed uses `eng` or `spa` for the nine default editions. [Kiwix OPDS catalog](https://opds.library.kiwix.org/catalog/v2/entries?count=10&name=wikipedia_es_top)

| Pack | Edition | Language | Configured host | Exact bytes | Kiwix Metalink |
| --- | --- | --- | --- | ---: | --- |
| Water treatment | 2024-08 | English | download.kiwix.org | 20,924,451 | [Metadata](https://download.kiwix.org/zim/other/zimgit-water_en_2024-08.zim.meta4) |
| Appropedia | 2026-02 maxi | English | download.kiwix.org | 581,641,351 | [Metadata](https://download.kiwix.org/zim/other/appropedia_en_all_maxi_2026-02.zim.meta4) |
| Field medicine | 2024-08 | English | download.kiwix.org | 70,179,585 | [Metadata](https://download.kiwix.org/zim/other/zimgit-medicine_en_2024-08.zim.meta4) |
| Simple English Wikipedia | 2026-09 mini | English | ftp.fau.de | 530,482,005 | [Metadata](https://download.kiwix.org/zim/wikipedia/wikipedia_en-simple_all_mini_2026-09.zim.meta4) |
| Wikipedia Climate Change | 2026-10 mini | English | download.kiwix.org | 12,143,778 | [Metadata](https://download.kiwix.org/zim/wikipedia/wikipedia_en_climate-change_mini_2026-10.zim.meta4) |
| Wikipedia Chemistry | 2026-10 mini | English | download.kiwix.org | 23,322,446 | [Metadata](https://download.kiwix.org/zim/wikipedia/wikipedia_en_chemistry_mini_2026-10.zim.meta4) |
| Best of English Wikipedia | 2026-09 nopic | English | dumps.wikimedia.org | 2,745,850,723 | [Metadata](https://download.kiwix.org/zim/wikipedia/wikipedia_en_top_nopic_2026-09.zim.meta4) |
| iFixit repair guides | 2025-12 | English | mirror.download.kiwix.org | 3,570,695,757 | [Metadata](https://download.kiwix.org/zim/ifixit/ifixit_en_all_2025-12.zim.meta4) |
| Spanish Wikipedia highlights | 2026-10 mini | Spanish | ftp.fau.de | 217,314,941 | [Metadata](https://download.kiwix.org/zim/wikipedia/wikipedia_es_top_mini_2026-10.zim.meta4) |
| Simple English Wikipedia | 2026-06 mini | English | ftp.fau.de | 471,822,478 | [Metadata](https://download.kiwix.org/zim/wikipedia/wikipedia_en-simple_all_mini_2026-06.zim.meta4) |
| Spanish Wikipedia highlights | 2026-07 mini | Spanish | ftp.fau.de | 205,850,124 | [Metadata](https://download.kiwix.org/zim/wikipedia/wikipedia_es_top_mini_2026-07.zim.meta4) |

The climate-change pack was the only byte-count discrepancy at the audited revision. Its estimate was 13,000,000 bytes. Direct mirror sidecars returned 404 for FAU, Wikimedia and `mirror.download.kiwix.org`. The matching records came from canonical `download.kiwix.org`. The canonical archive URLs redirected to a Kiwix mirror for these probes. Resume and checksum validation after an iOS background interruption still need a device test. The probe compared published hashes and sampled one byte per archive. [Download recovery fixture](Tests/PackDownloadFixture/test_resume.py)

To repeat a range probe, use a configured catalog URL and curl 8.4 or later so the size cap also applies to bodies of unknown length. Fetch the canonical sidecars with a separate small size cap.

```sh
curl --silent --show-error --location --proto '=https' --proto-redir '=https' \
  --max-redirs 6 --max-time 15 --max-filesize 1 --range 1-1 \
  --dump-header - --output /dev/null "$pack_url"
```

## Terms and desktop gaps

The primary sources list CC BY-SA 4.0 as the default for Appropedia and Wikipedia text, with source-specific exceptions and media terms. iFixit lists CC BY-NC-SA 3.0 and attribution conditions. The ZIM Git water and field-medicine archives collect manuals with individual terms. These third-party catalog editions keep archive sharing disabled while edition-level rights remain unverified. The original MIT-licensed Tinfoil Kit Offline Starter is cleared separately. [Appropedia copyrights](https://www.appropedia.org/Appropedia:Copyrights) · [English Wikipedia copyrights](https://en.wikipedia.org/wiki/Wikipedia:Copyrights) · [Spanish Wikipedia copyrights](https://es.wikipedia.org/wiki/Wikipedia:Derechos_de_autor) · [iFixit licensing](https://www.ifixit.com/Info/Licensing) · [iOS notices](THIRD-PARTY.md)

Four desktop starter archives are absent from the iOS catalog. Kiwix's OPDS feed lists each as English, and each linked Metalink includes the edition, exact size and SHA-256. Publisher and per-document terms, range support at the selected download host, and offline search and printable-page behavior remain to be checked before catalog inclusion.

| Desktop starter gap | Exact bytes | Publisher metadata |
| --- | ---: | --- |
| Military medicine, 2026-10 | 64,986,090 | [Kiwix Metalink](https://download.kiwix.org/zim/zimit/irp.fas.org_en_military-medicine_2026-10.zim.meta4) |
| Post-disaster resources, 2024-05 | 644,665,513 | [Kiwix Metalink](https://download.kiwix.org/zim/other/zimgit-post-disaster_en_2024-05.zim.meta4) |
| Food preparation, 2025-04 | 97,822,565 | [Kiwix Metalink](https://download.kiwix.org/zim/other/zimgit-food-preparation_en_2025-04.zim.meta4) |
| Knots, 2024-08 | 27,945,133 | [Kiwix Metalink](https://download.kiwix.org/zim/other/zimgit-knots_en_2024-08.zim.meta4) |

The broader desktop library also includes WikiMed, Ready.gov, MedlinePlus, field manuals, textbooks, and practical Q&A collections. Verify each prospective edition independently. The iOS English Wikipedia highlights pack covers a smaller selection than the desktop's complete English Wikipedia option. [Desktop catalog](https://github.com/tudor-city-ventures/tinfoil-kit/blob/64179271bcebffc5d76f1e3d13d2592e0089b6b1/kit.json)

## Consolidated candidate on November 25, 2026

All six desktop starter archives have pinned iOS Essentials editions. New one-byte HTTPS probes for the four additions returned HTTP 206 and the exact lengths above. Their Metalinks matched the catalog filenames and SHA-256 digests. In the official English OPDS results, openZIM is the package publisher and Kiwix hosts the downloads. The included documents retain their original terms. All four entries support user-initiated downloads and keep archive sharing disabled. [Current catalog candidate](Sources/TinfoilKit/PackCatalog.json) · [Content notices](THIRD-PARTY.md)

On a fresh installation, **Download Essentials** totals 2,255,961,634 bytes and **Download all** totals 8,607,974,338 bytes, before indexing. WikiMed is an individual 2,302,838,768-byte download. Both complete English Wikipedia editions also remain individual downloads. [WikiMed Metalink](https://download.kiwix.org/zim/other/mdwiki_en_all_maxi_2025-11.zim.meta4)

The print audit verified the exact post-disaster and military-medicine PDF fallbacks. The combined candidate also includes Ready.gov 2026-10 as an individual 2,063,895,408-byte download. The Ready.gov home page, preparedness articles, archived pagination and redirects, and both aliases for its power-outage PDF passed bounded reader checks on Linux. The addition leaves both bulk totals unchanged. Publisher download recovery, PDF indexing, WebKit navigation and print preview still need Apple verification. [Print reference checks](PLAN.md#print-reference-checks) · [Ready.gov Metalink](https://download.kiwix.org/zim/zimit/ready.gov_en_all_2026-10.zim.meta4)

## Nearby redistribution review

The downloaded Wikipedia Climate Change 2026-10 mini edition matched the catalog at 12,143,778 bytes and SHA-256 `dbcc313b4dd30cf7abbb1e6481c493d82937262158ea97624ca879a0bcf98b67`. Its ZIM metadata lists Wikipedia as creator, openZIM as publisher, and `en.wikipedia.org` as source. The embedded counter lists 3,701 HTML entries, 4 PNG, 133 SVG, and 100 WebP resources, plus scripts and stylesheets. The metadata directory has no License record. Wikipedia applies separate license and attribution requirements to non-text resources. Review the included assets and carry the required notices before allowing automatic redistribution of this exact edition. The catalog entry still disables archive sharing. [Publisher archive](https://download.kiwix.org/zim/wikipedia/wikipedia_en_climate-change_mini_2026-10.zim) · [Wikipedia reuse policy](https://en.wikipedia.org/wiki/Wikipedia:Copyrights#Re-use_of_non-text_media)
