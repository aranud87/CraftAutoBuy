"""Compare live WoW Forever recipe data across the five regional deployments.

Print one JSON summary with a builds entry for each version/configuration
and its regions. updated_regions records first sightings and rollouts, even
when recipe data is cached. Exit 0 on success, 2 for pending upstream data,
or 1 for a local error. No addon files are written.
"""
import argparse
import csv
from datetime import datetime, timezone
from functools import cache
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
REGIONS = ("eu", "us", "tw", "kr", "cn")
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


def live_builds():
    try:
        lines = fetch(VERSIONS_URL).decode("utf-8-sig").splitlines()
    except UnicodeError as error:
        raise Pending("Unreadable Blizzard versions manifest") from error
    if not lines:
        raise Pending("Empty Blizzard versions manifest")
    headers = [field.partition("!")[0] for field in lines[0].split("|")]
    if not {"Region", "BuildConfig", "BuildId", "VersionsName"}.issubset(headers) or len(headers) != len(set(headers)):
        raise Pending("Invalid Blizzard versions manifest header")
    by_region = {region: [] for region in REGIONS}
    for row in csv.DictReader((line for line in lines[1:] if not line.startswith("#")),
                              fieldnames=headers, delimiter="|"):
        if row.get("Region") in by_region:
            by_region[row["Region"]].append(row)
    builds, issues = {}, {}
    for region, rows in by_region.items():
        if len(rows) != 1:
            issues[region] = f"Expected one {region} row in the Blizzard manifest, found {len(rows)}"
            continue
        row = rows[0]
        version, config = row.get("VersionsName") or "", row.get("BuildConfig") or ""
        if not (re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+\.[1-9][0-9]*", version)
                and row.get("BuildId") == version.rsplit(".", 1)[1] and re.fullmatch(r"[0-9a-f]{32}", config)):
            issues[region] = f"Invalid {region} version or build configuration in the Blizzard manifest"
            continue
        builds.setdefault((version, config), []).append(region)
    return builds, issues


def wago_builds():
    try:
        catalogue = json.loads(fetch(BUILDS_URL))
    except ValueError as error:
        raise Pending("Unreadable Wago build catalogue") from error
    builds = catalogue.get("wowf") if isinstance(catalogue, dict) else None
    if not isinstance(builds, list):
        raise Pending("Missing wowf entries in the Wago build catalogue")
    configs = {}
    for entry in builds:
        if isinstance(entry, dict) and entry.get("product") == "wowf" and isinstance(entry.get("version"), str):
            config = entry.get("build_config")
            if not isinstance(config, str) or not re.fullmatch(r"[0-9a-f]{32}", config):
                config = None
            configs.setdefault(entry["version"], set()).add(config)
    return configs


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
            "blizzard_build_config": report["blizzard_build_config"],
            "identical_exports": len(report["sources"]) - len(changed), "changed_sources": changed,
            "index_accepts_build": report["version"] in (gen.VERSION, *gen.COMPATIBLE_VERSIONS),
            "recipe_changes": report["recipe_changes"], "next_step": report["next_step"]}


def record_pending(directory, version, config, checked, reason, regions, legacy_path=None):
    path = directory / "last-pending.json"
    source = path if path.is_file() else legacy_path
    previous = json.loads(source.read_text(encoding="utf-8")) if source and source.is_file() else {}
    matches = (previous.get("reason") == reason and previous.get("version") == version
               and previous.get("blizzard_build_config") == config)
    count = previous.get("pending_count", 1) + 1 if matches else 1
    first = previous.get("first_pending_utc", previous.get("checked_utc", checked)) if matches else checked
    pending = {"status": "pending", "regions": regions, "product": "wowf", "version": version,
               "blizzard_build_config": config, "first_pending_utc": first, "checked_utc": checked,
               "reason": reason, "pending_count": count, "needs_attention": count >= ATTENTION_AFTER}
    write_json(path, pending)
    return {**pending, "report": str(path)}


def watch_build(state_dir, version, config, regions, checked, baseline, get_catalogue, get_reference,
                conflicting, refresh):
    version_dir = state_dir / version
    directory = version_dir / config
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / "report.json"
    pending_path = directory / "last-pending.json"
    legacy_pending = version_dir / "last-pending.json"
    try:
        # Wago's CSV URLs select a version, not its BuildConfig. Even a cache
        # hit cannot resolve conflicting live configurations for that version.
        if conflicting:
            raise Pending("The live regions use different configurations of this version; Wago CSVs select by version only")
        if not refresh and not pending_path.is_file():
            prior = cached_report(path, version, config, baseline)
            if prior:
                return summary(prior, path, "unchanged")
            # The EU-only watcher stored its evidence directly under the version.
            legacy_path = version_dir / "report.json"
            if not path.exists() and not legacy_pending.is_file():
                prior = cached_report(legacy_path, version, config, baseline)
                if prior:
                    return summary(prior, legacy_path, "unchanged")
        configs = get_catalogue().get(version, set())
        if config not in configs:
            raise Pending("Wago has not listed this live wowf build configuration yet")
        if configs != {config}:
            raise Pending("Wago lists multiple configurations of this version; its CSVs select by version only")
        rows = get_reference()
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
            report = {"version": version, "blizzard_build_config": config, "regions": regions, "product": "wowf",
                      "versions_url": VERSIONS_URL, "wago_catalogue_url": BUILDS_URL,
                      "checked_utc": checked, "baseline": baseline, "status": result,
                      "exports": destination.name, "sources": sources, "changed_sources": changed,
                      "recipe_changes": changes, "next_step": next_step}
            write_json(path, report)
            pending_path.unlink(missing_ok=True)
        return summary(report, path, result)
    except Pending as error:
        return record_pending(directory, version, config, checked, str(error), regions,
                              legacy_path=None if path.exists() else legacy_pending)


def watch(state_dir, refresh=False):
    state_dir.mkdir(parents=True, exist_ok=True)
    checked = datetime.now(timezone.utc).isoformat()
    try:
        builds, issues = live_builds()
    except Pending as error:
        return {**record_pending(state_dir, None, None, checked, str(error), list(REGIONS)), "builds": []}
    (state_dir / "last-pending.json").unlink(missing_ok=True)
    baseline = {"capture_schema": 2, "version": gen.VERSION, "source_hashes": gen.SOURCE_HASHES,
                "generator_sha256": hashlib.sha256(Path(gen.__file__).read_bytes()).hexdigest()}
    get_catalogue = cache(wago_builds)
    get_reference = cache(lambda: baseline_rows(state_dir))
    configs_by_version = {}
    for version, config in builds:
        configs_by_version.setdefault(version, set()).add(config)

    # A region can join a build already compared for another region. Remember
    # the last valid deployment independently from the reusable DB2 evidence.
    deployments_path = state_dir / "last-deployments.json"
    deployments = json.loads(deployments_path.read_text(encoding="utf-8")) if deployments_path.is_file() else {}
    results = []
    for (version, config), regions in builds.items():
        try:
            result = watch_build(state_dir, version, config, regions, checked, baseline, get_catalogue, get_reference,
                                 len(configs_by_version[version]) > 1, refresh)
        except (OSError, ValueError, KeyError, csv.Error) as error:
            result = {"status": "error", "reason": str(error), "version": version, "blizzard_build_config": config}
        changed_regions = [region for region in regions if deployments.get(region) != [version, config]]
        for region in regions:
            deployments[region] = [version, config]
            (state_dir / "regions" / region / "last-pending.json").unlink(missing_ok=True)
        results.append({**result, "regions": regions, "updated_regions": changed_regions})
    for region, reason in issues.items():
        directory = state_dir / "regions" / region
        directory.mkdir(parents=True, exist_ok=True)
        result = record_pending(directory, None, None, checked, reason, [region])
        results.append({**result, "updated_regions": []})
    if any(result["updated_regions"] for result in results):
        write_json(deployments_path, deployments)
    # Preserve the original flat summary when all five regions use one build.
    if len(results) == 1:
        return {**results[0], "builds": results}
    statuses = {result["status"] for result in results}
    status = next(value for value in ("error", "pending", "changed", "identical", "unchanged") if value in statuses)
    return {"status": status, "builds": results}


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
