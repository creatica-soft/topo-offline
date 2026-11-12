#!/usr/bin/env python3
"""Extract campsites and caravan parks in Australia and New Zealand from OpenStreetMap.

Run before each app release (one Overpass query, well within its usage policy):

    python3 -I Tools/update-osm-campsites.py TopoOffline/Resources/osm-campsites.json

The output ships inside the app, so the app itself never contacts OpenStreetMap.
Data © OpenStreetMap contributors, ODbL 1.0 (https://www.openstreetmap.org/copyright).
The ODbL requires this extracted database to be made available under the same licence:
publish the output file (for example as a GitHub release asset) and link it from the app.
"""
import json
import sys
import time
import urllib.parse
import urllib.request

OVERPASS = "https://overpass-api.de/api/interpreter"
QUERY = """
[out:json][timeout:600];
(area["ISO3166-1"="AU"][admin_level=2];area["ISO3166-1"="NZ"][admin_level=2];)->.a;
nwr["tourism"~"^(camp_site|caravan_site)$"](area.a);
out center tags;
"""

# Tags worth showing a hiker or camper (everything else is dropped to keep the file small).
KEEP = [
    "fee", "toilets", "drinking_water", "shower", "showers", "power_supply", "tents", "caravans",
    "motorhome", "backcountry", "capacity", "access", "operator", "dog", "reservation",
    "openfire", "bbq", "camp_site", "description", "website", "group_only", "sanitary_dump_station",
]
SKIP_ACCESS = {"private", "no", "customers_only"}


def main(out_path: str) -> None:
    body = urllib.parse.urlencode({"data": QUERY}).encode()
    req = urllib.request.Request(OVERPASS, data=body, headers={
        "User-Agent": "TopoOffline-build/1.0 (campsite extract for an offline map app)",
    })
    started = time.time()
    with urllib.request.urlopen(req, timeout=900) as resp:
        data = json.load(resp)
    print(f"downloaded {len(data.get('elements', []))} elements in {time.time() - started:.0f} s")

    sites = []
    for e in data.get("elements", []):
        tags = e.get("tags", {})
        if tags.get("access") in SKIP_ACCESS:
            continue
        lat = e.get("lat") or (e.get("center") or {}).get("lat")
        lon = e.get("lon") or (e.get("center") or {}).get("lon")
        if lat is None or lon is None:
            continue
        facts = {k: tags[k][:200] for k in KEEP if k in tags}
        sites.append({
            "i": f"{e['type'][0]}{e['id']}",
            "n": tags.get("name"),
            "t": "v" if tags.get("tourism") == "caravan_site" else "c",
            "a": round(lat, 5),
            "o": round(lon, 5),
            **({"f": facts} if facts else {}),
        })

    out = {
        "generated": time.strftime("%Y-%m-%d"),
        "licence": "Data © OpenStreetMap contributors, ODbL 1.0",
        "sites": sites,
    }
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, separators=(",", ":"))
    named = sum(1 for s in sites if s["n"])
    print(f"wrote {len(sites)} sites ({named} named, "
          f"{sum(1 for s in sites if s['t'] == 'v')} caravan parks) to {out_path}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
