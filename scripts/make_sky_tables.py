#!/usr/bin/env python3
"""Write the two data tables the sky reads (docs/Sky_System.md):

    NeuraLink/App/Resources/sky_zones.txt         time zone -> latitude longitude
    NeuraLink/App/Resources/sky_bright_stars.txt  the bright stars, J2000

Zones: every row of the tz database's zone.tab (public domain), then the older
names iOS still reports for some zones (Asia/Calcutta, Europe/Kiev, ...): any
identifier Foundation knows that zone.tab does not is matched to the zone.tab
entry whose compiled tz file has the same bytes.

Stars: the Yale Bright Star Catalogue, 5th revised edition (Hoffleit & Warren
1991, NASA ADC), every star down to magnitude 3.55: about 300, enough for the
constellations to read. Download bsc5.dat.gz from
http://tdc-www.harvard.edu/catalogs/bsc5.html and pass it unpacked.

Usage (macOS, Xcode installed):
    python3 scripts/make_sky_tables.py <path to bsc5.dat>
"""

import os
import re
import subprocess
import sys
import tempfile

ZONE_TAB = "/usr/share/zoneinfo/zone.tab"
RESOURCES = os.path.join(os.path.dirname(__file__), "..", "NeuraLink", "App", "Resources")
FAINTEST = 3.55

# Old names whose tz file matches more than one zone.tab row.
MANUAL_ALIASES = {
    "America/Montreal": "America/Toronto",
    "America/Nipigon": "America/Toronto",
    "America/Thunder_Bay": "America/Toronto",
    "Pacific/Ponape": "Pacific/Pohnpei",
    "Pacific/Truk": "Pacific/Chuuk",
}


def iso6709(text):
    """'-1855+04731' or '+404251-0740023' -> (latitude, longitude) degrees."""
    match = re.match(r"([+-])(\d+)([+-])(\d+)$", text)

    def part(sign, digits, degree_width):
        degrees = int(digits[:degree_width])
        minutes = int(digits[degree_width:degree_width + 2])
        seconds = int(digits[degree_width + 2:] or 0)
        return (1 if sign == "+" else -1) * (degrees + minutes / 60 + seconds / 3600)

    return part(match.group(1), match.group(2), 2), part(match.group(3), match.group(4), 3)


def known_identifiers():
    """TimeZone.knownTimeZoneIdentifiers, from a throwaway Swift program."""
    with tempfile.TemporaryDirectory() as folder:
        source = os.path.join(folder, "known.swift")
        binary = os.path.join(folder, "known")
        with open(source, "w") as handle:
            handle.write('import Foundation\nprint(TimeZone.knownTimeZoneIdentifiers.joined(separator: "\\n"))\n')
        subprocess.run(["xcrun", "--sdk", "macosx", "swiftc", source, "-o", binary], check=True)
        return subprocess.run([binary], check=True, capture_output=True, text=True).stdout.split()


def zone_rows():
    zones = {}
    with open(ZONE_TAB) as handle:
        for line in handle:
            if line.startswith("#") or not line.strip():
                continue
            _, coordinates, name = line.split("\t")[:3]
            zones[name.strip()] = iso6709(coordinates)

    root = os.path.dirname(ZONE_TAB)

    def contents(name):
        try:
            with open(os.path.join(root, name), "rb") as handle:
                return handle.read()
        except OSError:
            return None

    by_contents = {}
    for name in zones:
        data = contents(name)
        if data:
            by_contents.setdefault(data, []).append(name)
    aliases = dict(MANUAL_ALIASES)
    for name in known_identifiers():
        if name in zones or name in aliases:
            continue
        data = contents(name)
        candidates = by_contents.get(data, []) if data else []
        same_region = [c for c in candidates if c.split("/")[0] == name.split("/")[0]] or candidates
        if same_region and len({zones[c] for c in same_region}) == 1:
            aliases[name] = same_region[0]

    rows = [f"{name} {zones[name][0]:.2f} {zones[name][1]:.2f}" for name in sorted(zones)]
    rows += [f"{name} {zones[target][0]:.2f} {zones[target][1]:.2f}" for name, target in sorted(aliases.items())]
    return rows


def star_rows(path):
    stars = []
    with open(path, encoding="latin-1") as handle:
        for line in handle:
            line = line.rstrip("\n").ljust(197)
            ra, dec, vmag, color = line[75:83], line[83:90], line[102:107], line[109:114]
            if not ra.strip() or not vmag.strip() or float(vmag) > FAINTEST:
                continue
            hours = int(ra[0:2]) + int(ra[2:4]) / 60 + float(ra[4:8]) / 3600
            sign = -1 if dec[0] == "-" else 1
            degrees = sign * (int(dec[1:3]) + int(dec[3:5]) / 60 + int(dec[5:7]) / 3600)
            try:
                b_minus_v = float(color)
            except ValueError:
                b_minus_v = 0.6
            stars.append((float(vmag), hours * 15, degrees, b_minus_v))
    stars.sort()
    return [f"{ra:.3f} {dec:.3f} {vmag:.2f} {bv:.2f}" for vmag, ra, dec, bv in stars]


def write(name, header, rows):
    path = os.path.normpath(os.path.join(RESOURCES, name))
    with open(path, "w") as handle:
        handle.write("\n".join(header + rows) + "\n")
    print(f"{path}: {len(rows)} rows")


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    write("sky_zones.txt", [
        "# Time zone -> latitude longitude (degrees, north and east positive): where",
        "# the sky is drawn for. One row per zone of the tz database's zone.tab",
        "# (public domain), then the older names iOS still reports for some of them.",
        "# Generated by scripts/make_sky_tables.py.",
    ], zone_rows())
    write("sky_bright_stars.txt", [
        "# Right ascension, declination (degrees, J2000), V magnitude, B-V colour",
        f"# index of every star down to magnitude {FAINTEST}, brightest first. From the",
        "# Yale Bright Star Catalogue, 5th revised edition (Hoffleit & Warren 1991).",
        "# Generated by scripts/make_sky_tables.py.",
    ], star_rows(sys.argv[1]))


if __name__ == "__main__":
    main()
