#!/usr/bin/env python3
"""Builds .c4z driver packages from src/ into dist/.

A .c4z is a zip archive with driver.xml at its root. Each subdirectory of
src/ containing a driver.xml (and a driver.lua) becomes
dist/c4plex_<name>.c4z. The shared common/ Lua modules are packed into every
driver so require() resolves inside the archive.

Version handling: the semver in VERSION is stamped into the {{SEMVER}}
placeholder, and {{VERSION_INT}} gets major*1000000 + minor*1000 + patch so
Composer sees a monotonically increasing integer for update checks (the wide
multipliers avoid collisions like 0.9.100 vs 0.10.0).

The build fails loudly rather than shipping a subtly broken archive: a driver
directory without a driver.xml, a path that driver.xml references but that is
not packed, and two files claiming the same archive name are all hard errors.
Files skipped for their extension are reported so a dropped asset is visible.
"""

import datetime
import re
import shutil
import sys
import zipfile
from pathlib import Path
from xml.etree import ElementTree

if sys.version_info < (3, 9):
    sys.exit("build.py requires Python 3.9 or newer (found %d.%d)" % sys.version_info[:2])

ROOT = Path(__file__).resolve().parent
SRC = ROOT / "src"
DIST = ROOT / "dist"
COMMON = ROOT / "common"
LICENSE = ROOT / "LICENSE"

# only these extensions are packed into a c4z; keeps editor backups, notes,
# and other stray files out of a distributed artifact. Deliberately excludes
# .md so a scratch NOTES.md dropped in a driver directory cannot ride along
# into a distributed archive; no driver references a .md file.
PACK_SUFFIXES = {".lua", ".xml", ".html", ".htm", ".rtf", ".png", ".jpg",
                 ".jpeg", ".gif", ".svg", ".ico", ".webp", ".css", ".js",
                 ".json"}

# the placeholders build.py is responsible for stamping; anything else that
# looks like {{...}} is legitimate content (a documented Home Assistant
# template, for instance) and must not trip the leftover check
PLACEHOLDERS = ("{{SEMVER}}", "{{VERSION_INT}}", "{{MODIFIED}}")

# file=, small_image= and large_image= are read from the parsed XML tree, not
# by regex, so quoting and spacing variants and commented-out lines all behave.
# Only the controller:// URLs still need a pattern, since they are embedded in
# element text rather than being attributes in their own right.
ICON_URL_RE = re.compile(r"controller://driver/([^/]+)/([^\"'<>\s]+)")


def read_version() -> "tuple[str, int]":
    version_file = ROOT / "VERSION"
    if not version_file.is_file():
        sys.exit(f"missing VERSION file at {version_file}")
    semver = version_file.read_text().strip()
    try:
        major, minor, patch = (int(x) for x in semver.split("."))
    except ValueError:
        sys.exit(f"VERSION must be major.minor.patch, got: {semver!r}")
    if major < 0:
        sys.exit(f"major version must not be negative: {semver}")
    if not (0 <= minor < 1000 and 0 <= patch < 1000):
        sys.exit(f"minor/patch must be < 1000: {semver}")
    return semver, major * 1_000_000 + minor * 1_000 + patch


def collect_files(driver_dir: Path, semver: str, version_int: int, stamp: str):
    """Yield (archive_name, bytes) for everything that goes into the c4z."""

    for path in sorted(driver_dir.rglob("*")):
        # never pack a path that resolves outside the repo. A symlink, or a file
        # reached through a symlinked directory (rglob follows those on Python
        # < 3.13), would otherwise read a file from outside the tree into the
        # shipped archive. resolve() collapses the symlink; is_relative_to is the
        # version-independent containment check.
        if not path.resolve().is_relative_to(ROOT):
            print(f"    skipped (resolves outside the repo): {path.relative_to(ROOT)}")
            continue
        if not path.is_file():
            continue
        # hidden files (editor droppings, macOS AppleDouble ._* files) must not
        # ride into a shipped archive even when their extension is packable
        if any(part.startswith(".") for part in path.relative_to(driver_dir).parts):
            print(f"    skipped (hidden file): {path.relative_to(ROOT)}")
            continue
        if path.suffix.lower() not in PACK_SUFFIXES:
            print(f"    skipped (extension not packed): {path.relative_to(ROOT)}")
            continue
        arcname = path.relative_to(driver_dir).as_posix()
        data = path.read_bytes()
        # driver.xml carries the version Composer reads; the documentation pages
        # carry it in their changelog line. Both are substituted so a release
        # cannot ship a driver and a doc claiming different versions.
        if path.suffix.lower() in {".xml", ".html", ".htm"}:
            try:
                text = data.decode("utf-8")
            except UnicodeDecodeError as exc:
                sys.exit(f"{path.relative_to(ROOT)}: not valid UTF-8 ({exc})")
            text = text.replace("{{SEMVER}}", semver)
            text = text.replace("{{VERSION_INT}}", str(version_int))
            text = text.replace("{{MODIFIED}}", stamp)
            data = text.encode("utf-8")
        yield arcname, data

    for base in (COMMON,):
        if not base.is_dir():
            continue
        for path in sorted(base.rglob("*")):
            if not path.resolve().is_relative_to(ROOT):
                print(f"    skipped (resolves outside the repo): {path.relative_to(ROOT)}")
                continue
            if not path.is_file():
                continue
            # same hidden-file exclusion as the driver walk above
            if any(part.startswith(".") for part in path.relative_to(base).parts):
                print(f"    skipped (hidden file): {path.relative_to(ROOT)}")
                continue
            if path.suffix.lower() not in PACK_SUFFIXES:
                print(f"    skipped (extension not packed): {path.relative_to(ROOT)}")
                continue
            yield path.relative_to(base).as_posix(), path.read_bytes()

    # ship the project's own MIT license inside every artifact
    if LICENSE.is_file():
        yield "LICENSE", LICENSE.read_bytes()


def check_referenced_paths(driver_name: str, members: "dict[str, bytes]") -> None:
    """driver.xml must parse, and every path it points at must have been packed."""
    raw = members.get("driver.xml")
    if raw is None:
        sys.exit(f"{driver_name}: driver.xml missing from the archive")
    text = raw.decode("utf-8")

    # Parse it. Composer rejects a malformed manifest with an unhelpful error
    # long after the release is cut, so catch it here instead.
    try:
        root = ElementTree.fromstring(text)
    except ElementTree.ParseError as exc:
        sys.exit(f"{driver_name}: driver.xml is not well-formed XML: {exc}")

    # Walk the parsed tree rather than the raw text. Regex over XML both
    # false-positives (a reference inside a comment, or an unrelated attribute
    # whose name merely ends in "file") and false-negatives (single quotes, or
    # spaces around the equals sign), and the tree is already in hand.
    for el in root.iter():
        ref = el.get("file")
        if ref and ref not in members:
            sys.exit(f"{driver_name}: driver.xml references {ref!r}, which is not packed")

    # The reference check above is transitive: dropping the <documentation>
    # element and its file together would pass silently and ship a driver whose
    # Documentation tab is blank, so require the element itself.
    if root.find(".//documentation[@file]") is None:
        sys.exit(f"{driver_name}: driver.xml declares no <documentation file=...>")

    # Image and controller:// paths are resolved by Composer relative to a base
    # this script cannot confirm, so accept either the archive root or www/ and
    # only complain when the file is absent under both. This catches a typo,
    # which is the realistic failure, without guessing at the resolver.
    image_refs = []
    for el in root.iter():
        for attr in ("small_image", "large_image"):
            v = el.get(attr)
            if v:
                image_refs.append(v)
        if el.tag in ("small", "large") and el.text:
            image_refs.append(el.text)
    # tree-walked attribute refs are authoritative: a referenced image that
    # exists nowhere in the archive is a broken icon in Composer no matter how
    # the resolver works, so that is a build error, not a warning nobody reads
    for ref in image_refs:
        ref = ref.strip()
        if ref and ref not in members and f"www/{ref}" not in members:
            sys.exit(f"{driver_name}: driver.xml references {ref!r}, "
                     f"not found at '{ref}' or 'www/{ref}'")

    # controller:// refs come from a raw-text scan that can also match XML
    # comments and URLs naming another driver's archive, so a missing file
    # here stays a warning: over-failing the build on a commented-out icon
    # block would be worse than the broken link it flags
    expected = f"c4plex_{driver_name}"
    for owner, ref in ICON_URL_RE.findall(text):
        if owner != expected:
            print(f"    WARNING: {driver_name}: controller:// URL names {owner!r}, "
                  f"but this driver packs as {expected!r}; the icon will not resolve")
        ref = ref.strip()
        if ref and ref not in members and f"www/{ref}" not in members:
            print(f"    WARNING: {driver_name}: controller:// URL references {ref!r}, "
                  f"not found at '{ref}' or 'www/{ref}'")


def build_driver(driver_dir: Path, semver: str, version_int: int, stamp: str, outdir: Path) -> Path:
    members: "dict[str, bytes]" = {}
    for arcname, data in collect_files(driver_dir, semver, version_int, stamp):
        if arcname in members:
            sys.exit(
                f"{driver_dir.name}: two files both claim the archive name {arcname!r}; "
                "a driver-local file is shadowing a common/ module"
            )
        members[arcname] = data

    if "driver.lua" not in members:
        sys.exit(f"{driver_dir.name}: driver.lua was not packed")
    check_referenced_paths(driver_dir.name, members)

    # Nothing may ship with an unsubstituted placeholder: a doc reading
    # "{{SEMVER}} - Initial public release" is a visible defect on the
    # Documentation tab, and an unstamped driver.xml will not install.
    for arcname in sorted(members):
        if arcname.rsplit(".", 1)[-1].lower() in {"xml", "html", "htm"}:
            text = members[arcname].decode("utf-8", "replace")
            left = [p for p in PLACEHOLDERS if p in text]
            if left:
                sys.exit(f"{driver_dir.name}: {arcname} still contains {left}")

    out = outdir / f"c4plex_{driver_dir.name}.c4z"
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zf:
        for arcname in sorted(members):
            zf.writestr(arcname, members[arcname])
    return out


def main():
    semver, version_int = read_version()

    if not SRC.is_dir():
        sys.exit(f"missing src/ directory at {SRC}")

    # A symlink reports is_dir() true but rmtree refuses it, so handle it first
    if DIST.is_symlink():
        sys.exit(f"{DIST} is a symlink; remove it and re-run")
    if DIST.exists() and not DIST.is_dir():
        sys.exit(f"{DIST} exists but is not a directory; remove it and re-run")

    driver_dirs = []
    for d in sorted(SRC.iterdir()):
        if not d.is_dir():
            continue
        # tooling and scaffolding directories are not drivers; a dot or
        # underscore prefix is the conventional marker for both
        if d.name.startswith(".") or d.name.startswith("_"):
            print(f"  skipping non-driver directory src/{d.name}/")
            continue
        if not (d / "driver.xml").is_file():
            sys.exit(f"{d.name}: directory under src/ looks like a driver but has no driver.xml")
        if not (d / "driver.lua").is_file():
            sys.exit(f"{d.name}: has driver.xml but no driver.lua")
        driver_dirs.append(d)
    if not driver_dirs:
        sys.exit("no driver directories with driver.xml found under src/")

    print(f"c4plex {semver} (version {version_int})")

    # One stamp for the whole build, so a run straddling a minute boundary does
    # not label some drivers differently from others.
    stamp = datetime.datetime.now().strftime("%m/%d/%Y %I:%M %p")

    # Build into a staging directory and swap it in only once every driver has
    # succeeded. A hard error partway through would otherwise leave dist/ half
    # populated and looking like a complete release.
    staging = ROOT / "dist.building"
    if staging.is_symlink():
        sys.exit(f"{staging} is a symlink; remove it and re-run")
    if staging.exists() and not staging.is_dir():
        sys.exit(f"{staging} exists but is not a directory; remove it and re-run")
    if staging.is_dir():
        shutil.rmtree(staging)
    staging.mkdir()
    try:
        built = []
        for driver_dir in driver_dirs:
            out = build_driver(driver_dir, semver, version_int, stamp, staging)
            built.append((out.name, out.stat().st_size))
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise

    if DIST.is_dir():
        shutil.rmtree(DIST)
    staging.rename(DIST)
    for name, size in built:
        print(f"  built dist/{name} ({size} bytes)")


if __name__ == "__main__":
    main()
