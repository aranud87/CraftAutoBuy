"""Generate the passive recipe-ID candidates from a pinned Forever client build.

Only numeric recipe candidates and explicit skill-line relations are shipped.
The source CSVs and the detailed provenance manifest stay under .tools/.
Run again without network access with --offline, or verify with --check.
"""

import argparse
import csv
import hashlib
import io
import json
from pathlib import Path
import re
import sys
import urllib.request


ROOT = Path(__file__).resolve().parents[1]
VERSION = "1.60.1.70938"
BUILD = 70938
INTERFACE = 16001
SCHEMA = 1
COMPATIBLE_VERSIONS = ("1.60.1.71037", "1.60.1.71091")
SOURCE_DIR = ROOT / ".tools/reviews/codex-1.0.1/recipe-index-source"
OUTPUT = ROOT / "CraftAutoBuy/RecipeIndex.lua"
SOURCE_HASHES = {
    "SkillLineAbility": "6696abd03ef90ad250a12ac23778616c292c46f6a0082130fbe187c96ead0aa0",
    "SkillLine": "f3867d43ab42d1f5278e6e5028d0151bc06e4ef8e5cbd790a20df6ee57aa654d",
    "SpellEffect-TradeSkill": "f424e9775d219f0a8a0a54389fd3c8abf9040722a48846a1b169ce504ffbb682",
    "SpellEffect-4036": "af620b6404acf96b9b7fa0b5f71ea54160d7af45d96a6cecc680d287a1ca6d72",
    "SpellEffect-1240947": "da9ffc6cd6fd5a0985c9c38a87f21e2793db351c90bcc6260708f590e9c22700",
    "SpellEffect-1240958": "1ce0bc5a1def363a76a482029c1500ae0b12c6b18ee2a740bf566d010ae58736",
    "SpellEffect-1240969": "55cd1e9e82a08701191b17142fe394f0d4fb050206e05bb71de6b52319e43318",
    "SpellEffect-1240982": "eee4883d3fac65d22cf26bd54d6d5416c924c3351f5c0bba10a9ee19cbe7e5b8",
    "SpellEffect-1278062": "1d332181935055fee504b0b896a38ffe4840c17c832a99e1b51224a48985807a",
    "SpellEffect-1278068": "d9d88ed303d402eb588597f343870ed49b4535fb7584258e79bf0fc4a4ef5d06",
}
# The twelve primary/secondary professions present in this Forever build.
# Racial, riding, class-only (e.g. Poisons) and test skill lines are excluded.
PROFESSIONS = (129, 164, 165, 171, 182, 185, 186, 197, 202, 333, 356, 393)


def source_url(table, version=VERSION):
    if table == "SpellEffect-TradeSkill":
        return f"https://wago.tools/db2/SpellEffect/csv?build={version}&filter[Effect]=47"
    if table.startswith("SpellEffect-"):
        spell = int(table.removeprefix("SpellEffect-"))
        return f"https://wago.tools/db2/SpellEffect/csv?build={version}&filter[SpellID]={spell}"
    return f"https://wago.tools/db2/{table}/csv?build={version}"


def source_rows(table, data):
    rows = list(csv.DictReader(io.StringIO(data.decode("utf-8-sig"))))
    if not rows:
        raise ValueError(f"{table}: empty source")
    return rows


def verified_rows(table, data):
    actual = hashlib.sha256(data).hexdigest()
    if actual != SOURCE_HASHES[table]:
        raise ValueError(f"{table}: SHA256 {actual}, expected {SOURCE_HASHES[table]}")
    return source_rows(table, data)


def download_source(table, version):
    request = urllib.request.Request(source_url(table, version), headers={
        "User-Agent": "CraftAutoBuy recipe index generator",
        "Accept": "text/csv",
    })
    with urllib.request.urlopen(request, timeout=30) as response:
        return response.read()


def load_sources(directory, offline=False, version=VERSION):
    rows, blobs = {}, {}
    for table in SOURCE_HASHES:
        path = directory / f"{table}-{version}.csv"
        if path.is_file():
            data = path.read_bytes()
        elif offline:
            raise ValueError(f"Missing pinned source: {path}")
        else:
            data = download_source(table, version)
        rows[table] = verified_rows(table, data)
        blobs[table] = data
    return rows, blobs


def integer(row, key):
    try:
        value = int(row[key])
    except (KeyError, TypeError, ValueError) as error:
        raise ValueError(f"Invalid integer {key} in source row") from error
    if value < 0:
        raise ValueError(f"Negative {key} in source row")
    return value


def non_recipe_abilities(rows, candidates):
    # A positive crafting category is not sufficient: Gardening/Tanning and
    # Engineering ranks also have one. Discover all Trade Skill effects first,
    # then inspect every effect of each matching candidate. The pinned per-spell
    # exports are evidence inputs, not a manually chosen list of exclusions.
    if "SpellEffect-TradeSkill" not in rows:
        raise ValueError("Missing complete Trade Skill effect source")
    possible = {integer(row, "SpellID") for row in rows["SpellEffect-TradeSkill"]
                if integer(row, "Effect") == 47 and integer(row, "SpellID") in candidates}
    excluded = set()
    for spell in possible:
        proof = rows.get(f"SpellEffect-{spell}")
        if proof is None:
            raise ValueError(f"Missing complete effect evidence for {spell}")
        effects = [row for row in proof if integer(row, "SpellID") == spell]
        if not effects or not any(integer(row, "Effect") == 47 for row in effects):
            raise ValueError(f"Incomplete Trade Skill effect evidence for {spell}")
        # 47 = Trade Skill; 118 = Skill. These effects only open/advance the
        # profession. Any additional effect, produced item or triggered spell
        # keeps the candidate, so a real recipe is not discarded speculatively.
        if all(integer(row, "Effect") in (47, 118)
               and integer(row, "EffectItemType") == 0
               and integer(row, "EffectTriggerSpell") == 0 for row in effects):
            excluded.add(spell)
    return excluded


def build_index(rows):
    skills = {integer(row, "ID"): row for row in rows["SkillLine"]}
    for key in PROFESSIONS:
        if key not in skills or integer(skills[key], "CategoryID") not in (9, 11):
            raise ValueError(f"Missing profession skill line {key}")

    def root_skill(key):
        seen = set()
        while key in skills:
            if key in seen:
                raise ValueError("Cyclic skill-line parent relation")
            seen.add(key)
            parent = integer(skills[key], "ParentSkillLineID")
            if parent == 0:
                return key
            key = parent
        return None

    parents = {}
    for key in skills:
        root = root_skill(key)
        if root in PROFESSIONS and root != key:
            parents[key] = root

    recipes = {key: set() for key in PROFESSIONS}
    details = {key: {"source_rows": 0, "categorized_rows": 0,
                     "excluded_uncategorized_spell_ids": [],
                     "excluded_non_recipe_spell_ids": []} for key in PROFESSIONS}
    for row in rows["SkillLineAbility"]:
        root = root_skill(integer(row, "SkillLine"))
        if root not in recipes:
            continue
        spell = integer(row, "Spell")
        if spell == 0:
            raise ValueError("A profession ability has spell ID zero")
        details[root]["source_rows"] += 1
        # This is the client's explicit crafting-category relation. Uncategorized
        # abilities include profession ranks/openers, tracking and gadget-use
        # summons, and must not hold a complete recipe scan open indefinitely.
        if integer(row, "TradeSkillCategoryID") > 0:
            recipes[root].add(spell)
            details[root]["categorized_rows"] += 1
        else:
            details[root]["excluded_uncategorized_spell_ids"].append(spell)

    non_recipes = non_recipe_abilities(rows, set().union(*recipes.values()))
    for key, values in recipes.items():
        details[key]["excluded_non_recipe_spell_ids"] = sorted(values & non_recipes)
        values.difference_update(non_recipes)
    for key, values in recipes.items():
        if not values:
            raise ValueError(f"Profession {key} has no recipe candidates")
        details[key]["recipe_candidates"] = len(values)
        details[key]["name"] = skills[key]["DisplayName_lang"]
        details[key]["excluded_uncategorized_spell_ids"] = sorted(set(
            details[key]["excluded_uncategorized_spell_ids"]))
    return {key: sorted(values) for key, values in recipes.items()}, parents, details


def render_lua(recipes, parents):
    compatible = ", ".join(f"[{version.rsplit('.', 1)[1]}] = true" for version in COMPATIBLE_VERSIONS)
    lines = [
        "local _, ns = ...",
        "",
        "-- Generated numeric candidates, not proof that the character knows a recipe.",
        f"-- Source: wago.tools DB2 SkillLineAbility + SkillLine + SpellEffect, build {VERSION}.",
        "-- Generator: scripts/generate_recipe_index.py; pinned SHA256 provenance stays local.",
        "-- Includes categorized profession abilities, excluding proven open/rank-only spells.",
        "-- Learned state and recipe schematics must still be read from the client.",
        "ns.RecipeIndex = {",
        f"    schema = {SCHEMA}, interface = {INTERFACE}, build = {BUILD},",
        f'    version = "{VERSION}",',
        "    -- These client builds use byte-identical source exports (verified by SHA256).",
        f"    compatibleBuilds = {{ {compatible} }},",
        "    professions = {",
    ]
    for key, ids in sorted(recipes.items()):
        lines.append(f"        [{key}] = {{")
        for start in range(0, len(ids), 12):
            lines.append("            " + ", ".join(map(str, ids[start:start + 12])) + ",")
        lines.append("        },")
    lines.extend(["    },", "    parents = {"])
    for key, parent in sorted(parents.items()):
        lines.append(f"        [{key}] = {parent},")
    lines.extend(["    },", "}", ""])
    return "\n".join(lines).encode("utf-8")


def source_evidence(table, version, data):
    return {"url": source_url(table, version), "sha256": hashlib.sha256(data).hexdigest(),
            "bytes": len(data), "rows": len(source_rows(table, data))}


def manifest(rows, blobs, compatible_blobs, recipes, parents, details, lua):
    return {
        "schema": SCHEMA, "interface": INTERFACE, "build": BUILD, "version": VERSION,
        "identical_source_versions": list(COMPATIBLE_VERSIONS),
        "compatible_sources": {
            version: {table: source_evidence(table, version, data) for table, data in sources.items()}
            for version, sources in compatible_blobs.items()
        },
        "sources": {table: {"url": source_url(table), "sha256": SOURCE_HASHES[table],
                             "bytes": len(blobs[table]), "rows": len(rows[table])}
                    for table in SOURCE_HASHES},
        "policy": {
            "profession_skill_lines": list(PROFESSIONS),
            "include": "positive TradeSkillCategoryID in a selected profession or its explicit child",
            "exclude": "racial/riding/class-only/test skill lines, uncategorized abilities, and proven open/rank-only spells",
            "non_recipe_proof": "complete SpellEffect records contain only Trade Skill (47) and optional Skill (118), with no item or trigger",
            "runtime": "candidate IDs only; require the client's known-spell result and a readable recipe schematic",
            "future_builds": "Regenerate and validate when the client adds or moves recipes.",
        },
        "professions": details, "parents": parents,
        "total_profession_candidates": sum(map(len, recipes.values())),
        "unique_spell_ids": len(set().union(*recipes.values())),
        "output_sha256": hashlib.sha256(lua).hexdigest(),
    }


def verify_target(version, interface, directory, baseline, fetch=False):
    if not re.fullmatch(r"1\.60\.\d+\.[1-9]\d*", version, re.ASCII):
        raise ValueError("Expected a full Forever version such as 1.60.1.71037")
    sources, differences = {}, []
    for table, expected in baseline.items():
        path = directory / f"{table}-{version}.csv"
        if fetch:
            data = download_source(table, version)
            if path.exists():
                raise ValueError(f"Fresh download requires an empty capture directory: {path}")
            source_rows(table, data)
            path.write_bytes(data)
        else:
            data = path.read_bytes()
        evidence = source_evidence(table, version, data)
        sources[table] = {**evidence, "index_sha256": SOURCE_HASHES[table]}
        if data != expected:
            differences.append(table)
    return {
        "version": version, "interface": interface, "index_interface": INTERFACE,
        "index_version": VERSION, "sources": sources, "changed_sources": differences,
        "source_mode": "fresh Wago downloads" if fetch else "local exports",
        "index_accepts_build": version == VERSION or version in COMPATIBLE_VERSIONS,
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--offline", action="store_true", help="Use the pinned local CSVs only")
    parser.add_argument("--check", action="store_true", help="Read-only comparison against the pinned local CSVs")
    parser.add_argument("--source-dir", type=Path, default=SOURCE_DIR)
    parser.add_argument("--output", type=Path, default=OUTPUT)
    parser.add_argument("--verify-target", metavar="VERSION", help="Compare a full target version with the shipped index")
    parser.add_argument("--interface", type=int, help="Interface reported by the target client")
    parser.add_argument("--target-source-dir", type=Path, help="Directory for target exports")
    parser.add_argument("--fetch-target", action="store_true", help="Download each target export anew into an empty directory")
    parser.add_argument("--target-report", type=Path, help="Write the target comparison as JSON")
    args = parser.parse_args(argv)
    if args.verify_target:
        if not args.check or args.interface is None or args.interface <= 0:
            parser.error("--verify-target requires --check and a positive --interface")
        if args.fetch_target:
            if not args.target_source_dir or args.target_source_dir.resolve() == args.source_dir.resolve():
                parser.error("--fetch-target requires a separate --target-source-dir")
            args.target_source_dir.mkdir(parents=True, exist_ok=True)
            if any(args.target_source_dir.iterdir()):
                parser.error("--fetch-target requires an empty --target-source-dir")
    elif args.interface is not None or args.target_source_dir or args.fetch_target or args.target_report:
        parser.error("Target options require --verify-target")
    offline = args.offline or args.check
    rows, blobs = load_sources(args.source_dir, offline)
    # Every compatible version must pass the same pinned SHA256 checks as the
    # canonical inputs before its build can be emitted in the Lua index.
    compatible_blobs = {version: load_sources(args.source_dir, offline, version)[1]
                        for version in COMPATIBLE_VERSIONS}
    recipes, parents, details = build_index(rows)
    lua = render_lua(recipes, parents)
    metadata = manifest(rows, blobs, compatible_blobs, recipes, parents, details, lua)
    encoded = (json.dumps(metadata, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")
    metadata_path = args.source_dir / "manifest.json"
    if args.check:
        for path, expected in ((args.output, lua), (metadata_path, encoded)):
            if not path.is_file() or path.read_bytes() != expected:
                raise ValueError(f"Generated output differs: {path}")
    else:
        args.source_dir.mkdir(parents=True, exist_ok=True)
        for version, sources in {VERSION: blobs, **compatible_blobs}.items():
            for table, data in sources.items():
                (args.source_dir / f"{table}-{version}.csv").write_bytes(data)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_bytes(lua)
        metadata_path.write_bytes(encoded)
    print(f"Recipe index: {len(recipes)} professions, {metadata['total_profession_candidates']} candidates, "
          f"{metadata['unique_spell_ids']} unique spells, {len(parents)} parent relations; "
          + ("verified" if args.check else "generated"))
    if args.verify_target:
        target = verify_target(args.verify_target, args.interface, args.target_source_dir or args.source_dir,
                               blobs, args.fetch_target)
        if args.target_report:
            args.target_report.write_text(json.dumps(target, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        print(f"Target {target['version']}, interface {target['interface']}: "
              f"{len(target['sources']) - len(target['changed_sources'])}/{len(target['sources'])} identical exports")
        if target["changed_sources"]:
            raise ValueError("Changed exports require a newly pinned index: " + ", ".join(target["changed_sources"]))
        if args.interface != INTERFACE:
            raise ValueError(f"Interface {args.interface} has not been validated for this index ({INTERFACE})")
        if not target["index_accepts_build"]:
            raise ValueError("Identical sources: add and verify the target alias before release")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError) as error:
        print(f"Recipe index: {error}", file=sys.stderr)
        sys.exit(1)
