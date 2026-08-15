#!/usr/bin/env python3
"""Idempotently patch $HERMES_HOME/config.yaml from env-provided values.

    hermes_config_patch.py --config PATH [--memory-provider NAME] [--mcp-servers-b64 B64YAML]

- memory.provider := NAME (declarative — env is the source of truth every boot)
- each server named in the YAML replaces mcp_servers.<name> wholesale;
  servers not named are left untouched; sections are created if missing.
Uses PyYAML like hermes itself does (hermes_cli.config.save_config), so the
comment-stripping round-trip is the same one hermes already performs.
Exit codes: 0 ok (changed or not), 2 usage/input error.
"""
import argparse, base64, binascii, os, sys, tempfile
import yaml


def _atomic_write(path: str, data: dict) -> None:
    d = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".config.", suffix=".yaml.tmp")
    try:
        with os.fdopen(fd, "w") as fh:
            yaml.safe_dump(data, fh, default_flow_style=False, sort_keys=False, allow_unicode=True)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except Exception:
        try: os.unlink(tmp)
        except OSError: pass
        raise


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    ap.add_argument("--memory-provider")
    ap.add_argument("--mcp-servers-b64")
    a = ap.parse_args(argv)

    if not os.path.isfile(a.config):
        print(f"config not found: {a.config}", file=sys.stderr); return 2
    servers = None
    if a.mcp_servers_b64:
        try:
            # GNU `base64` wraps encoded output at 76 columns; strip all
            # whitespace before decoding so a wrapped value is still accepted.
            raw = "".join(a.mcp_servers_b64.split())
            servers = yaml.safe_load(base64.b64decode(raw, validate=True).decode()) or {}
        except (binascii.Error, UnicodeDecodeError, yaml.YAMLError) as e:
            print(f"--mcp-servers-b64 is not valid base64 YAML: {e}", file=sys.stderr); return 2
        if not isinstance(servers, dict):
            print("--mcp-servers-b64 must decode to a mapping of server-name → config", file=sys.stderr); return 2

    with open(a.config) as fh:
        cfg = yaml.safe_load(fh) or {}
    if not isinstance(cfg, dict):
        print("config.yaml root is not a mapping", file=sys.stderr); return 2

    changes = []
    if a.memory_provider is not None:
        mem = cfg.setdefault("memory", {})
        if mem.get("provider") != a.memory_provider:
            mem["provider"] = a.memory_provider
            changes.append(f"memory.provider={a.memory_provider}")
    if servers:
        mcp = cfg.setdefault("mcp_servers", {})
        if mcp is None:
            mcp = cfg["mcp_servers"] = {}
        for name, entry in servers.items():
            if mcp.get(name) != entry:
                mcp[name] = entry
                changes.append(f"mcp_servers.{name} replaced")

    if changes:
        _atomic_write(a.config, cfg)
        for c in changes: print(f"hermes_config_patch: {c}")
    else:
        print("hermes_config_patch: no changes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
