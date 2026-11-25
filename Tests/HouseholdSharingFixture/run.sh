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
    Sources/TinfoilKit/HouseholdResource.swift \
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
    const sections = Array.from(main.matchAll(/<section([^>]*)>([\s\S]*?)<\/section>/g), ([, attributes, content]) => {
        const title = content.match(/<h2(?:\s[^>]*)?>([^<]+)<\/h2>/)[1];
        const passages = Array.from(content.matchAll(/<p id="([^"]+)" data-reference-passage>([\s\S]*?)<\/p>/g),
            ([, id, textContent]) => ({ id, textContent }));
        return {
            title, textContent: content.replace(/<[^>]+>/g, ' '), hidden: false,
            isPublicReference: attributes.includes('data-public-reference'),
            querySelector: () => ({ textContent: title }),
            querySelectorAll: selector => selector === '[data-reference-passage]' ? passages : []
        };
    });
    const node = () => ({
        handlers: {}, children: [], textContent: '',
        addEventListener(kind, action) { this.handlers[kind] = action; },
        dispatchEvent(event) { this.handlers[event.type](); },
        append(...items) { this.children.push(...items); },
        replaceChildren() { this.children = []; }
    });
    const search = { hidden: true };
    const status = { textContent: '' };
    const input = node();
    const question = node();
    const feedback = node();
    const results = node();
    const askForm = node();
    const ask = { hidden: true, querySelector: () => askForm };
    const selectors = {
        '#search': search, '#query': input, '#search-status': status,
        '#shared-ask': ask, '#shared-question': question,
        '#shared-ask-status': feedback, '#shared-ask-results': results
    };
    const document = {
        querySelector: selector => selectors[selector],
        querySelectorAll: selector => selector === 'main > section' ? sections : sections.filter(section => section.isPublicReference),
        createElement: node
    };
    vm.runInNewContext(html.match(/<script nonce="[^"]+">([\s\S]*?)<\/script>/)[1], {
        document, Event: class { constructor(type) { this.type = type; } },
        fetch() { assert.fail('Shared Ask sent a network request'); }
    });
    assert.equal(search.hidden, false);
    assert.equal(ask.hidden, false);
    return {
        filter(value) {
            input.value = value;
            input.handlers.input();
            return { titles: sections.filter(section => !section.hidden).map(section => section.title),
                     hasStatus: Boolean(status.textContent) };
        },
        ask(value) {
            question.value = value;
            let cancelled = false;
            askForm.handlers.submit({ preventDefault: () => { cancelled = true; } });
            assert.ok(cancelled, 'Shared Ask submitted a form to the host');
            return { feedback: feedback.textContent, rows: results.children };
        },
        visibleReferences() { return sections.filter(section => section.isPublicReference && !section.hidden); }
    };
}

const searchBoth = loadSearch('public-references.html');
const worksheet = 'Household check-in worksheet';
const statusLog = 'Neighborhood status log';
assert.deepEqual(searchBoth.filter('OuT-of-ARea Contact'), { titles: [worksheet], hasStatus: false });
assert.deepEqual(searchBoth.filter('correction to earlier entry'), { titles: [statusLog], hasStatus: false });
assert.equal(searchBoth.filter('').titles.length, 2);

const searchSelected = loadSearch('selected-reference.html');
assert.deepEqual(searchSelected.filter('correction to earlier entry'), { titles: [], hasStatus: true });
assert.deepEqual(searchSelected.filter(''), { titles: [worksheet], hasStatus: false });
searchBoth.filter('correction to earlier entry');
const result = searchBoth.ask('Who is the out-of-area contact?');
assert.equal(result.feedback, 'Matching quotes');
assert.equal(result.rows.length, 1);
const [quote, citation] = result.rows[0].children;
assert.match(quote.textContent, /Agree on a time zone/);
assert.equal(citation.href, '#reference-household-check-in-v1-1');
assert.equal(citation.textContent, '[1] ' + worksheet);
citation.handlers.click();
assert.equal(searchBoth.visibleReferences().length, 2);
assert.match(searchBoth.ask('when was the condition observed?').rows[0].children[0].textContent, /when the condition was observed/);
assert.match(searchSelected.ask('official source confirmed').feedback, /No matching quote/);
assert.match(searchBoth.ask('particular purpose warranty').feedback, /No matching quote/);
assert.match(searchBoth.ask('meeting').feedback, /at least two topic words/);
assert.match(loadSearch('mixed-reference.html').ask('secret pantry inventory').feedback, /No matching quote/);
console.log('Verified search and browser-only quotes with exact citations across selected public references.');
JS
fi
