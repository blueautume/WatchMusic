#!/usr/bin/env python3
"""Check shipped localization coverage, format contracts, and offline legal pages.

Run without arguments for source checks; add --bundle PATH to inspect built
iPhone/Watch apps too. The iPhone app's embedded Watch app is checked automatically.
"""

from __future__ import annotations

import argparse
import json
import plistlib
import re
import subprocess
from collections import Counter
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlsplit


ROOT = Path(__file__).resolve().parents[1]
LANGUAGES = ("en", "zh-Hans")
HAN = re.compile(r"[\u3400-\u9fff]")
FORMAT = re.compile(r"%(?:(\d+)\$)?[-+ #0]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(hh|ll|[hlLzjt])?([@diuoxXfFeEgGaAcCsSp])")
PREVIEW_DATA = {
    "Music/UI预览/测试旋律.flac", "夜跑歌单", "夜空中的旋律.flac",
    "海风与落日.mp3", "城市漫步.flac", "晴天的远方.mp3",
    "山间回声.flac", "雨后散步.mp3", "晚风轻拂.flac",
}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def read_plist(path: Path) -> dict:
    require(path.is_file(), f"Missing resource: {path}")
    data = path.read_bytes()
    try:
        return plistlib.loads(data)
    except plistlib.InvalidFileException:
        # Apple's .strings and .pbxproj use the OpenStep plist syntax.
        converted = subprocess.run(
            ["plutil", "-convert", "json", "-o", "-", str(path)],
            capture_output=True, text=True, check=True,
        )
        return json.loads(converted.stdout)


def placeholders(value: str) -> Counter:
    """Compare argument positions and ABI types, allowing translation reordering."""
    tokens = Counter()
    sequential = 0
    cursor = 0
    while cursor < len(value):
        if value[cursor:cursor + 2] == "%%":
            cursor += 2
            continue
        match = FORMAT.match(value, cursor)
        if match:
            sequential += 1
            position = int(match[1]) if match[1] else sequential
            tokens[(position, (match[2] or "") + match[3])] += 1
            cursor = match.end()
        else:
            cursor += 1
    return tokens


def decode_swift(value: str) -> str:
    escapes = {"n": "\n", "r": "\r", "t": "\t", "0": "\0", '"': '"', "\\": "\\"}
    return re.sub(
        r"\\(?:u\{([0-9a-fA-F]+)\}|([nrt0\"\\]))",
        lambda match: chr(int(match[1], 16)) if match[1] else escapes[match[2]],
        value,
    )


def swift_literals(source: str):
    """Yield real Swift literals, excluding comments and interpolation expressions.

    An interpolation is represented by a NUL marker. Its nested strings and
    balanced parentheses are consumed so a quoted fallback inside an expression
    cannot be mistaken for a separate user-facing label.
    """
    cursor = 0
    nested = []

    def string_at(start: int):
        triple = source.startswith('"""', start)
        delimiter = '"""' if triple else '"'
        pos = start + len(delimiter)
        pieces = []
        while pos < len(source):
            if source.startswith(delimiter, pos):
                return "".join(pieces), pos + len(delimiter)
            if source.startswith("\\(", pos):
                depth, pos = 1, pos + 2
                while pos < len(source) and depth:
                    if source[pos] == '"':
                        nested_start = pos
                        nested_value, pos = string_at(pos)
                        nested.append((decode_swift(nested_value), source.count("\n", 0, nested_start) + 1))
                    elif source[pos] == "(":
                        depth, pos = depth + 1, pos + 1
                    elif source[pos] == ")":
                        depth, pos = depth - 1, pos + 1
                    else:
                        pos += 1
                pieces.append("\0")
            elif source[pos] == "\\" and pos + 1 < len(source):
                pieces.append(source[pos:pos + 2])
                pos += 2
            else:
                pieces.append(source[pos])
                pos += 1
        raise AssertionError("Unterminated Swift string literal")

    while cursor < len(source):
        if source.startswith("//", cursor):
            newline = source.find("\n", cursor)
            cursor = len(source) if newline < 0 else newline + 1
        elif source.startswith("/*", cursor):
            depth, cursor = 1, cursor + 2
            while cursor < len(source) and depth:
                if source.startswith("/*", cursor):
                    depth, cursor = depth + 1, cursor + 2
                elif source.startswith("*/", cursor):
                    depth, cursor = depth - 1, cursor + 2
                else:
                    cursor += 1
        elif source[cursor] == '"':
            start = cursor
            value, cursor = string_at(cursor)
            yield from nested
            nested.clear()
            yield decode_swift(value), source.count("\n", 0, start) + 1
        else:
            cursor += 1


def normalized(value: str) -> str:
    return FORMAT.sub("\0", value).replace("%%", "%")


def check_source_coverage(tables: dict[str, dict]) -> int:
    keys = set(tables["en"])
    normalized_keys = {normalized(key) for key in keys}
    missing = []
    count = 0
    for directory in ("Shared", "PhoneApp", "WatchApp"):
        for path in sorted((ROOT / directory).glob("*.swift")):
            # This helper also contains Chinese classification fragments used to
            # recognize old errors; they are not presented as app-owned copy.
            if path.name == "Localization.swift":
                continue
            for value, line in swift_literals(path.read_text()):
                if not HAN.search(value) or value in PREVIEW_DATA:
                    continue
                count += 1
                if value not in keys and value not in normalized_keys:
                    missing.append(f"{path.relative_to(ROOT)}:{line}: {value!r}")
    require(not missing, "Untranslated source literals:\n" + "\n".join(missing))
    return count


def check_project() -> None:
    project = read_plist(ROOT / "WatchMusic.xcodeproj/project.pbxproj")
    objects = project["objects"]
    shared = next(key for key, obj in objects.items()
                  if obj.get("isa") == "PBXFileSystemSynchronizedRootGroup" and obj.get("path") == "Shared")
    targets = [obj for obj in objects.values() if obj.get("isa") == "PBXNativeTarget"]
    require(len(targets) == 2, "Expected iPhone and Watch targets")
    for target in targets:
        require(shared in target.get("fileSystemSynchronizedGroups", []),
                f"{target['name']} does not include shared localization resources")
    settings = objects[project["rootObject"]]
    require(set(LANGUAGES) <= set(settings["knownRegions"]), "Project language regions are incomplete")
    require(settings["developmentRegion"] == "en", "Unsupported languages must fall back to English")


class LegalPage(HTMLParser):
    def __init__(self, path: Path):
        super().__init__(convert_charrefs=True)
        self.path = path
        self.lang = ""
        self.versions = []
        self.links = []
        self.ids = set()
        self.text = []
        self.feed(path.read_text())

    def handle_starttag(self, tag, attributes):
        attrs = dict(attributes)
        require(tag not in {"script", "iframe", "object", "embed"}, f"Active content in {self.path}")
        require(not any(key.lower().startswith("on") for key in attrs), f"Event handler in {self.path}")
        require(not attrs.get("src"), f"Legal page must read offline: {self.path}")
        if tag == "html":
            self.lang = attrs.get("lang", "")
        if tag == "meta" and attrs.get("name") == "document-version":
            self.versions.append(attrs.get("content"))
        if tag == "body":
            self.versions.append(attrs.get("data-document-version"))
        if "href" in attrs:
            self.links.append(attrs["href"])
        if "id" in attrs:
            self.ids.add(attrs["id"])

    def handle_data(self, data):
        self.text.append(data)


def check_legal(directory: Path, *, flattened: bool = False) -> None:
    version_source = (ROOT / "PhoneApp/PrivacyConsentState.swift").read_text()
    version = re.search(r'currentVersion\s*=\s*"([^"]+)"', version_source)[1]
    pages = {}
    for language in LANGUAGES:
        for name in ("privacy", "terms", "support"):
            if language == "en":
                relative = Path(f"{name}-en.html") if flattened else Path(f"en/{name}-en.html")
            else:
                relative = Path(f"{name}.html")
            path = directory / relative
            require(path.is_file(), f"Missing {language} legal document: {path}")
            page = LegalPage(path)
            require(page.lang.startswith("en" if language == "en" else "zh"), f"Wrong HTML language: {path}")
            require(page.versions == [version, version], f"Agreement version differs from consent policy: {path}")
            if language == "en":
                require(not HAN.search(" ".join(page.text)), f"Chinese copy remains in English legal document: {path}")
            pages[path.resolve()] = (language, page)
    for path, (language, page) in pages.items():
        for href in page.links:
            parsed = urlsplit(href)
            if parsed.scheme:
                require(parsed.scheme.lower() in {"https", "mailto"}, f"Unsafe legal link in {path}: {href}")
                require(not parsed.username and not parsed.password, f"Credentials in legal link: {href}")
                continue
            require(not parsed.netloc and not parsed.query, f"Nonlocal legal link in {path}: {href}")
            destination = (path.parent / unquote(parsed.path)).resolve() if parsed.path else path
            require(destination in pages, f"Legal link escapes packaged documents in {path}: {href}")
            target_language, target = pages[destination]
            require(target_language == language, f"Legal link changes language in {path}: {href}")
            require(not parsed.fragment or unquote(parsed.fragment) in target.ids,
                    f"Missing legal anchor in {path}: {href}")


def check_info(directory: Path, required_permission: str) -> None:
    for language in LANGUAGES:
        table = read_plist(directory / f"{language}.lproj/InfoPlist.strings")
        require(table.get("CFBundleDisplayName") == ("WatchMusic" if language == "en" else "随身音乐"),
                f"Wrong localized app name in {directory}, {language}")
        require(bool(table.get(required_permission)), f"Missing localized permission copy: {directory}, {language}")
        if language == "en":
            require(not HAN.search(table[required_permission]), f"Chinese permission copy in {directory}")


def check_bundle(bundle: Path, tables: dict[str, dict]) -> int:
    require(bundle.is_dir(), f"Product bundle does not exist: {bundle}")
    info = read_plist(bundle / "Info.plist")
    watch = info.get("WKApplication") is True or info.get("WKWatchKitApp") is True
    for language in LANGUAGES:
        shipped = read_plist(bundle / f"{language}.lproj/Localizable.strings")
        require(shipped == tables[language], f"Built {bundle.name} has missing or stale {language} localization resources")
    require(info.get("CFBundleDevelopmentRegion") == "en", f"Wrong product language fallback: {bundle}")
    check_info(bundle, "NSMotionUsageDescription" if watch else "NSLocalNetworkUsageDescription")
    count = 1
    if not watch:
        legal = bundle / "Legal" if (bundle / "Legal/privacy.html").is_file() else bundle
        check_legal(legal, flattened=not (legal / "en").is_dir())
        embedded = sorted((bundle / "Watch").glob("*.app"))
        require(bool(embedded), f"No embedded Watch app in {bundle}")
        count += sum(check_bundle(path, tables) for path in embedded)
    return count


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, action="append", default=[])
    args = parser.parse_args()
    tables = {language: read_plist(ROOT / f"Shared/{language}.lproj/Localizable.strings")
              for language in LANGUAGES}
    require(set(tables["en"]) == set(tables["zh-Hans"]), "English and Chinese key sets differ")
    for key, english in tables["en"].items():
        chinese = tables["zh-Hans"][key]
        require(bool(english) and bool(chinese), f"Empty translation: {key!r}")
        require(not HAN.search(english), f"Chinese copy remains in English translation: {key!r}")
        require(placeholders(key) == placeholders(english) == placeholders(chinese),
                f"Format argument mismatch: {key!r}, {english!r}, {chinese!r}")
    literals = check_source_coverage(tables)
    check_project()
    check_info(ROOT / "PhoneApp", "NSLocalNetworkUsageDescription")
    check_info(ROOT / "WatchApp", "NSMotionUsageDescription")
    check_legal(ROOT / "PhoneApp/Legal")
    bundles = sum(check_bundle(path.resolve(), tables) for path in args.bundle)
    print(f"PASS: {len(tables['en'])} bilingual keys, {literals} source literals, two target memberships, permission copy, legal links and versions; {bundles} product bundles")


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"FAIL: {error}")
