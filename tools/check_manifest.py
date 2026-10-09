#!/usr/bin/env python3
"""Check the supplied manifest fields and their agreement with compiled artifacts.

Uses only Python's standard library. This is a local consistency check, not the
network's independent admission validator.
"""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"Duplicate manifest key: {key}")
        result[key] = value
    return result


def check():
    manifest = json.loads((ROOT / "launch.json").read_text(), object_pairs_hook=unique_object)
    assert manifest["kind"] == "univ4_hook"
    for role in ("hook", "token"):
        name = manifest[role]["contract"]
        assert isinstance(name, str) and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name)
        artifact = json.loads((ROOT / "out" / f"{name}.sol" / f"{name}.json").read_text())
        assert artifact["bytecode"]["object"] not in ("", "0x")
        assert (len(artifact["deployedBytecode"]["object"]) - 2) // 2 <= 24576
        constructors = [entry for entry in artifact["abi"] if entry["type"] == "constructor"]
        inputs = constructors[0]["inputs"] if constructors else []
        assert [arg["type"] for arg in inputs] == (["address"] if role == "hook" else [])
    assert manifest["hook"]["constructorArgs"] == ["$poolManager"]
    assert manifest["hook"]["permissions"] == ["beforeInitialize", "afterSwap"]
    assert manifest["token"]["name"] == "Pixel Pool"
    assert manifest["token"]["symbol"] == "PIXEL"
    assert manifest["token"]["decimals"] == 18
    assert manifest["token"]["totalSupply"] == str(10**27)
    pool = manifest["pool"]
    assert re.fullmatch(r"0x[0-9a-f]{40}", pool["pairedCurrency"])
    assert pool["pairedCurrency"] == "0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7"
    assert pool["fee"] == 12500
    assert pool["tickSpacing"] == 60
    assert pool["initialPrice"] == "50108289675009586237282760313921"
    assert isinstance(manifest["notes"], str) and manifest["notes"].strip()
    print("Manifest fields and compiled constructor interfaces agree.")


if __name__ == "__main__":
    check()
