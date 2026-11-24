import { execFileSync } from "node:child_process";
import { writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { gunzipSync } from "node:zlib";

const [pmtiles, archive, output, dependencies] = process.argv.slice(2);
const require = createRequire(resolve(dependencies, "package.json"));
const { VectorTile } = await import(pathToFileURL(require.resolve("@mapbox/vector-tile")));
const { default: Pbf } = await import(pathToFileURL(require.resolve("pbf")));

const region = { west: -122.53, south: 47.43, east: -122.18, north: 47.78 };
const zoom = 13;
const world = 2 ** zoom;
const column = (longitude) => Math.floor((longitude + 180) * world / 360);
const row = (latitude) => {
    const radians = latitude * Math.PI / 180;
    return Math.floor((1 - Math.asinh(Math.tan(radians)) / Math.PI) * world / 2);
};

const places = new Map();
for (let x = column(region.west); x <= column(region.east); x += 1) {
    for (let y = row(region.north); y <= row(region.south); y += 1) {
        const compressed = execFileSync(pmtiles, ["tile", "-q", archive, zoom, x, y]);
        if (compressed.length === 0) continue;
        const bytes = compressed[0] === 31 && compressed[1] === 139 ? gunzipSync(compressed) : compressed;
        const tile = new VectorTile(new Pbf(bytes));
        for (const name of ["places", "pois"]) {
            const layer = tile.layers[name];
            if (!layer) continue;
            for (let index = 0; index < layer.length; index += 1) {
                const feature = layer.feature(index);
                const title = feature.properties["name:en"] || feature.properties.name;
                if (feature.type !== 1 || !title) continue;
                const geometry = feature.toGeoJSON(x, y, zoom).geometry;
                if (geometry.type !== "Point") continue;
                const [longitude, latitude] = geometry.coordinates;
                if (longitude < region.west || longitude > region.east
                    || latitude < region.south || latitude > region.north) continue;
                const kind = String(feature.properties.kind || "place").replaceAll("_", " ");
                const key = [title, longitude.toFixed(4), latitude.toFixed(4)].join("|");
                places.set(key, { name: title, kind, latitude, longitude });
            }
        }
    }
}
if (places.size === 0) throw new Error("No named places found in the map extract.");
writeFileSync(output, JSON.stringify([...places.values()]));
process.stdout.write(`Indexed ${places.size} named places from the Seattle map.\n`);
