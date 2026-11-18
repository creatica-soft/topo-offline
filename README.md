# Topo Offline

An iPhone app for bushwalkers, trampers and hikers, and for cyclists and horse riders on the
trails: official topographic maps for Australia, New
Zealand, the United States, Canada, Switzerland and Norway, saved for use without phone signal,
with walking tracks and trails, campsites, huts, closures and elevation profiles.

**No account, no ads, no analytics, no tracking.** The app has no server of its own: map tiles
and data come straight from government open-data services, and your location never leaves your
phone. This repository is the complete source, so you can check that for yourself.

**[Get it on the App Store](https://apps.apple.com/app/id6833853505)** (Australia, New Zealand,
the United States, Canada, Switzerland and Norway).

## Features

- **Topo maps**: NSW, Queensland and Tasmania state topo maps, New Zealand's LINZ Topo50/Topo250,
  the USGS topo map for the United States (including Alaska, Hawaii and Puerto Rico), NRCan's
  Toporama for Canada, swisstopo's national map and Kartverket's topo map for Norway, and
  Geoscience Australia's 1:250k national map underneath the Australian state maps (optionally
  shown when zoomed out, with the state map taking over at walking scale).
- **Offline areas**: download what's on screen at full detail (with the tile count and size shown
  first); maps, place names, tracks and elevation are saved together. Zooming in past the
  downloaded detail enlarges the finest tiles instead of going blank. Offline mode uses only what's
  on the phone.
- **Search**: Australia's Composite Gazetteer (about 290,000 names), the NZ Gazetteer (about
  55,000 names, kept on the phone so it's instant and works offline), the USGS Geographic Names
  Information System, and the Canadian, Swiss and Norwegian national name registers, plus
  walking-track and trail names.
- **Walking tracks and trails** (NSW, QLD, TAS, VIC, NZ, US, Canada's national parks, BC and Ontario,
  Switzerland's named hiking routes and trail network, Norway's marked routes): tap a track to highlight all of it and
  see its name, type and length, and who may use it where the agency publishes that (Queensland,
  NZ DOC, the US and Ontario: cyclists, horse riders, dog rules). In Victoria, which has no free
  topo map, all tracks are drawn on the map.
- **Elevation profiles**: climb, descent, highest and lowest points, and a chart you can drag
  along to see the spot on the map.
- **Campsites, huts and closures**: official campgrounds (NSW National Parks, Vicmap, the national
  gazetteer, Victorian state forests, NZ DOC huts and campsites, US Forest Service campgrounds with
  their open or closed status, Parks Canada and BC recreation sites) and community campsites, huts and
  caravan parks from OpenStreetMap with facilities, merged into one pin per place. Current
  closures for Victorian state forests and NZ DOC (worked out from their dates; stale records are
  ignored) and NZ freedom-camping rules.
- **Routes**: tap the map to plan a route. Between two points it follows the walking tracks where
  there are any (using downloaded tracks when offline) and goes straight elsewhere. Tap the line to
  insert a point; tap a point to move it, delete it or extend the route from the start or end. The
  distance and climb update as you go. Saved routes and published tracks can be followed, showing the distance done and to
  go (to the end you're heading for, worked out from which way you're going). Off the
  route by more than a chosen distance (100 m unless changed), it vibrates and says which way the
  route is; with the phone locked it sends a notification with sound (made on the phone, so it
  works without signal).
- **GPX**: share routes and recordings as GPX files, and import GPX tracks and routes from
  Files, AirDrop or other apps.
- **Recording** (off by default, to save battery): records your walk or ride with GPS, also while
  the phone is locked, at a chosen detail (about every 5, 15 or 50 m). It shows the time,
  distance and climb as you go, and can be paused (GPS off) for a long break; if it looks stopped
  (within 50 m for 5 minutes, adjustable), a notification offers a Pause button. Afterwards it
  shows a speed chart under the elevation profile, with moving time, time stopped and average
  speed; GPS wandering during stops (indoors, around camp) isn't drawn or counted. Every recorded
  point is kept, and GPX export includes them all. Recordings stay on the phone.
- **Units**: kilometres and metres or miles and feet, following the phone's region or chosen in
  Settings (the gear on the map), where you can also pick the map and turn on recording.
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
| NSW topo map, NSW paths | © State of New South Wales (DCS Spatial Services) | CC BY 4.0 (confirmed by Spatial Services) |
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
| US topo map | USGS The National Map | Public domain |
| US trails | USGS National Digital Trails | Public domain |
| US place names | USGS Geographic Names Information System | Public domain |
| US campgrounds | USDA Forest Service | Public domain |
| Canada topo map (Toporama), place names | Natural Resources Canada | Open Government Licence – Canada |
| Canada national park trails and campgrounds | Parks Canada | Open Government Licence – Canada |
| BC trails and recreation sites | Recreation Sites and Trails BC | Open Government Licence – British Columbia |
| Ontario trails | Ontario Trail Network (Land Information Ontario) | Open Government Licence – Ontario |
| Swiss named hiking routes | Wanderland Schweiz (SchweizMobil), FEDRO and cantons | Opendata BY |
| Switzerland national map, hiking trails, place names | © swisstopo | swisstopo free geodata terms |
| Norway topo map, trails (Turruter), place names | © Kartverket | CC BY 4.0 |
| Elevation | Terrain Tiles on AWS (Geoscience Australia, LINZ, USGS 3DEP and SRTM) | CC BY / public domain |
| Community campsites | © OpenStreetMap contributors | ODbL 1.0 |

If you build your own app from this code, check each provider's terms for your use. Some ask to
be told about apps that use their services, and LINZ requires your own key.

### OpenStreetMap campsite extract

`TopoOffline/Resources/osm-campsites*.json` are extracts of campsites, caravan parks and huts
(Australia and New Zealand; the US and Canada; Switzerland and Norway), © OpenStreetMap
contributors, available under the [Open Database License](https://opendatacommons.org/licenses/odbl/).
They ship inside the app, so the app never contacts OpenStreetMap. Refresh them with one Overpass
query per country (a few minutes in all):

```sh
python3 -I Tools/update-osm-campsites.py anz TopoOffline/Resources/osm-campsites.json
python3 -I Tools/update-osm-campsites.py na TopoOffline/Resources/osm-campsites-na.json
python3 -I Tools/update-osm-campsites.py europe TopoOffline/Resources/osm-campsites-europe.json
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
