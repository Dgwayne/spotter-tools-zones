# spotter-tools-zones — catalog builder

Builder for the prebuilt NWS zone-geometry catalog consumed by Spotter Tools
Pro. A scheduled GitHub Action runs `tool/build_catalog.dart` weekly. It
downloads NWS's official zone shapefiles from https://www.weather.gov/gis/
(counties, public forecast zones, fire zones, coastal and offshore marine
zones), packs every zone polygon into the same `ZGC3` v1 binary format the
app uses on disk, and publishes the result as a GitHub Release.

The app fetches **one** file (~44 MB) from this repo's "latest" release
instead of doing ~11,650 per-zone HTTPS calls against NWS.

## How a build decides what to publish

- **Source set:** each GIS page lists the current shapefile set and, ahead
  of a zone change, the next one. The valid date is in the file name
  (`z_16ap26.zip` = 16 April 2026); the build uses the newest set already
  valid.
- **Geometry:** outer rings only (holes dropped, as the app always did),
  simplified to 25 m (islands under ~1 km across keep full detail), rounded
  to 4 decimals. Zones with more than 255 islands keep the 255 largest,
  since the format stores the ring count in one byte.
- **Unchanged weeks publish nothing.** `manifest.json` carries a
  `content_sha256` over the zone data. When it matches the published
  release, no release is made, so phones (which re-download whenever
  `generated_at` is newer than their copy) download nothing.
- **Diff safety gate:** before publishing, the build compares against the
  published release and refuses if more than 2% of zones disappeared or
  more than 1% changed shape drastically. If NWS really did change that
  much, re-run the workflow manually with **allow_large_diff** ticked.

## Files in this folder

- `pubspec.yaml` — minimal Dart pubspec for the builder.
- `tool/build_catalog.dart` — the builder script.
- `.github/workflows/build-catalog.yml` — weekly cron + manual trigger.

## One-time bootstrap

From this `catalog_builder/` folder in the **Spotter Tools Pro WIP**
workspace, copy everything into your separate `spotter-tools-zones` repo
clone, then push.

```powershell
# Copy the scaffold into the new repo
$dest = "C:\path\to\your\spotter-tools-zones"
Copy-Item -Recurse -Force .\pubspec.yaml $dest
Copy-Item -Recurse -Force .\tool $dest
New-Item -ItemType Directory -Force "$dest\.github\workflows" | Out-Null
Copy-Item -Force ".\.github\workflows\build-catalog.yml" "$dest\.github\workflows\"

# From inside the new repo clone:
cd $dest
git add .
git commit -m "Initial catalog builder + weekly workflow"
git push -u origin main
```

## First run

1. GitHub → your `spotter-tools-zones` repo → **Actions** tab.
2. Pick **Build NWS Zone Catalog** in the left sidebar.
3. Click **Run workflow** → **main** → green **Run workflow** button.
4. Wait ~2 minutes for the run to finish.
5. **Releases** tab → confirm a release tagged `catalog-YYYYMMDD-1` exists
   with both `zones.bin` and `manifest.json` attached.

## Verify the stable URLs

These URLs always redirect to the latest release's assets. They do not
change for the lifetime of the app.

- `https://github.com/Dgwayne/spotter-tools-zones/releases/latest/download/manifest.json`
- `https://github.com/Dgwayne/spotter-tools-zones/releases/latest/download/zones.bin`

Open both in a browser. The manifest should be ~250 bytes of JSON. The
binary will trigger a download dialog.

## Bake the seed asset

After the first successful release, download `zones.bin` and drop it at
`assets/nws/zones.bin` in the Spotter Tools Pro app repo. Re-bake before
each app release if you want the freshest possible seed (optional — the
app will silently refresh from this repo's latest release on first
unmetered network anyway).
