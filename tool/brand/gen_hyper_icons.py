#!/usr/bin/env python3
"""Generates assets/fonts/HyperMaterialIcons.otf for the soft-light material.

It is Flutter's MaterialIcons font with the glyphs in MAPPING replaced by HyperOS symbols, so every existing
`Icons.x` shows the HyperOS symbol without touching its call site. The font is registered at run time under the
family name 'MaterialIcons' (see lib/ui/widgets/hyper_icons.dart). Anything not mapped keeps its Material glyph.

Sources are the fonts inside a ROM dump: python gen_hyper_icons.py <apk dir> <flutter sdk> <output> [sheet.png]
"""
import pathlib
import re
import sys

from fontTools.misc.transform import Transform
from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.recordingPen import DecomposingRecordingPen
from fontTools.pens.t2CharStringPen import T2CharStringPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTFont
from fontTools.varLib import instancer

WEIGHT = 330  # the default of the variable fonts, which is what the system draws

M, C, L = "misymbol", "content", "layout"

# Material name -> (font, glyph[, turn]). turn = 1 rotates by 90 degrees.
MAPPING = {
    "add_rounded": (M, "add"),
    "arrow_back_rounded": (M, "back"),
    "bedtime_rounded": (C, "sleep_surface"),
    "bedtime_outlined": (C, "sleep_surface"),
    "cast_rounded": (C, "screen_casting_surface"),
    "cast_connected_rounded": (C, "screen_casting_surface"),
    "check_rounded": (M, "ok"),
    "chevron_left_rounded": (M, "chevron_backward"),
    "chevron_right_rounded": (M, "chevron_forward"),
    "close_rounded": (M, "close"),
    "computer_rounded": (C, "computer_surface"),
    "laptop_rounded": (C, "computer_surface"),
    "content_copy_rounded": (M, "copy"),
    "delete_outline_rounded": (M, "delete"),
    "delete_rounded": (M, "delete"),
    "delete_sweep_rounded": (M, "delete"),
    "devices_rounded": (C, "device_surface"),
    "devices_other_rounded": (C, "device_surface"),
    "directions_car_rounded": (C, "car_surface"),
    "download_rounded": (M, "download"),
    "error_outline_rounded": (C, "error_line"),
    "error_rounded": (C, "error_surface"),
    "folder_open_rounded": (M, "folder"),
    "format_list_bulleted_rounded": (M, "list_view"),
    "view_list_rounded": (M, "list_view"),
    "grid_view_rounded": (M, "grid_view"),
    "headphones_rounded": (C, "earphones_surface"),
    "history_rounded": (M, "recent"),
    "home_outlined": (C, "home_screen_surface"),
    "home_filled": (C, "home_screen_surface"),
    "info_outline_rounded": (M, "info"),
    "info_rounded": (M, "info"),
    "ios_share_rounded": (M, "share"),
    "key_rounded": (C, "key_surface"),
    "library_music_outlined": (M, "playlist"),
    "library_music_rounded": (M, "playlist"),
    "link_rounded": (M, "link"),
    "lock_outline_rounded": (M, "lock"),
    "lock_rounded": (M, "lock"),
    "menu_rounded": (M, "menu"),
    "more_horiz_rounded": (M, "more"),
    "more_vert_rounded": (M, "more", 1),
    "music_note_rounded": (M, "music"),
    "playlist_play_rounded": (M, "playlist"),
    "push_pin_outlined": (M, "pin"),
    "push_pin_rounded": (M, "pin"),
    "queue_music_rounded": (M, "playlist"),
    "refresh_rounded": (M, "refresh"),
    "restart_alt_rounded": (M, "reset"),
    "search_rounded": (M, "search"),
    "settings_suggest_rounded": (M, "settings"),
    "sort_rounded": (M, "sort"),
    "storage_rounded": (C, "data_surface"),
    "swap_vert_rounded": (M, "sort"),
    "sync_rounded": (M, "refresh"),
    "tablet_rounded": (C, "pad_device_line"),
    "translate_rounded": (M, "translate"),
    "tv_rounded": (C, "tv_surface"),
    "update_rounded": (M, "update"),
    "view_sidebar_outlined": (M, "sidebar"),
    "view_sidebar_rounded": (M, "sidebar"),
    "volume_down_rounded": (M, "volume_up"),
    "volume_mute_rounded": (M, "volume_up"),
    "volume_off_rounded": (M, "volume_off"),
    "volume_up_rounded": (M, "volume_up"),
    "warning_amber_rounded": (C, "error_line"),
    "watch_rounded": (C, "xiaomi_watch_round_surface"),
    "cloud_off_rounded": (C, "no_network_surface"),
    "wifi_off_rounded": (C, "no_network_surface"),
    "schedule_rounded": (M, "recent"),
    "person_outline_rounded": (M, "contacts"),
    "person_rounded": (M, "contacts"),
    "smartphone_rounded": (C, "my_device_surface"),
    "expand_more_rounded": (M, "chevron_forward", 1),
    "keyboard_arrow_down_rounded": (M, "chevron_forward", 1),
    "expand_less_rounded": (M, "chevron_backward", 1),
    "keyboard_arrow_up_rounded": (M, "chevron_backward", 1),
}


def codepoints(sdk):
    text = (sdk / "packages/flutter/lib/src/material/icons.dart").read_text("utf-8")
    return {m[0]: int(m[1], 16) for m in re.findall(r"static const IconData (\w+) = IconData\(\s*(0x[0-9a-f]+)", text)}


def main():
    apk, sdk, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3])
    sheet = pathlib.Path(sys.argv[4]) if len(sys.argv) > 4 else None
    fonts_dir = apk / "MIUIGallery/resources/assets/flutter_assets/packages/hyperos/fonts"
    sources = {}
    for key, path in {
        M: apk / "MIUIDeskClock/resources/assets/fonts/misymbol_vf.ttf",
        C: fonts_dir / "HyperOSSymbols-Content-RegularVF.ttf",
        L: fonts_dir / "HyperOSSymbols-LayoutVF.ttf",
    }.items():
        sources[key] = instancer.instantiateVariableFont(TTFont(path), {"wght": WEIGHT})

    base = TTFont(sdk / "bin/cache/artifacts/material_fonts/materialicons-regular.otf")
    assert "CFF " in base, "expected a CFF font"
    cff = base["CFF "].cff
    top = cff.topDictIndex[0]
    chars = top.CharStrings
    cmap = base.getBestCmap()
    glyphs = base.getGlyphSet()
    codes = codepoints(sdk)
    done = []
    for name, spec in MAPPING.items():
        font_key, glyph = spec[0], spec[1]
        turn = len(spec) > 2
        src = sources[font_key]
        src_set = src.getGlyphSet()
        target = cmap[codes[name]]

        old = BoundsPen(glyphs)
        glyphs[target].draw(old)
        new = BoundsPen(src_set)
        src_set[glyph].draw(new)
        (ox0, oy0, ox1, oy1), (nx0, ny0, nx1, ny1) = old.bounds, new.bounds
        if turn:
            nw, nh = ny1 - ny0, nx1 - nx0
        else:
            nw, nh = nx1 - nx0, ny1 - ny0
        # the symbol keeps its own proportions and takes the space the Material glyph had
        scale = max(ox1 - ox0, oy1 - oy0) / max(nw, nh)
        cx, cy = (ox0 + ox1) / 2, (oy0 + oy1) / 2
        t = Transform().translate(cx, cy).scale(scale)
        if turn:
            t = t.rotate(-3.14159265358979 / 2)
        t = t.translate(-(nx0 + nx1) / 2, -(ny0 + ny1) / 2)

        record = DecomposingRecordingPen(src_set)
        src_set[glyph].draw(record)
        pen = T2CharStringPen(glyphs[target].width, None, roundTolerance=0.5)
        record.replay(TransformPen(pen, t))
        fresh = pen.getCharString(private=chars[target].private, globalSubrs=chars[target].globalSubrs)
        chars[target] = fresh
        done.append((name, target))

    out.parent.mkdir(parents=True, exist_ok=True)
    base.save(out)
    print(f"{len(done)} glyphs replaced, {out.stat().st_size // 1024} KB")

    if sheet:
        from PIL import Image, ImageDraw, ImageFont

        material = ImageFont.truetype(str(sdk / "bin/cache/artifacts/material_fonts/materialicons-regular.otf"), 40)
        patched = ImageFont.truetype(str(out), 40)
        label = ImageFont.load_default()
        cols, cell_w, cell_h = 6, 150, 74
        rows = (len(done) + cols - 1) // cols
        img = Image.new("RGB", (cols * cell_w, rows * cell_h), "white")
        d = ImageDraw.Draw(img)
        for i, (name, _) in enumerate(done):
            x, y = (i % cols) * cell_w, (i // cols) * cell_h
            ch = chr(codes[name])
            d.text((x + 8, y + 4), ch, font=material, fill="#888888")
            d.text((x + 58, y + 4), ch, font=patched, fill="black")
            d.text((x + 6, y + 56), name.replace("_rounded", "")[:24], font=label, fill="#c0392b")
        img.save(sheet)


if __name__ == "__main__":
    main()
