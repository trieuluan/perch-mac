#!/usr/bin/env python3
"""Writes Perch's Sparkle appcast: the new release first, then up to 9 earlier
releases carried over from the previous appcast."""

import argparse
import email.utils
import os
import re
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)


def sparkle(tag):
    return f"{{{SPARKLE}}}{tag}"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    parser.add_argument("--previous")
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--url", required=True)
    parser.add_argument("--signature-attrs", required=True,
                        help='sign_update output: sparkle:edSignature="..." length="..."')
    parser.add_argument("--release-notes", required=True)
    parser.add_argument("--minimum-system", default="14.0")
    args = parser.parse_args()

    attrs = dict(re.findall(r'([\w:]+)="([^"]*)"', args.signature_attrs))
    signature = attrs.get("sparkle:edSignature")
    length = attrs.get("length")
    if not signature or not length:
        raise SystemExit(f"could not parse sign_update output: {args.signature_attrs!r}")

    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "Perch"
    ET.SubElement(channel, "link").text = "https://github.com/trieuluan/perch-mac"
    ET.SubElement(channel, "description").text = "Perch updates"

    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = f"Perch {args.version}"
    ET.SubElement(item, "pubDate").text = email.utils.formatdate(usegmt=True)
    ET.SubElement(item, sparkle("version")).text = args.build
    ET.SubElement(item, sparkle("shortVersionString")).text = args.version
    ET.SubElement(item, sparkle("minimumSystemVersion")).text = args.minimum_system
    ET.SubElement(item, sparkle("releaseNotesLink")).text = args.release_notes
    ET.SubElement(item, "enclosure", {
        "url": args.url,
        "length": length,
        "type": "application/octet-stream",
        sparkle("edSignature"): signature,
    })

    if args.previous and os.path.exists(args.previous):
        old_channel = ET.parse(args.previous).getroot().find("channel")
        if old_channel is not None:
            for old_item in old_channel.findall("item")[:9]:
                if old_item.findtext(sparkle("shortVersionString")) != args.version:
                    channel.append(old_item)

    ET.indent(rss)
    ET.ElementTree(rss).write(args.output, encoding="utf-8", xml_declaration=True)


if __name__ == "__main__":
    main()
