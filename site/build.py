#!/usr/bin/env python3
"""Build site/index.html from the design canvas artboard.

The page and the canvas share one source. `design/Main.dc.html` is authored for
the Claude Design canvas, which imposes three things a real page cannot keep:
a `<x-dc>`/`<helmet>` wrapper, its own `support.js`, and image references as
bare filenames. This script strips those, gives the inline grids class hooks so
media queries can reach them, and adds the responsive layer.

Run it after editing the artboard:

    python3 site/build.py

It rewrites site/index.html in place and prints what it changed.
"""

from pathlib import Path
import hashlib
import html
import json
import re
import struct
import sys

ROOT = Path(__file__).resolve().parent
ARTBOARD = ROOT / "design" / "Main.dc.html"
OUTPUT = ROOT / "index.html"

SITE_URL = "https://usespender.com/"
REPO_URL = "https://github.com/bestmark1/spender"
# Always the newest release: the DMG keeps one name across versions.
DOWNLOAD_URL = f"{REPO_URL}/releases/latest/download/Spender.dmg"
VERSION = "0.1.0"


def versioned(relative: str) -> str:
    """The asset path with a short hash of its contents as a query string.

    Screenshots keep their filenames when they are retaken, and browsers were
    still showing the old ones after a deploy. A changed file now gets a new
    URL, so no cache can hold on to it.
    """
    digest = hashlib.sha256((ROOT / relative).read_bytes()).hexdigest()[:10]
    return f"{relative}?v={digest}"

# Inline `grid-template-columns` cannot be overridden by a media query, so each
# grid trades its inline style for a class.
GRID_CLASSES = [
    (
        '<div style="display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 16px;">',
        '<div class="grid grid-provenance">',
    ),
    (
        '<div style="display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 24px; margin-top: 38px;">',
        '<div class="grid grid-compare">',
    ),
    (
        '<div style="display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 10px;">',
        '<div class="grid grid-capability">',
    ),
    (
        '<div style="display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 44px;">',
        '<div class="grid grid-principles">',
    ),
]

SCREENSHOTS = ("panel-today-520", "panel-30days-520", "panel-deepseek-expanded-520")

# Section spacing is written inline on each `.wrap`, where a media query cannot
# reach it. Rewriting it as custom properties lets the phone scale every section
# by one factor instead of restating each number — and a section deliberately
# set to 0 stays 0, because zero scaled is still zero.
WRAP_TAG = re.compile(r'<div\b[^>]*class="wrap"[^>]*>')
WRAP_PAD = re.compile(r'padding-(top|bottom):\s*(\d+)px')

RESPONSIVE = """
    /* --- Grids lifted out of inline styles so media queries can reach them --- */
    .grid { display: grid; }
    .grid-provenance  { grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 16px; }
    .grid-compare     { grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 24px; margin-top: 38px; }
    .grid-capability  { grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 10px; }
    .grid-principles  { grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 44px; }

    img { max-width: 100%; }

    .btn-watch { display: none; }

    /* Section spacing comes from the artboard as --pad-top / --pad-bottom. */
    .wrap { padding-top: var(--pad-top, 0); padding-bottom: var(--pad-bottom, 0); }

    /* --- Tablet --- */
    @media (max-width: 900px) {
      .wrap {
        padding-left: 32px;
        padding-right: 32px;
        padding-top: calc(var(--pad-top, 0px) * 0.75);
        padding-bottom: calc(var(--pad-bottom, 0px) * 0.75);
      }
      .row { gap: 44px; }
      .grid-provenance { grid-template-columns: repeat(2, minmax(0, 1fr)); }
      .grid-principles { grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 32px; }
      h1 { font-size: 46px !important; }
      .cta-band { padding: 40px 36px !important; }
    }

    /* --- Phone: one column throughout, following the Mobile 390 artboard --- */
    @media (max-width: 620px) {
      .wrap { padding-left: 20px; padding-right: 20px; }
      /* The desktop breathing room came over verbatim: 1192px of vertical
         padding on a 375px screen, a screen and a half of nothing. Scaled
         rather than replaced, so the proportions the design set survive. */
      .wrap {
        padding-top: calc(var(--pad-top, 0px) * 0.5);
        padding-bottom: calc(var(--pad-bottom, 0px) * 0.5);
      }
      .row { gap: 32px; }
      .grid-provenance,
      .grid-compare,
      .grid-capability,
      .grid-principles { grid-template-columns: minmax(0, 1fr); gap: 16px; }
      h1 { font-size: 34px !important; line-height: 1.08 !important; }
      h2 { font-size: 27px !important; }
      .lede { font-size: 17px; }

      /* The callouts are positioned as a percentage of the screenshot column.
         On a phone that column is narrow enough to push them off the edge. */
      .note { display: none !important; }

      /* The wordmark and the nav links shared one row with space-between. At
         375px "How it works" wrapped to two lines and sat 16px on top of the
         product's own name. On a single-column page the scroll is the
         navigation, so the section links stand down and GitHub — the only one
         that leaves the page — stays. */
      .nav-secondary { display: none; }

      /* These eight marks answer the one question a phone visitor has — is my
         provider here — and they answer it before anything else on the page.
         At 21px they read as speckle. A grid rather than a wrapping flex row:
         left to wrap, eight marks break 7 + 1 and the last one looks dropped. */
      .provider-row {
        display: grid;
        grid-template-columns: repeat(4, minmax(0, 1fr));
        justify-items: center;
        gap: 20px 12px;
        margin-top: 30px;
      }
      .provider-mark { width: 30px; height: 30px; opacity: 0.8; }

      /* The requirements line is four items long and lands a few pixels past the
         column, which drops "· MIT" onto a line of its own. A point smaller and
         it fits; the inline font-size is why this needs !important. */
      .meta-line { font-size: 12px !important; letter-spacing: -0.01em; }

      /* The button does not wrap and its label is wider than a phone, so on a
         narrow screen it takes the column instead of widening the page. */
      .btn-download { display: none !important; }
      .btn {
        display: flex;
        width: 100%;
        justify-content: center;
        text-align: center;
        padding: 14px 18px;
      }

      /* The last desktop row still standing. Two columns of 146px and 149px
         inside 335px broke every link in the right-hand one across two lines —
         "MIT License" split in half. One column, left-aligned like everything
         above it, and the links wrap as a row instead of a column of stumps. */
      .site-footer { display: block !important; }
      .site-footer-meta {
        align-items: flex-start !important;
        margin-top: 26px;
      }
      .site-footer-links { flex-wrap: wrap; gap: 18px !important; }

      /* 60px of side padding on a 335px column left the closing row no room to
         wrap, and it pushed the page sideways. */
      .cta-band {
        display: block !important;
        padding: 30px 22px !important;
      }
      .cta-band > div { margin-bottom: 22px; }

      /* The FAQ card kept its 30px desktop sides, which left the answers a
         narrow column on a phone. */
      .faq { padding: 2px 22px !important; }
    }
"""

TITLE = "Spender — every LLM API bill in one macOS menu bar panel"
# Under 160 characters, so search results show it whole.
DESCRIPTION = (
    "Free, open source macOS menu bar app that tracks LLM API spend from "
    "OpenAI, Anthropic, DeepSeek, xAI and more. Keys stay in the Keychain."
)
SOCIAL_DESCRIPTION = (
    "Free and open source. Reads official spend from your providers. "
    "Keys stay in the macOS Keychain — no account, no server."
)

HEAD = f"""<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{TITLE}</title>
<meta name="description" content="{DESCRIPTION}">
<link rel="icon" href="{versioned("assets/spender-icon-160.png")}" type="image/png">
<link rel="canonical" href="{SITE_URL}">

<meta property="og:type" content="website">
<meta property="og:title" content="{TITLE}">
<meta property="og:description" content="{SOCIAL_DESCRIPTION}">
<meta property="og:image" content="{SITE_URL}{versioned("assets/og-image.png")}">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:image:alt" content="The Spender menu bar panel beside the line: every LLM API bill, in one menu bar panel.">
<meta property="og:url" content="{SITE_URL}">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="{TITLE}">
<meta name="twitter:description" content="{SOCIAL_DESCRIPTION}">
<meta name="twitter:image" content="{SITE_URL}{versioned("assets/og-image.png")}">"""


def fail(message: str) -> None:
    print(f"build.py: {message}", file=sys.stderr)
    raise SystemExit(1)


def webp_size(path: Path) -> tuple[int, int]:
    """Pixel size of a WebP, read from its header.

    The deploy runner has plain Python and no imaging library, so this reads
    the three header layouts WebP uses instead of adding a dependency.
    """
    data = path.read_bytes()[:30]
    if data[:4] != b"RIFF" or data[8:12] != b"WEBP":
        fail(f"not a WebP file: {path}")
    chunk = data[12:16]
    if chunk == b"VP8X":
        width = 1 + int.from_bytes(data[24:27], "little")
        height = 1 + int.from_bytes(data[27:30], "little")
    elif chunk == b"VP8L":
        bits = int.from_bytes(data[21:25], "little")
        width = 1 + (bits & 0x3FFF)
        height = 1 + ((bits >> 14) & 0x3FFF)
    elif chunk == b"VP8 ":
        width, height = struct.unpack("<HH", data[26:30])
        width &= 0x3FFF
        height &= 0x3FFF
    else:
        fail(f"unknown WebP layout {chunk!r} in {path}")
    return width, height


FAQ_ITEM = re.compile(
    r'<h3 class="faq-q">(.*?)</h3>\s*<p class="faq-a">(.*?)</p>', re.S
)


def plain(fragment: str) -> str:
    return " ".join(html.unescape(re.sub(r"<[^>]+>", "", fragment)).split())


def structured_data(body: str) -> str:
    """JSON-LD for the app, the site and the FAQ.

    Only what the page itself says: no rating, reviews or download URL,
    because there are none yet. The FAQ entries are read from the page's own
    FAQ section, so the markup cannot drift from the visible answers.
    """
    faq = [(plain(q), plain(a)) for q, a in FAQ_ITEM.findall(body)]
    if not faq:
        fail("no FAQ items found — the FAQPage markup would be empty")
    graph = {
        "@context": "https://schema.org",
        "@graph": [
            {
                "@type": "WebSite",
                "@id": f"{SITE_URL}#website",
                "name": "Spender",
                "url": SITE_URL,
                "inLanguage": "en",
            },
            {
                "@type": "SoftwareApplication",
                "@id": f"{SITE_URL}#app",
                "name": "Spender",
                "url": SITE_URL,
                "description": DESCRIPTION,
                "applicationCategory": "DeveloperApplication",
                "operatingSystem": "macOS 14 or later",
                "isAccessibleForFree": True,
                "softwareVersion": VERSION,
                "downloadUrl": DOWNLOAD_URL,
                "offers": {"@type": "Offer", "price": "0", "priceCurrency": "USD"},
                "license": f"{REPO_URL}/blob/main/LICENSE",
                "image": f"{SITE_URL}assets/spender-icon-160.png",
                "screenshot": f"{SITE_URL}assets/screenshots/panel-today.png",
                "sameAs": [REPO_URL],
                "author": {
                    "@type": "Person",
                    "name": "bestmark1",
                    "url": "https://github.com/bestmark1",
                },
            },
            {
                "@type": "FAQPage",
                "@id": f"{SITE_URL}#faq",
                "mainEntity": [
                    {
                        "@type": "Question",
                        "name": question,
                        "acceptedAnswer": {"@type": "Answer", "text": answer},
                    }
                    for question, answer in faq
                ],
            },
        ],
    }
    return (
        '<script type="application/ld+json">\n'
        + json.dumps(graph, ensure_ascii=False, indent=2)
        + "\n</script>"
    )


def split_artboard(source: str) -> tuple[str, str]:
    """Return (head contents, body contents) from the canvas wrappers."""
    for marker in ("<helmet>", "</helmet>", "</x-dc>"):
        if source.count(marker) != 1:
            fail(f"expected exactly one {marker} in the artboard")

    helmet = source.split("<helmet>", 1)[1].split("</helmet>", 1)[0]
    body = source.split("</helmet>", 1)[1].split("</x-dc>", 1)[0]
    return helmet.strip(), body.strip()


def main() -> None:
    if not ARTBOARD.exists():
        fail(f"artboard not found: {ARTBOARD}")

    helmet, body = split_artboard(ARTBOARD.read_text())

    for old, new in GRID_CLASSES:
        if body.count(old) != 1:
            fail(f"grid markup changed, cannot rewrite: {old[:60]}…")
        body = body.replace(old, new)

    def to_custom_properties(match: re.Match[str]) -> str:
        return WRAP_PAD.sub(
            lambda m: f"--pad-{m.group(1)}: {m.group(2)}px",
            match.group(0),
        )

    body, wraps_rewritten = WRAP_TAG.subn(to_custom_properties, body)
    if wraps_rewritten == 0:
        fail("no .wrap sections found — section spacing would not scale")

    icon = versioned("assets/spender-icon-160.png")
    body = body.replace('src="spender-icon-160.png"', f'src="{icon}"')
    for index, shot in enumerate(SCREENSHOTS):
        path = f"assets/screenshots/{shot}.webp"
        width, height = webp_size(ROOT / path)
        # Declared size keeps the layout from jumping while images load; the
        # two below the fold wait until they are near the viewport.
        extra = f' width="{width}" height="{height}" decoding="async"'
        if index > 0:
            extra += ' loading="lazy"'
        body = body.replace(f'src="{shot}.webp"', f'src="{versioned(path)}"{extra}')

    # A phone cannot install a Mac app, so there each download button gives
    # way to a link to the repository; CSS picks one per screen size.
    download_open = f'<a class="btn" href="{DOWNLOAD_URL}">'
    downloads = body.count(download_open)
    if downloads == 0:
        fail("no download button found in the artboard")
    body = body.replace(download_open, f'<a class="btn btn-download" href="{DOWNLOAD_URL}">')
    body = re.sub(
        r'(<a class="btn btn-download".*?</a>)',
        lambda m: m.group(1)
        + f'\n<a class="btn btn-watch" href="{REPO_URL}">View on GitHub — for your Mac</a>',
        body,
        flags=re.S,
    )

    if "support.js" in body or "<x-dc" in body:
        fail("canvas machinery leaked into the page body")

    page = (
        "<!doctype html>\n<html lang=\"en\">\n<head>\n"
        f"{HEAD}\n{structured_data(body)}\n{helmet}\n<style>{RESPONSIVE}</style>\n"
        f"</head>\n<body>\n{body}\n</body>\n</html>\n"
    )
    OUTPUT.write_text(page)
    print(
        f"wrote {OUTPUT.relative_to(ROOT.parent)} — "
        f"{len(page.splitlines())} lines, {len(GRID_CLASSES)} grids classed, "
        f"{downloads} download button(s) with a phone fallback"
    )


if __name__ == "__main__":
    main()
