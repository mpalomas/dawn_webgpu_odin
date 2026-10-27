#!/usr/bin/env python3
"""Compares this repo's Dawn bindings (wgpu/) with Odin's vendor:wgpu (wgpu-native).

Usage: tools/compare_vendor_wgpu.py [--vendor DIR] [--dawn DIR]
  --vendor  vendor:wgpu directory (default: $(odin root)/vendor/wgpu)
  --dawn    this repo's package directory (default: wgpu/ next to tools/)

Lists the declarations only one package has (enums, structs, procs, other constants and types), then
for the declarations both have: enum members that differ, struct fields that differ, and proc
signatures that differ. Procs are compared by their Odin name, so `RawQueueSubmit` and the
`QueueSubmit` wrapper are compared separately.

A line-based parser of the declarations as both packages write them, not a full Odin parser.
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path


def strip_comments(line):
    line = re.sub(r"/\*.*?\*/", "", line)
    return line.split("//")[0].rstrip()


def norm_type(t):
    # Bool is an alias of b32 in both packages. Struct tags (`fmt:"..."`) do not change the layout.
    t = re.sub(r"`[^`]*`", "", t)
    return re.sub(r"\bBool\b", "b32", t).replace(" ", "")


def split_params(params):
    out, depth, cur = [], 0, ""
    for ch in params:
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(cur)
            cur = ""
        else:
            cur += ch
    out.append(cur)
    # Drop default values: `descriptor: ^X = nil`.
    return [re.sub(r"\s*=.*", "", p.strip()) for p in out if p.strip()]


def parse_package(directory):
    decls = {"enum": {}, "struct": {}, "proc": {}, "other": {}}
    for path in sorted(Path(directory).glob("*.odin")):
        lines = path.read_text().split("\n")
        in_foreign = False
        i = 0
        while i < len(lines):
            line = strip_comments(lines[i])

            m = re.match(r"^(\w+) :: (enum|struct)\b.*\{\s*$", line)
            if m:
                name, kind = m.groups()
                body = []
                i += 1
                while not lines[i].startswith("}"):
                    b = strip_comments(lines[i]).strip().rstrip(",")
                    if b:
                        body.append(b)
                    i += 1
                if kind == "enum":
                    members = {}
                    for b in body:
                        key, _, value = b.partition("=")
                        members[key.strip()] = value.strip() or None
                    decls["enum"][name] = members
                else:
                    fields = []
                    for b in body:
                        if ":" not in b:
                            continue
                        names, _, type_ = b.partition(":")
                        # `r, g, b, a: T` declares one field per name.
                        for n in names.split(","):
                            fields.append((n.strip(), type_.strip()))
                    decls["struct"][name] = fields
                i += 1
                continue

            if re.match(r"^foreign \w+ \{", line):
                in_foreign = True
            elif in_foreign and line == "}":
                in_foreign = False
            elif in_foreign:
                m = re.match(r"\s*(\w+) :: proc\((.*)\)( -> (.*?))? ---", line)
                if m:
                    decls["proc"][m.group(1)] = (split_params(m.group(2)), (m.group(4) or "").strip())
            else:
                m = re.match(r'^(\w+) :: proc(?: "\w+")? \((.*)\)( -> (.*?))?\s*(\{|where|$)', line)
                if m:
                    decls["proc"][m.group(1)] = (split_params(m.group(2)), (m.group(4) or "").strip())
                else:
                    m = re.match(r"^(\w+) :: (.*)$", line)
                    if m:
                        decls["other"][m.group(1)] = m.group(2).strip()
            i += 1
    return decls


def odin_root():
    try:
        return subprocess.run(["odin", "root"], capture_output=True, text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return None


def main():
    repo = Path(__file__).resolve().parent.parent
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--vendor", help="vendor:wgpu directory")
    ap.add_argument("--dawn", default=str(repo / "wgpu"), help="this repo's package directory")
    args = ap.parse_args()
    vendor = args.vendor
    if vendor is None:
        root = odin_root()
        if root is None:
            sys.exit("error: cannot run `odin root`, pass --vendor")
        vendor = str(Path(root) / "vendor" / "wgpu")

    dawn, wgpu = parse_package(args.dawn), parse_package(vendor)
    print(f"dawn:   {args.dawn}\nvendor: {vendor}")

    for kind in ("enum", "struct", "proc", "other"):
        a, b = set(dawn[kind]), set(wgpu[kind])
        print(f"\n===== {kind}: dawn {len(a)}, vendor {len(b)}, both {len(a & b)}")
        print("only dawn:  ", " ".join(sorted(a - b)) or "-")
        print("only vendor:", " ".join(sorted(b - a)) or "-")

    print("\n===== enum members that differ")
    for name in sorted(set(dawn["enum"]) & set(wgpu["enum"])):
        a, b = dawn["enum"][name], wgpu["enum"][name]
        only_a = [m for m in a if m not in b]
        only_b = [m for m in b if m not in a]
        values = [(m, a[m], b[m]) for m in a if m in b and a[m] and b[m] and int(a[m], 0) != int(b[m], 0)]
        if only_a or only_b or values:
            print(name)
            if only_a:
                print("  only dawn:  ", " ".join(only_a))
            if only_b:
                print("  only vendor:", " ".join(only_b))
            for m, va, vb in values:
                print(f"  {m}: dawn {va}, vendor {vb}")

    print("\n===== struct fields that differ")
    for name in sorted(set(dawn["struct"]) & set(wgpu["struct"])):
        a, b = dawn["struct"][name], wgpu["struct"][name]
        if [(n, norm_type(t)) for n, t in a] != [(n, norm_type(t)) for n, t in b]:
            print(name)
            print("  dawn:  ", ", ".join(f"{n}: {t}" for n, t in a))
            print("  vendor:", ", ".join(f"{n}: {norm_type(t)}" for n, t in b))

    print("\n===== proc signatures that differ (parameter types and results)")
    for name in sorted(set(dawn["proc"]) & set(wgpu["proc"])):
        (pa, ra), (pb, rb) = dawn["proc"][name], wgpu["proc"][name]
        types_a = [norm_type(p.partition(":")[2]) for p in pa]
        types_b = [norm_type(p.partition(":")[2]) for p in pb]
        if types_a != types_b or norm_type(ra) != norm_type(rb):
            print(name)
            print(f"  dawn:   ({', '.join(pa)}){' -> ' + ra if ra else ''}")
            print(f"  vendor: ({', '.join(pb)}){' -> ' + rb if rb else ''}")


if __name__ == "__main__":
    main()
