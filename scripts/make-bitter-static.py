#!/usr/bin/env python3
# Makes static TTFs of Bitter from its variable fonts, one per named weight, because
# KOReader (FreeType/crengine) uses only a variable font's default instance, which for
# Bitter is Thin.
#
#   python3 make-bitter-static.py <folder with Bitter[wght].ttf and Bitter-Italic[wght].ttf> <output folder>
#
# Each named instance in the fonts' fvar table (Thin to Black, upright and italic) is
# instantiated with fontTools, which also updates the names from the STAT table and sets
# the weight class and style bits; outlines are not otherwise changed. The PostScript name
# and unique ID are then set from the instance's own PostScript name, since fontTools
# builds them from the italic font's "BitterItalic" prefix. Needs fontTools
# (pip install fonttools); not needed to build or install anything else.
#
# The fonts are under the SIL Open Font License 1.1, whose Reserved Font Name is "Bitter
# Pro"; the fonts are named "Bitter", as upstream's are, and this script keeps that name.
#
# SPDX-License-Identifier: AGPL-3.0-or-later
import os
import sys

from fontTools.ttLib import TTFont
from fontTools.varLib import instancer

SOURCES = ["Bitter[wght].ttf", "Bitter-Italic[wght].ttf"]


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: make-bitter-static.py <input folder> <output folder>")
    src_dir, dst_dir = sys.argv[1:]
    os.makedirs(dst_dir, exist_ok=True)
    for source in SOURCES:
        path = os.path.join(src_dir, source)
        font = TTFont(path)
        name = font["name"]
        for instance in font["fvar"].instances:
            postscript = name.getDebugName(instance.postscriptNameID)
            static = instancer.instantiateVariableFont(
                TTFont(path), instance.coordinates, updateFontNames=True)
            names = static["name"]
            version = names.getDebugName(3).split(";")[0]
            for record in list(names.names):
                if record.nameID == 6:
                    names.setName(postscript, 6, record.platformID, record.platEncID, record.langID)
                elif record.nameID == 3:
                    names.setName(f"{version};NONE;{postscript}", 3, record.platformID, record.platEncID, record.langID)
            dst = os.path.join(dst_dir, postscript + ".ttf")
            static.save(dst)
            print(f"{source} {instance.coordinates} -> {os.path.basename(dst)}")


if __name__ == "__main__":
    main()
