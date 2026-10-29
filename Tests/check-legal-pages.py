#!/usr/bin/env python3
"""Check the offline/deployment contract, including agreement version parity."""
import argparse
from html.parser import HTMLParser
from pathlib import Path
import re
from urllib.parse import unquote, urlsplit
import zipfile


class Document(HTMLParser):
    def __init__(self, source):
        super().__init__(convert_charrefs=True)
        self.tags = []
        self.links = []
        self.ids = set()
        self.meta = {}
        self.language = None
        self.resources = []
        self.feed(source)

    def handle_starttag(self, tag, attributes):
        attrs = dict(attributes)
        self.tags.append(tag)
        if tag == "html":
            self.language = attrs.get("lang")
        if tag == "meta":
            self.meta[attrs.get("name", attrs.get("http-equiv", "")).lower()] = attrs.get("content", "")
        if "id" in attrs:
            assert attrs["id"] not in self.ids, f"duplicate id: {attrs['id']}"
            self.ids.add(attrs["id"])
        if "href" in attrs:
            self.links.append(attrs["href"])
        if tag != "a" and "href" in attrs:
            self.resources.append(attrs["href"])
        for key in ("src", "srcset", "poster"):
            if key in attrs:
                self.resources.append(attrs[key])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle", type=Path, help="also verify the built iPhone .app resources")
    arguments = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    version = re.search(r'currentVersion = "([^"]+)"',
                        (root / "PhoneApp/PrivacyConsentState.swift").read_text()).group(1)
    source = root / "PhoneApp/Legal"
    pages = {name: (source / name).read_text() for name in ("privacy.html", "terms.html", "support.html")}
    documents = {name: Document(text) for name, text in pages.items()}
    for name, document in documents.items():
        assert document.language and document.language.startswith("zh"), name
        assert document.meta.get("document-version") == version, f"version mismatch: {name}"
        assert document.meta.get("viewport"), f"missing viewport: {name}"
        assert "default-src 'none'" in document.meta.get("content-security-policy", ""), name
        assert document.tags.count("h1") == 1 and "title" in document.tags, name
        assert not set(document.tags) & {"script", "iframe", "form", "object", "embed"}, name
        assert not document.resources, f"offline document has external assets: {name}"
        assert not re.search(r"@import|\burl\s*\(", pages[name], re.IGNORECASE), name
        for link in document.links:
            url = urlsplit(link)
            if url.scheme:
                assert url.scheme in ("https", "mailto"), f"unexpected external scheme: {link}"
                continue
            assert not url.netloc, link
            destination = unquote(url.path) or name
            assert destination in documents, f"broken relative link: {name} -> {link}"
            if url.fragment:
                assert unquote(url.fragment) in documents[destination].ids, f"broken anchor: {link}"
    archive = root / f"Artifacts/Deployment/watchmusic-web-{version}.zip"
    with zipfile.ZipFile(archive) as package:
        assert set(package.namelist()) == {"index.html", *pages}, "unexpected deployment files"
        for name in pages:
            assert package.read(name) == (source / name).read_bytes(), f"stale deployment copy: {name}"
        assert package.read("index.html") == package.read("support.html")
    if arguments.bundle:
        for name in pages:
            bundled = next((path for path in (arguments.bundle / "Legal" / name, arguments.bundle / name)
                            if path.is_file()), None)
            assert bundled and bundled.read_bytes() == (source / name).read_bytes(), f"stale/missing app resource: {name}"
    print("PASS: legal versions, offline resources, links/anchors and deployment package" +
          ("; built app documents match" if arguments.bundle else ""))


if __name__ == "__main__":
    main()
