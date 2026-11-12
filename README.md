# Topo Offline

An iPhone app for bushwalkers and trampers: official topographic maps for Australia and New
Zealand that you can save for use without phone signal, with walking tracks, campsites, huts,
closures and elevation profiles.

**No account, no ads, no analytics, no tracking.** The app has no server of its own: map tiles
and data come straight from government open-data services, and your location never leaves your
phone. This repository is the complete source, so you can check that for yourself.

## Features

- **Topo maps**: NSW, Queensland and Tasmania state topo maps, New Zealand's LINZ Topo50/Topo250,
  and Geoscience Australia's 1:250k national map underneath (optionally shown when zoomed out,
  with the state map taking over at walking scale).
- **Offline areas**: download what's on screen at full detail (with the tile count and size shown
  first); maps, place names, tracks and elevation are saved together. Zooming in past the
  downloaded detail enlarges the finest tiles instead of going blank. Offline mode uses only what's
  on the phone.
- **Search**: Australia's Composite Gazetteer (about 290,000 names) and the NZ Gazetteer (about
  55,000 names, kept on the phone so it's instant and works offline), plus walking-track names.
- **Walking tracks** (NSW, QLD, TAS, VIC, NZ): tap a track to highlight all of it and see its name,
  type and length. In Victoria, which has no free topo map, all tracks are drawn on the map.
- **Elevation profiles**: climb, descent, highest and lowest points, and a chart you can drag
  along to see the spot on the map.
- **Campsites, huts and closures**: official campgrounds (NSW National Parks, Vicmap, the national
  gazetteer, Victorian state forests, NZ DOC huts and campsites) and community campsites and
  caravan parks from OpenStreetMap with facilities, merged into one pin per place. Current
  closures for Victorian state forests and NZ DOC (worked out from their dates; stale records are
  ignored) and NZ freedom-camping rules.
- Location, compass and an always-visible scale bar, all working without signal.

## Building

Requires a Mac with Xcode (iOS 17 SDK or later) and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
git clone https://github.com/creatica-soft/topo-offline.git
cd topo-offline
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig   # then fill it in, see below
xcodegen generate
open TopoOffline.xcodeproj
```

`Config/Secrets.xcconfig` holds your own settings and is ignored by git:

- `DEVELOPMENT_TEAM`: your Apple developer team ID (Xcode › Settings › Accounts), and a
  `PRODUCT_BUNDLE_IDENTIFIER` of your own.
- `LINZ_API_KEY`: needed only for the New Zealand topo map. A standard key (valid 90 days) is
  shown on [basemaps.linz.govt.nz](https://basemaps.linz.govt.nz). Apps should ask LINZ for a
  developer key and set `LINZ_KEY_IS_DEVELOPER = YES`; with a standard key, downloads are slowed
  to stay under LINZ's 1,000 tiles a minute. Without a key the NZ map is hidden; everything else
  still works.

The app builds without the file too (no NZ topo map, and you pick a team in Xcode).

Run on a phone: select it as the destination and press ▶. The first time, enable Developer Mode on
the phone (Settings › Privacy & Security).

### Tests

`Tools/selftest.sh` compiles the app's non-UI code for macOS and runs an end-to-end check against
the live services: tile downloads and offline reads, resume, over-zoom, search, tracks in every
state, campsites and closures, NZ data and elevation profiles. It takes a few minutes and uses a
small amount of each service.

## Data sources and licences

The app fetches data from these services at run time (nothing is redistributed in this
repository except the OpenStreetMap extract below). Each is credited in the app's About screen and
where its data is shown.

| Data | Source | Licence |
|---|---|---|
| NSW topo map, NSW paths | NSW Spatial Services (DCS) | CC BY 4.0 (web services terms) |
| Queensland topo map | Queensland Government | CC BY 4.0 |
| Queensland walking tracks | Queensland Parks (Department of Environment and Science) | CC BY 4.0 |
| Tasmania topo map and tracks | the LIST, State of Tasmania | CC BY 3.0 AU |
| Australia 1:250k map, place names | Geoscience Australia | CC BY 4.0 |
| Victorian tracks and campgrounds | Vicmap, State of Victoria | CC BY 4.0 |
| Victorian state forest sites and closures | DEECA, State of Victoria | CC BY 4.0 |
| NSW campground locations | NSW National Parks and Wildlife Service: "© State Government of NSW and NSW Department of Climate Change, Energy, the Environment and Water 2026" | CC BY (confirmed by the NSW data broker) |
| New Zealand topo map | Toitū Te Whenua LINZ (Basemaps) | CC BY 4.0, Basemaps terms of use |
| NZ place names | LINZ, NZ Gazetteer | CC BY 4.0 |
| NZ tracks, huts, campsites, closures, freedom camping | Department of Conservation | CC BY 4.0 |
| Elevation | Terrain Tiles on AWS (Geoscience Australia, LINZ, USGS SRTM) | CC BY / public domain |
| Community campsites | © OpenStreetMap contributors | ODbL 1.0 |

If you build your own app from this code, check each provider's terms for your use. Some ask to
be told about apps that use their services, and LINZ requires your own key.

### OpenStreetMap campsite extract

`TopoOffline/Resources/osm-campsites.json` is an extract of campsites and caravan parks in
Australia and New Zealand, © OpenStreetMap contributors, available under the
[Open Database License](https://opendatacommons.org/licenses/odbl/). It ships inside the app, so
the app never contacts OpenStreetMap. Refresh it with one Overpass query (about a minute):

```sh
python3 -I Tools/update-osm-campsites.py TopoOffline/Resources/osm-campsites.json
```

## Project layout

| Folder | What's in it |
|---|---|
| `TopoOffline/Model` | Map sources, tile maths, regions, tracks, place names, campsites and closures |
| `TopoOffline/Storage` | MBTiles files, the offline library (tiles, names, tracks), saved areas, park info and campground stores |
| `TopoOffline/Download` | Downloads, and clients for each data service (gazetteers, tracks, DOC, Victorian data, campgrounds, elevation) |
| `TopoOffline/Map` | MapKit tile overlay (downloaded → network → cache, with over-zoom) and the map view |
| `TopoOffline/Views` | SwiftUI screens, cards and detail sheets |
| `Config` | Build settings; your private `Secrets.xcconfig` goes here |
| `Tools` | Self-test, OpenStreetMap extract script |
| `docs` | Website (GitHub Pages): privacy policy and support pages |

Adding a topo map is one `TileSource` entry in `TileSource.swift`; adding a track dataset is one
`TrackLayer` in `TrackSources.swift`.

## Licence

The source code is licensed under the [GNU General Public License v3.0](LICENSE).
© 2026 Creatica. The official App Store version is published by the maintainer.

Map data and other data used by the app remain under their providers' licences (see above).

## Contributing

Issues and pull requests are welcome. By submitting a contribution you agree that it's licensed
under the GPL-3.0 and that Creatica may also distribute it as part of the App Store version of
the app (whose terms aren't GPL-compatible).
