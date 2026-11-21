#!/usr/bin/env python3
"""Generate fork versions and package an unsigned iOS archive."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import zipfile


def upstream_version(project):
    versions = set(re.findall(r"MARKETING_VERSION = ([^;]+);", Path(project).read_text()))
    if len(versions) != 1:
        raise ValueError("All targets must use the same MARKETING_VERSION")
    version = versions.pop().strip()
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError("MARKETING_VERSION must contain three numeric components")
    return version


def select_version(base, tags, head_tags):
    pattern = re.compile(r"v" + re.escape(base) + r"-([1-9][0-9]*)$")

    def sequences(values):
        return [int(match.group(1)) for tag in values if (match := pattern.fullmatch(tag))]

    # 重跑同一提交時沿用版本，避免失敗重試消耗序號或覆寫其他版本。
    existing = sequences(head_tags)
    sequence = max(existing) if existing else max(sequences(tags), default=0) + 1
    return {
        "base_version": base,
        "version": "{}-{}".format(base, sequence),
        "tag": "v{}-{}".format(base, sequence),
        "build_number": str(sequence),
    }


def git(*arguments):
    return subprocess.check_output(["git", *arguments], text=True).strip()


def write_metadata(path, version):
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+-[1-9][0-9]*", version):
        raise ValueError("Invalid fork version")
    path = Path(path)
    with path.open("rb") as source:
        info = plistlib.load(source)
    info["Build Release Version"] = version
    info["FirebaseCrashlyticsCollectionEnabled"] = False
    metadata = {
        "Build Git SHA": os.environ.get("GITHUB_SHA"),
        "Build Workflow": os.environ.get("GITHUB_WORKFLOW"),
        "Build GitHub Run ID": os.environ.get("GITHUB_RUN_ID"),
        "Build Source Branch": os.environ.get("GITHUB_REF_NAME"),
    }
    if os.environ.get("GITHUB_REPOSITORY") and os.environ.get("GITHUB_RUN_ID"):
        metadata["Build GitHub Run URL"] = "{}/{}/actions/runs/{}".format(
            os.environ.get("GITHUB_SERVER_URL", "https://github.com"),
            os.environ["GITHUB_REPOSITORY"], os.environ["GITHUB_RUN_ID"],
        )
    info.update({key: value for key, value in metadata.items() if value})
    with path.open("wb") as destination:
        plistlib.dump(info, destination, sort_keys=False)


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def package_archive(archive, output, version):
    base, sequence = version.rsplit("-", 1)
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", base) or not re.fullmatch(r"[1-9][0-9]*", sequence):
        raise ValueError("Invalid fork version")
    apps = list((Path(archive) / "Products/Applications").glob("*.app"))
    if len(apps) != 1:
        raise ValueError("Archive must contain exactly one iOS app")
    app = apps[0]
    for bundle in [app, *app.glob("PlugIns/*.appex")]:
        with (bundle / "Info.plist").open("rb") as source:
            info = plistlib.load(source)
        if info.get("CFBundleShortVersionString") != base or str(info.get("CFBundleVersion")) != sequence:
            raise ValueError("App and extensions must have matching release versions")
        if bundle == app and info.get("Build Release Version") != version:
            raise ValueError("App is missing the fork display version")
    if any(path.name in {"_CodeSignature", "embedded.mobileprovision"} for path in app.rglob("*")):
        raise ValueError("Expected an unsigned archive without provisioning profiles")

    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    ipa = output / "NS-Connect-{}-unsigned.ipa".format(version)
    with zipfile.ZipFile(ipa, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as package:
        for path in [app, *sorted(app.rglob("*"))]:
            name = str(Path("Payload") / app.name / path.relative_to(app))
            if path.is_symlink():
                entry = zipfile.ZipInfo(name)
                entry.create_system = 3
                entry.external_attr = (stat.S_IFLNK | 0o777) << 16
                package.writestr(entry, os.readlink(path))
            else:
                package.write(path, name)

    provenance = output / "build-provenance.json"
    provenance.write_text(json.dumps({
        "version": version,
        "upstream_version": base,
        "build_number": sequence,
        "signed": False,
        "git_sha": os.environ.get("GITHUB_SHA"),
        "repository": os.environ.get("GITHUB_REPOSITORY"),
        "run_id": os.environ.get("GITHUB_RUN_ID"),
        "ipa": ipa.name,
        "ipa_sha256": sha256(ipa),
    }, ensure_ascii=False, indent=2) + "\n")
    (output / "SHA256SUMS").write_text("".join(
        "{}  {}\n".format(sha256(path), path.name) for path in [ipa, provenance]
    ))
    return ipa


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    prepare = commands.add_parser("prepare")
    prepare.add_argument("--project", default="nodeseek.xcodeproj/project.pbxproj")
    metadata = commands.add_parser("metadata")
    metadata.add_argument("--plist", default="nodeseek/Resources/Info.plist")
    metadata.add_argument("--version", required=True)
    package = commands.add_parser("package")
    package.add_argument("--archive", required=True)
    package.add_argument("--output", default="build/release")
    package.add_argument("--version", required=True)
    args = parser.parse_args()
    if args.command == "prepare":
        version = select_version(
            upstream_version(args.project), git("tag", "--list").splitlines(),
            git("tag", "--points-at", "HEAD").splitlines(),
        )
        for key, value in version.items():
            print("{}={}".format(key, value))
    elif args.command == "metadata":
        write_metadata(args.plist, args.version)
    else:
        print(package_archive(args.archive, args.output, args.version))


if __name__ == "__main__":
    main()
