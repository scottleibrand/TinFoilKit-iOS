#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
output="$(mktemp -d)"
trap 'rm -rf "$output"' EXIT
xcrun swiftc -module-cache-path "$output/module-cache" -o "$output/verify" \
    Tests/HouseholdSharingFixture/VerifyHouseholdSharing.swift \
    Sources/TinfoilKit/HouseholdNoteProposal.swift \
    Sources/TinfoilKit/HouseholdPinProposal.swift \
    Sources/TinfoilKit/HouseholdSharing.swift \
    Sources/TinfoilKit/Household.swift \
    Sources/TinfoilKit/MapCoordinateText.swift \
    Sources/TinfoilKit/Nearby{PublicManifest,PublicReference,PublicResume}.swift
"$output/verify" "$output"

if command -v node >/dev/null; then
    node - "$output" <<'JS'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

function loadSearch(file) {
    const html = fs.readFileSync(path.join(process.argv[2], file), 'utf8');
    const main = html.match(/<main(?:\s[^>]*)?>([\s\S]*?)<\/main>/)[1];
    const sections = Array.from(main.matchAll(/<section(?:\s[^>]*)?>([\s\S]*?)<\/section>/g), ([, content]) => ({
        title: content.match(/<h2(?:\s[^>]*)?>([^<]+)<\/h2>/)[1],
        textContent: content.replace(/<[^>]+>/g, ' '),
        querySelectorAll: () => [],
        hidden: false,
    }));
    const search = { hidden: true };
    const status = { textContent: '' };
    let onInput;
    const input = { addEventListener: (_, handler) => { onInput = handler; } };
    const selectors = { '#search': search, '#query': input, '#search-status': status };
    const document = {
        querySelector: selector => selectors[selector],
        querySelectorAll: selector => selector === 'main > section' ? sections : [],
    };
    vm.runInNewContext(html.match(/<script nonce="[^"]+">([\s\S]*?)<\/script>/)[1], { document });
    assert.equal(search.hidden, false);
    return value => {
        input.value = value;
        onInput();
        return { titles: sections.filter(section => !section.hidden).map(section => section.title),
                 hasStatus: Boolean(status.textContent) };
    };
}

const searchBoth = loadSearch('public-references.html');
const worksheet = 'Household check-in worksheet';
const statusLog = 'Neighborhood status log';
assert.deepEqual(searchBoth('OuT-of-ARea Contact'), { titles: [worksheet], hasStatus: false });
assert.deepEqual(searchBoth('correction to earlier entry'), { titles: [statusLog], hasStatus: false });
assert.equal(searchBoth('').titles.length, 2);

const searchSelected = loadSearch('selected-reference.html');
assert.deepEqual(searchSelected('correction to earlier entry'), { titles: [], hasStatus: true });
assert.deepEqual(searchSelected(''), { titles: [worksheet], hasStatus: false });
console.log('Verified browser search across the selected public references.');
JS
fi
