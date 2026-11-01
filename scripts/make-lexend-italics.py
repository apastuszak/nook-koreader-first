#!/usr/bin/env python3
# Turns Lexend's slanted OTFs into a proper italic style of the upright family, so
# KOReader (FreeType/crengine) offers them as the family's italics instead of extra
# upright fonts.
#
#   python3 make-lexend-italics.py <folder with Lexend-aalt-<Weight>-Slanted.otf> <output folder>
#
# Only metadata changes: the name table (family and style names, full name, PostScript
# name, unique ID), the CFF table's names, OS/2 fsSelection (italic on, regular off) and
# head.macStyle (italic on). Glyphs, metrics and the italic angle are left as they are.
# Needs fontTools (pip install fonttools); not needed to build or install anything else.
#
# The fonts are under the SIL Open Font License 1.1, whose Reserved Font Name is
# "RevReading Lexend"; this script never uses that name.
#
# SPDX-License-Identifier: AGPL-3.0-or-later
import os
import sys

from fontTools.ttLib import TTFont

FAMILY = "Lexend-aalt"
WEIGHTS = ["Thin", "ExtraLight", "Light", "Regular", "Medium", "SemiBold", "Bold", "ExtraBold", "Black"]


def italic_names(weight):
    """Name table entries for the italic of `weight`, in the same scheme as the uprights:
    Regular and Bold share the family name (RIBBI); other weights get their own legacy
    family plus a typographic family (IDs 16 and 17)."""
    style = "Italic" if weight == "Regular" else weight + " Italic"
    postscript = f"{FAMILY}-{'' if weight == 'Regular' else weight}Italic"
    names = {
        4: f"{FAMILY} {style}",
        6: postscript,
    }
    if weight in ("Regular", "Bold"):
        names[1] = FAMILY
        names[2] = style
    else:
        names[1] = f"{FAMILY} {weight}"
        names[2] = "Italic"
        names[16] = FAMILY
        names[17] = style
    return names


def convert(src, dst, weight):
    font = TTFont(src)
    if "fvar" in font or "CFF " not in font:
        sys.exit(f"{src}: expected a static CFF-based OTF")
    if font["post"].italicAngle >= 0:
        sys.exit(f"{src}: not slanted (italic angle {font['post'].italicAngle})")

    name = font["name"]
    names = italic_names(weight)
    version = str(name.getName(3, 3, 1, 0x409)).split(";")[0]
    names[3] = f"{version};NONE;{names[6]}"
    for record_id in (16, 17):
        if record_id not in names:
            name.removeNames(nameID=record_id)
    platforms = {(r.platformID, r.platEncID, r.langID) for r in name.names} or {(3, 1, 0x409)}
    for name_id, text in names.items():
        for platform in platforms:
            name.setName(text, name_id, *platform)

    cff = font["CFF "].cff
    cff.fontNames = [names[6]]
    top = cff.topDictIndex[0]
    top.FullName = names[4]
    top.FamilyName = names[16] if 16 in names else names[1]

    os2 = font["OS/2"]
    os2.fsSelection = (os2.fsSelection | 0x01) & ~0x40  # ITALIC on, REGULAR off
    font["head"].macStyle |= 0x02  # italic
    font.save(dst)


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__ or "usage: make-lexend-italics.py <input folder> <output folder>")
    src_dir, dst_dir = sys.argv[1:]
    os.makedirs(dst_dir, exist_ok=True)
    for weight in WEIGHTS:
        src = os.path.join(src_dir, f"{FAMILY}-{weight}-Slanted.otf")
        dst = os.path.join(dst_dir, f"{FAMILY}-{'' if weight == 'Regular' else weight}Italic.otf")
        convert(src, dst, weight)
        print(f"{os.path.basename(src)} -> {os.path.basename(dst)}")


if __name__ == "__main__":
    main()
