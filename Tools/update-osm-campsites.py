#!/usr/bin/env python3
"""Extract campsites, caravan parks and huts from OpenStreetMap, one file per region.

Run before each app release (one Overpass query per region, well within its usage policy):

    python3 -I Tools/update-osm-campsites.py anz TopoOffline/Resources/osm-campsites.json
    python3 -I Tools/update-osm-campsites.py na TopoOffline/Resources/osm-campsites-na.json
    python3 -I Tools/update-osm-campsites.py europe TopoOffline/Resources/osm-campsites-europe.json

anz: Australia and New Zealand (campsites and caravan parks; NZ huts come from DOC).
na: the United States and Canada (campsites and backcountry huts; caravan parks left out, and
    long descriptions dropped, to keep the file small).
europe: Switzerland and Norway (campsites, caravan parks, alpine and wilderness huts).

The output ships inside the app, so the app itself never contacts OpenStreetMap.
Data © OpenStreetMap contributors, ODbL 1.0 (https://www.openstreetmap.org/copyright).
The ODbL requires this extracted database to be made available under the same licence:
publish the output file (for example as a GitHub release asset) and link it from the app.
"""
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

OVERPASS = "https://overpass-api.de/api/interpreter"
REGIONS = {
    # region: (countries, tourism values, drop descriptions)
    "anz": (["AU", "NZ"], "camp_site|caravan_site", False),
    "na": (["US", "CA"], "camp_site|alpine_hut|wilderness_hut", True),
    "europe": (["CH", "NO"], "camp_site|caravan_site|alpine_hut|wilderness_hut", False),
}


def query(countries, tourism):
    areas = "".join(f'area["ISO3166-1"="{c}"][admin_level=2];' for c in countries)
    return f"""
[out:json][timeout:900];
({areas})->.a;
nwr["tourism"~"^({tourism})$"](area.a);
out center tags;
"""

# Tags worth showing a hiker or camper (everything else is dropped to keep the file small).
KEEP = [
    "fee", "toilets", "drinking_water", "shower", "showers", "power_supply", "tents", "caravans",
    "motorhome", "backcountry", "capacity", "access", "operator", "dog", "reservation",
    "openfire", "bbq", "camp_site", "description", "website", "group_only", "sanitary_dump_station",
]
SKIP_ACCESS = {"private", "no", "customers_only"}


def fetch(countries, tourism):
    """One query per country (the US is too big to combine with another), with a few retries."""
    elements = []
    for country in countries:
        body = urllib.parse.urlencode({"data": query([country], tourism)}).encode()
        for attempt in range(4):
            req = urllib.request.Request(OVERPASS, data=body, headers={
                "User-Agent": "TopoOffline-build/1.0 (campsite extract for an offline map app)",
            })
            started = time.time()
            try:
                with urllib.request.urlopen(req, timeout=1000) as resp:
                    part = json.load(resp).get("elements", [])
                break
            except urllib.error.HTTPError as e:
                if attempt == 3 or e.code not in (429, 502, 503, 504):
                    raise
                print(f"{country}: HTTP {e.code}, retrying in a minute")
                time.sleep(60)
        print(f"{country}: {len(part)} elements in {time.time() - started:.0f} s")
        elements += part
        time.sleep(10)  # be gentle with the shared server
    return elements


def main(region: str, out_path: str) -> None:
    countries, tourism, drop_descriptions = REGIONS[region]
    elements = fetch(countries, tourism)

    sites = []
    for e in elements:
        tags = e.get("tags", {})
        if tags.get("access") in SKIP_ACCESS:
            continue
        lat = e.get("lat") or (e.get("center") or {}).get("lat")
        lon = e.get("lon") or (e.get("center") or {}).get("lon")
        if lat is None or lon is None:
            continue
        facts = {k: tags[k][:200] for k in KEEP if k in tags and not (drop_descriptions and k == "description")}
        kind = {"caravan_site": "v", "alpine_hut": "h", "wilderness_hut": "h"}.get(tags.get("tourism"), "c")
        sites.append({
            "i": f"{e['type'][0]}{e['id']}",
            "n": tags.get("name"),
            "t": kind,
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
          f"{sum(1 for s in sites if s['t'] == 'v')} caravan parks, "
          f"{sum(1 for s in sites if s['t'] == 'h')} huts) to {out_path}")


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] not in REGIONS:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
