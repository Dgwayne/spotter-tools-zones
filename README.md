# spotter-tools-zones — catalog builder

Builder for the prebuilt NWS zone-geometry catalog consumed by Spotter Tools
Pro. A scheduled GitHub Action runs `tool/build_catalog.dart` weekly, which
fans out across the public `api.weather.gov` endpoints, packs every zone
polygon into the same `ZGC3` v1 binary format the app uses on disk, and
publishes the result as a GitHub Release.

The app fetches **one** file (~12 MB) from this repo's "latest" release
instead of doing ~15,000 per-zone HTTPS calls against NWS.

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
4. Wait ~10–15 minutes for the run to finish.
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
