#!/usr/bin/env python3
"""Guard against the class of defects fixed in CHANGELOG 0.1.0.

Two independent checks, either or both of which can be requested:

--parity  config/kongctl/airs-guardrail.yaml and config/deck/airs-guardrail.yaml
          must carry the exact same `config` block for each `ai-custom-guardrail`
          instance, in the same order. Order is: every ai_gateway_policies entry
          (kongctl) versus every service-level plugin (document order across all
          services) followed by every route-level plugin (document order across
          all routes) on the deck side.

--schema  Every key inside every `config` block, in both files, must exist in
          the plugin schema published at
          https://developer.konghq.com/plugins/ai-custom-guardrail/reference/
          (inline as `window.schema`), and every value of an enum field must be
          one of the schema's allowed values. This is what would have caught
          `guarding_mode: REQUEST` and a nested `request.body` before they ever
          reached `kongctl apply` or `deck sync`.

Needs only PyYAML beyond the standard library.
"""
import argparse
import json
import re
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Any

import yaml

SCHEMA_URL = "https://developer.konghq.com/plugins/ai-custom-guardrail/reference/"
USER_AGENT = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/124.0 Safari/537.36"
)
KONGCTL_FILE = "config/kongctl/airs-guardrail.yaml"
DECK_FILE = "config/deck/airs-guardrail.yaml"
SCHEMA_RE = re.compile(r"window\.schema\s*=\s*(\{.*?\})\s*;?\s*</script>", re.S)


@dataclass(eq=True, frozen=True)
class TagValue:
    """Placeholder for a kongctl-only YAML tag (!lookup, !env, !ref, ...)."""

    tag: str
    value: Any


def make_loader() -> type:
    class Loader(yaml.SafeLoader):
        pass

    def constructor(loader, node):
        if isinstance(node, yaml.ScalarNode):
            value = loader.construct_scalar(node)
        elif isinstance(node, yaml.SequenceNode):
            value = loader.construct_sequence(node)
        else:
            value = loader.construct_mapping(node)
        return TagValue(node.tag, value)

    for tag in ("!lookup", "!env", "!ref", "!file", "!external"):
        Loader.add_constructor(tag, constructor)
    return Loader


def load_yaml(path: str) -> Any:
    with open(path, encoding="utf-8") as handle:
        return yaml.load(handle, Loader=make_loader())


def find_guardrail_configs(node: Any, path: str = "$") -> list[tuple[str, str, dict]]:
    """Recursively find every ai-custom-guardrail instance's config block."""
    found: list[tuple[str, str, dict]] = []
    if isinstance(node, dict):
        kind = node.get("type") or node.get("name")
        config = node.get("config")
        if kind == "ai-custom-guardrail" and isinstance(config, dict):
            label = node.get("ref") or node.get("instance_name") or node.get("name") or "?"
            found.append((path, label, config))
        for key, value in node.items():
            found.extend(find_guardrail_configs(value, f"{path}.{key}"))
    elif isinstance(node, list):
        for index, value in enumerate(node):
            found.extend(find_guardrail_configs(value, f"{path}[{index}]"))
    return found


def collect_kongctl_policies(doc: Any) -> list[tuple[str, dict]]:
    return [
        (policy.get("ref") or policy.get("name"), policy["config"])
        for policy in doc.get("ai_gateway_policies", [])
        if policy.get("type") == "ai-custom-guardrail"
    ]


def collect_deck_plugins(doc: Any) -> list[tuple[str, dict]]:
    services = doc.get("services", [])
    service_level = []
    route_level = []
    for service in services:
        for plugin in service.get("plugins", []) or []:
            if plugin.get("name") == "ai-custom-guardrail":
                service_level.append((plugin.get("instance_name") or plugin.get("name"), plugin["config"]))
    for service in services:
        for route in service.get("routes", []) or []:
            for plugin in route.get("plugins", []) or []:
                if plugin.get("name") == "ai-custom-guardrail":
                    route_level.append((plugin.get("instance_name") or plugin.get("name"), plugin["config"]))
    return service_level + route_level


def run_parity() -> bool:
    kongctl_doc = load_yaml(KONGCTL_FILE)
    deck_doc = load_yaml(DECK_FILE)
    kongctl = collect_kongctl_policies(kongctl_doc)
    deck = collect_deck_plugins(deck_doc)

    ok = True
    if len(kongctl) != len(deck):
        print(f"FAIL: policy count differs: kongctl={len(kongctl)} deck={len(deck)}")
        ok = False

    for index, (name_k, cfg_k) in enumerate(kongctl):
        if index >= len(deck):
            break
        name_d, cfg_d = deck[index]
        if cfg_k == cfg_d:
            print(f"ok - [{index}] {name_k} == {name_d}: config identical")
        else:
            ok = False
            print(f"FAIL: [{index}] {name_k} (kongctl) vs {name_d} (deck): config differs")
            keys = set(cfg_k) | set(cfg_d)
            for key in sorted(keys):
                if cfg_k.get(key) != cfg_d.get(key):
                    print(f"  differs at key: {key}")
                    print(f"    kongctl: {cfg_k.get(key)!r}")
                    print(f"    deck   : {cfg_d.get(key)!r}")
    return ok


def download_schema() -> dict:
    request = urllib.request.Request(SCHEMA_URL, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            html = response.read().decode("utf-8")
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        # Distinct from a schema violation: the page could not be fetched.
        print(f"::error::could not fetch the plugin schema ({exc}); rerun, or pass --schema-file")
        sys.exit(3)
    match = SCHEMA_RE.search(html)
    if not match:
        sys.exit("FAIL: could not find window.schema on the reference page")
    return json.loads(match.group(1))


def validate_against(schema_props: dict, data: dict, path: str, errors: list, enums_seen: dict) -> None:
    for key, value in data.items():
        if key not in schema_props:
            errors.append(f"{path}.{key}: unknown key, not in schema")
            continue
        field_schema = schema_props[key]
        if "enum" in field_schema:
            enums_seen.setdefault(key, set()).add(value if isinstance(value, str) else repr(value))
            if value not in field_schema["enum"]:
                errors.append(
                    f"{path}.{key}: value {value!r} not in enum {field_schema['enum']}"
                )
        if "additionalProperties" in field_schema:
            continue  # free-form map (params, request.body/headers/queries, functions, custom_metrics)
        if "properties" in field_schema and isinstance(value, dict):
            validate_against(field_schema["properties"], value, f"{path}.{key}", errors, enums_seen)


def run_schema(schema: dict) -> bool:
    config_props = schema["properties"]["config"]["properties"]
    errors: list[str] = []
    enums_seen: dict = {}
    top_level_keys: set = set()

    for filename in (KONGCTL_FILE, DECK_FILE):
        doc = load_yaml(filename)
        for path, label, config in find_guardrail_configs(doc):
            top_level_keys |= set(config)
            validate_against(config_props, config, f"{filename}:{path} ({label})", errors, enums_seen)

    print(f"config keys used: {sorted(top_level_keys)}")
    print(f"guarding_mode values seen: {sorted(enums_seen.get('guarding_mode', []))}")
    print(f"text_source values seen: {sorted(enums_seen.get('text_source', []))}")

    if errors:
        print("FAIL: schema violations found")
        for error in errors:
            print(f"  {error}")
        return False

    print("ok - every config key and enum value found in the published schema")
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--parity", action="store_true", help="check kongctl/deck config parity")
    parser.add_argument("--schema", action="store_true", help="validate configs against the live plugin schema")
    parser.add_argument("--schema-file", help="validate against a saved schema JSON file instead of downloading")
    parser.add_argument("--save-schema", help="save the downloaded schema JSON to this path")
    args = parser.parse_args()

    if not args.parity and not args.schema:
        parser.error("nothing to do: pass --parity and/or --schema")

    ok = True

    if args.parity:
        ok = run_parity() and ok

    if args.schema:
        if args.schema_file:
            with open(args.schema_file, encoding="utf-8") as handle:
                schema = json.load(handle)
        else:
            schema = download_schema()
            if args.save_schema:
                with open(args.save_schema, "w", encoding="utf-8") as handle:
                    json.dump(schema, handle, indent=2)
                print(f"saved schema to {args.save_schema}")
        ok = run_schema(schema) and ok

    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
