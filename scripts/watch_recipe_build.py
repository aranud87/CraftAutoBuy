"""Check the live EU Forever build and retain recipe-index evidence for maintenance.

Print one JSON summary. Exit 0 for identical, changed or unchanged, 2 for a
retryable upstream failure, and 1 for a local error. No addon files are written.
"""
import argparse
import csv
from datetime import datetime, timezone
import hashlib
import http.client
import json
import os
from pathlib import Path
import re
from tempfile import NamedTemporaryFile, TemporaryDirectory
import urllib.request

import generate_recipe_index as gen


VERSIONS_URL = "https://eu.version.battle.net/v2/products/wowf/versions"
BUILDS_URL = "https://wago.tools/api/builds"
STATE_DIR = gen.ROOT / ".tools/reviews/recipe-build-watch"
NETWORK_ERRORS = (OSError, http.client.HTTPException)
ATTENTION_AFTER = 3


class Pending(Exception):
    """The upstream manifest or exports are unavailable for this build."""


def fetch(url):
    request = urllib.request.Request(url, headers={"User-Agent": "CraftAutoBuy recipe index generator"})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.read()
    except NETWORK_ERRORS as error:
        raise Pending(f"{url}: {error}") from error


def live_build():
    try:
        lines = fetch(VERSIONS_URL).decode("utf-8-sig").splitlines()
    except UnicodeError as error:
        raise Pending("Unreadable Blizzard versions manifest") from error
    if not lines:
        raise Pending("Empty Blizzard versions manifest")
    headers = [field.partition("!")[0] for field in lines[0].split("|")]
    rows = csv.DictReader((line for line in lines[1:] if not line.startswith("#")),
                          fieldnames=headers, delimiter="|")
    europe = [row for row in rows if row.get("Region") == "eu"]
    if len(europe) != 1:
        raise Pending("Expected one EU region in the Blizzard wowf manifest")
    row = europe[0]
    version, config = row.get("VersionsName") or "", row.get("BuildConfig") or ""
    if not (re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+\.[1-9][0-9]*", version)
            and row.get("BuildId") == version.rsplit(".", 1)[1] and re.fullmatch(r"[0-9a-f]{32}", config)):
        raise Pending("Invalid EU version or build configuration in the Blizzard manifest")
    return version, config


def require_wago_build(version, config):
    try:
        catalogue = json.loads(fetch(BUILDS_URL))
    except ValueError as error:
        raise Pending("Unreadable Wago build catalogue") from error
    builds = catalogue.get("wowf") if isinstance(catalogue, dict) else None
    if not isinstance(builds, list) or not any(
        isinstance(entry, dict) and entry.get("product") == "wowf" and entry.get("version") == version
        and entry.get("build_config") == config for entry in builds
    ):
        raise Pending("Wago has not listed the live EU wowf build configuration yet")


def write_bytes(path, data):
    stream = NamedTemporaryFile(dir=path.parent, delete=False)
    temp = Path(stream.name)
    try:
        with stream:
            stream.write(data)
        os.replace(temp, path)
    finally:
        temp.unlink(missing_ok=True)


def write_json(path, value):
    write_bytes(path, (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode())


def baseline_rows(state_dir):
    """Use local pinned CSVs if available; a fresh checkout can bootstrap its own verified cache."""
    cache = state_dir / "reference" / gen.VERSION
    cache.mkdir(parents=True, exist_ok=True)
    rows = {}
    for table, expected in gen.SOURCE_HASHES.items():
        name = f"{table}-{gen.VERSION}.csv"
        for source in (cache / name, gen.SOURCE_DIR / name):
            if source.is_file():
                data = source.read_bytes()
                if hashlib.sha256(data).hexdigest() == expected:
                    rows[table] = gen.source_rows(table, data)
                    break
        else:
            try:
                data = gen.download_source(table, gen.VERSION)
                rows[table] = gen.verified_rows(table, data)
            except (*NETWORK_ERRORS, ValueError, csv.Error) as error:
                raise Pending(f"Pinned reference {gen.source_url(table)}: {error}") from error
            write_bytes(cache / name, data)
    return rows


def validate_export(table, data, reference):
    header = next(csv.reader(data.decode("utf-8-sig").splitlines()), [])
    if not reference[0].keys() <= set(header) or len(set(header)) != len(header):
        raise ValueError("unexpected or incomplete DB2 column names")
    records = gen.source_rows(table, data)
    if table == "SkillLine":
        numbers = ("ID", "CategoryID", "ParentSkillLineID")
    elif table == "SkillLineAbility":
        numbers = ("ID", "SkillLine", "Spell", "TradeSkillCategoryID")
    else:
        numbers = ("ID", "Effect", "SpellID", "EffectItemType", "EffectTriggerSpell")
    for row in records:
        if None in row or None in row.values():
            raise ValueError("incomplete or invalid DB2 row")
        for column in numbers:
            gen.integer(row, column)
        # Wago's CSV filters are substring matches. The generator narrows
        # these rows to the exact effect/spell while building the index.
        if table == "SpellEffect-TradeSkill" and "47" not in row["Effect"]:
            raise ValueError("wrong Trade Skill effect filter")
        if table.startswith("SpellEffect-") and table != "SpellEffect-TradeSkill":
            if table.removeprefix("SpellEffect-") not in row["SpellID"]:
                raise ValueError("wrong SpellID filter")
    return records


def capture(version, directory, baseline):
    rows, sources = {}, {}
    for table, expected in gen.SOURCE_HASHES.items():
        try:
            data = gen.download_source(table, version)
            records = validate_export(table, data, baseline[table])
        except (*NETWORK_ERRORS, ValueError, csv.Error) as error:
            raise Pending(f"{gen.source_url(table, version)}: {error}") from error
        rows[table] = records
        sources[table] = {**gen.source_evidence(table, version, data), "index_sha256": expected}
        (directory / f"{table}-{version}.csv").write_bytes(data)
    return rows, sources


def compare_recipes(baseline, target):
    reference, parents, _ = gen.build_index(baseline)
    try:
        candidates, new_parents, _ = gen.build_index(target)
    except (ValueError, KeyError) as error:
        # A change to e.g. the set of trade-skill effects can require new per-spell evidence.
        return {"review_required": str(error)}
    professions = {}
    for skill, ids in candidates.items():
        added = sorted(set(ids) - set(reference[skill]))
        removed = sorted(set(reference[skill]) - set(ids))
        if added or removed:
            professions[skill] = {"added": added, "removed": removed}
    relations = {key: {"before": parents.get(key), "after": new_parents.get(key)}
                 for key in parents.keys() | new_parents.keys() if parents.get(key) != new_parents.get(key)}
    return {"candidates": sum(map(len, candidates.values())), "professions": professions, "parent_changes": relations}


def cached_report(path, version, config, baseline):
    if not path.is_file():
        return None
    report = json.loads(path.read_text(encoding="utf-8"))
    if (report.get("baseline") != baseline or report.get("blizzard_build_config") != config
            or report.get("version") != version or report.get("status") not in ("changed", "identical")):
        return None
    sources = report["sources"]
    if sources.keys() != gen.SOURCE_HASHES.keys():
        return None
    for table, evidence in sources.items():
        export = path.parent / report["exports"] / f"{table}-{version}.csv"
        if not export.is_file() or hashlib.sha256(export.read_bytes()).hexdigest() != evidence["sha256"]:
            return None
    return report


def summary(report, path, status):
    changed = report["changed_sources"]
    return {"status": status, "result": report["status"], "version": report["version"], "report": str(path),
            "identical_exports": len(report["sources"]) - len(changed), "changed_sources": changed,
            "index_accepts_build": report["version"] in (gen.VERSION, *gen.COMPATIBLE_VERSIONS),
            "recipe_changes": report["recipe_changes"], "next_step": report["next_step"]}


def record_pending(directory, version, config, checked, reason):
    path = directory / "last-pending.json"
    previous = json.loads(path.read_text(encoding="utf-8")) if path.is_file() else {}
    matches = (previous.get("reason") == reason and previous.get("version") == version
               and previous.get("blizzard_build_config") == config)
    count = previous.get("pending_count", 1) + 1 if matches else 1
    first = previous.get("first_pending_utc", previous.get("checked_utc", checked)) if matches else checked
    pending = {"status": "pending", "region": "eu", "product": "wowf", "version": version,
               "blizzard_build_config": config, "first_pending_utc": first, "checked_utc": checked,
               "reason": reason, "pending_count": count, "needs_attention": count >= ATTENTION_AFTER}
    write_json(path, pending)
    return {**pending, "report": str(path)}


def watch(state_dir, refresh=False):
    state_dir.mkdir(parents=True, exist_ok=True)
    directory = state_dir
    version = config = None
    checked = datetime.now(timezone.utc).isoformat()
    try:
        version, config = live_build()
        (state_dir / "last-pending.json").unlink(missing_ok=True)
        directory = state_dir / version
        directory.mkdir(exist_ok=True)
        baseline = {"capture_schema": 2, "version": gen.VERSION, "source_hashes": gen.SOURCE_HASHES,
                    "generator_sha256": hashlib.sha256(Path(gen.__file__).read_bytes()).hexdigest()}
        path = directory / "report.json"
        pending_path = directory / "last-pending.json"
        prior = None if refresh or pending_path.is_file() else cached_report(path, version, config, baseline)
        if prior:
            return summary(prior, path, "unchanged")
        require_wago_build(version, config)
        rows = baseline_rows(state_dir)
        with TemporaryDirectory(dir=directory, prefix="stage-") as stage:
            exports = Path(stage) / "exports"
            exports.mkdir()
            target, sources = capture(version, exports, rows)
            changed = [table for table, data in sources.items() if data["sha256"] != data["index_sha256"]]
            changes = compare_recipes(rows, target)
            result = "changed" if changed else "identical"
            if changed:
                next_step = "Review changed exports and candidate IDs before preparing a new index."
            elif version.rsplit(".", 1)[0] != gen.VERSION.rsplit(".", 1)[0]:
                next_step = "Matching exports on a new game version. Review its interface and APIs before adapting the addon."
            elif version in (gen.VERSION, *gen.COMPATIBLE_VERSIONS):
                next_step = "This version is already accepted by the local index."
            else:
                next_step = (f"Confirm client interface {gen.INTERFACE}, then use the captured CSVs to "
                             "verify and test a compatibility release.")
            # Each successful run publishes immutable exports before the report. A
            # failed or concurrent capture cannot replace another run's evidence.
            destination = directory / Path(stage).name.replace("stage-", "exports-", 1)
            exports.rename(destination)
            report = {"version": version, "blizzard_build_config": config, "region": "eu", "product": "wowf",
                      "versions_url": VERSIONS_URL, "wago_catalogue_url": BUILDS_URL,
                      "checked_utc": checked, "baseline": baseline, "status": result,
                      "exports": destination.name, "sources": sources, "changed_sources": changed,
                      "recipe_changes": changes, "next_step": next_step}
            write_json(path, report)
            pending_path.unlink(missing_ok=True)
        return summary(report, path, result)
    except Pending as error:
        return record_pending(directory, version, config, checked, str(error))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-dir", type=Path, default=STATE_DIR)
    parser.add_argument("--refresh", action="store_true", help="Recapture a build already compared")
    args = parser.parse_args()
    try:
        result = watch(args.state_dir.resolve(), args.refresh)
    except (OSError, ValueError, KeyError, csv.Error) as error:
        result = {"status": "error", "reason": str(error)}
    print(json.dumps(result, sort_keys=True))
    return {"pending": 2, "error": 1}.get(result["status"], 0)


if __name__ == "__main__":
    raise SystemExit(main())
