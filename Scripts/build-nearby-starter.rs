use std::path::PathBuf;
use zimru::writer::{Creator, Item};
use zimru::Compression;

const TITLE: &str = "Tinfoil Kit Offline Starter";
const DATE: &str = "2026-11-24";
const ILLUSTRATION: &[u8] =
    include_bytes!("../Resources/NearbyPublic/offline-starter-illustration.png");
const CHECK_IN: &str = include_str!("../Resources/NearbyPublic/household-check-in-v1.txt");
const STATUS_LOG: &str = include_str!("../Resources/NearbyPublic/neighborhood-status-log-v1.txt");
const LICENSE: &str = include_str!("../LICENSE");

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let output = PathBuf::from(std::env::args_os().nth(1).ok_or("Missing destination")?);
    let mut archive = Creator::new();
    archive
        .set_uuid([
            0x91, 0xc0, 0x18, 0xfa, 0x5e, 0xf6, 0x45, 0x17, 0xa3, 0xe5, 0xd1, 0x30, 0x26, 0x11,
            0x24, 0x00,
        ])
        .set_compression(Compression::None);

    for (key, value) in [
        ("Title", TITLE),
        (
            "Description",
            "Preparedness, household check-in and offline setup",
        ),
        ("Language", "eng"),
        ("Creator", "Tinfoil Kit iOS contributors"),
        ("Publisher", "Tinfoil Kit"),
        ("Name", "tinfoilkit_offline_starter"),
        ("Date", DATE),
        ("License", "MIT"),
        ("Source", "https://github.com/scottleibrand/TinFoilKit-iOS"),
    ] {
        archive.try_add_metadata(key, value.as_bytes())?;
    }
    archive.try_add_illustration(48, ILLUSTRATION)?;
    archive.try_set_main_path("index.html")?;
    add_page(
        &mut archive,
        "index.html",
        TITLE,
        r#"
<p>November 2026 edition. Keep these references on your device before a disruption.</p>
<ul>
<li><a href="earthquake-safety.html">Earthquake safety and local updates</a></li>
<li><a href="household-check-in.html">Household check-in worksheet</a></li>
<li><a href="neighborhood-status.html">Neighborhood status log</a></li>
<li><a href="prepare-offline.html">Prepare Tinfoil Kit for offline use</a></li>
<li><a href="license.html">License and credits</a></li>
</ul>"#,
    )?;

    // Original wording from Sources/TinfoilKit/DisasterStarterView.swift.
    add_page(
        &mut archive,
        "earthquake-safety.html",
        "Earthquake safety and local updates",
        r#"
<h2>Get to safety</h2>
<p>If the ground is shaking, drop, cover and hold on. Protect your head and neck. If you use a wheelchair, lock the wheels if you can, then cover and hold on.</p>
<p>Once shaking stops, stay clear of damaged buildings, downed wires and floodwater. Expect aftershocks. In the U.S., call 911 for immediate danger or serious injury.</p>
<p>In a low-lying coastal area, strong or prolonged shaking, a sudden change in sea level or a loud ocean roar can signal a tsunami. As soon as you can move safely, follow evacuation signs or head inland or to high ground.</p>
<h2>Find your bearings</h2>
<p>Note the time and your location using a street intersection, landmark or coordinates. Use your household meeting point if you can reach it safely.</p>
<p>Use saved maps to orient yourself. Check local evacuation orders, road and bridge conditions and utility advisories. Turn back if a route looks unsafe.</p>
<h2>Check in</h2>
<p>Text your household or a contact outside the affected area. Keep it short so they can pass it on.</p>
<p>Name · time · location · safe or need help · next check-in</p>
<h2>Get local updates</h2>
<p>Follow local emergency alerts and posted instructions. If you lose phone service, listen for updates on a battery-powered radio if one is available.</p>
<h2>Official sources when online</h2>
<ul>
<li><a href="https://www.ready.gov/sites/default/files/2025-02/fema_full-suite-hazard-info-sheets.pdf">FEMA earthquake safety</a></li>
<li><a href="https://www.cdc.gov/earthquakes/safety/stay-safe-after-an-earthquake.html">CDC safety after an earthquake</a></li>
<li><a href="https://www.weather.gov/safety/tsunami-during">National Weather Service tsunami guidance</a></li>
<li><a href="https://www.fema.gov/print/pdf/node/331794">FEMA household communication planning</a></li>
<li><a href="https://www.fema.gov/sites/default/files/documents/fema_hm-know-your-alerts-and-warnings_english.pdf">FEMA alerts and warnings</a></li>
</ul>"#,
    )?;

    add_page(
        &mut archive,
        "household-check-in.html",
        "Household check-in worksheet",
        &template_body(CHECK_IN),
    )?;
    add_page(
        &mut archive,
        "neighborhood-status.html",
        "Neighborhood status log",
        &template_body(STATUS_LOG),
    )?;

    add_page(
        &mut archive,
        "prepare-offline.html",
        "Prepare Tinfoil Kit for offline use",
        r#"
<h2>Library and maps</h2>
<p>In Library, open Content Packs and choose the references you want. Allow time for indexing, then search for a topic you know is in a downloaded pack. Open a result to check that you can read the source.</p>
<p>In Map, install a regional bundle with coverage where you need it. Find an address and a place you recognize. Check that you can calculate a walking or driving route between two locations inside the installed region.</p>
<h2>Household</h2>
<p>Set Home and save meeting points as pins in Map. Write down a backup meeting point and an out-of-area contact. In Household, review the notes and pins, export a backup, or print the essentials.</p>
<h2>Check before disconnecting</h2>
<p>Open Offline readiness in Library, then choose Run offline checks. Try a reference, a local search, and a route. Repeat in airplane mode with Wi-Fi off to see what remains available.</p>
<p>In Library, open Find nearby. With public sync enabled, the app can exchange verified public references with another participating device over a local connection.</p>"#,
    )?;

    let credits = format!(
        "<p>Original Tinfoil Kit iOS references and illustration. The earthquake article links to official sources for further reading.</p><pre>{}</pre>",
        escape(LICENSE)
    );
    add_page(
        &mut archive,
        "license.html",
        "License and credits",
        &credits,
    )?;
    archive.write_to(output)?;
    Ok(())
}

fn add_page(archive: &mut Creator, path: &str, title: &str, body: &str) -> zimru::Result<()> {
    let page = format!(
        r#"<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title></head><body><header><a href="index.html">Offline Starter</a></header>
<main><h1>{title}</h1>{body}</main><footer><a href="license.html">MIT license</a></footer></body></html>"#,
        title = escape(title),
    );
    archive.try_add_item(Item::new(path, title, "text/html", page.into_bytes()))
}

fn template_body(source: &str) -> String {
    let (_, content) = source.split_once("\n\n").expect("Template has a title");
    let (content, _) = content
        .split_once("\n\nOriginal Tinfoil Kit reference")
        .expect("Template has license attribution");
    content
        .split("\n\n")
        .map(|paragraph| {
            if paragraph.contains('\n') {
                format!("<pre>{}</pre>", escape(paragraph))
            } else {
                format!("<p>{}</p>", escape(paragraph))
            }
        })
        .collect()
}

fn escape(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}
