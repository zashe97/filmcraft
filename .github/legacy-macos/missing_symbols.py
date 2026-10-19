#!/usr/bin/env python3
"""Lists the symbols a Mach-O binary imports that macOS 10.12 does not have.

Usage: missing_symbols.py <MacOSX10.12.sdk> <binary>... (reads `nm -m -u` output, so run on macOS
or with llvm-nm). Prints one line per missing symbol: "<weak|STRONG> <symbol> (from <library>)".
A STRONG one stops the app at launch on 10.12; a weak one is NULL there and only crashes if used.
Exit code 1 when any STRONG symbol is missing.
"""
import os, re, subprocess, sys

def sdk_symbols(sdk):
    have = set()
    item = re.compile(r"[A-Za-z_$.][\w$.:]*")
    for dirpath, _, files in os.walk(sdk):
        for f in files:
            if not f.endswith(".tbd"):
                continue
            kind = None
            for line in open(os.path.join(dirpath, f), errors="replace"):
                m = re.match(r"\s*(?:-\s*)?(symbols|weak-def-symbols|objc-classes|objc-ivars|objc-eh-types|thread-local-symbols|re-exports|archs|install-name|current-version|compatibility-version|exports|undefineds|[a-z-]+):", line)
                if m:
                    kind = m.group(1)
                    line = line[m.end():]
                if kind in ("symbols", "weak-def-symbols", "objc-classes", "objc-ivars", "objc-eh-types", "thread-local-symbols"):
                    for s in item.findall(line.replace("'", " ")):
                        if kind == "objc-classes":
                            s = s.lstrip("_")
                            have.update({f"_OBJC_CLASS_$_{s}", f"_OBJC_METACLASS_$_{s}"})
                        elif kind == "objc-ivars":
                            have.add(f"_OBJC_IVAR_$_{s.lstrip('_')}")
                        elif kind == "objc-eh-types":
                            have.add(f"_OBJC_EHTYPE_$_{s.lstrip('_')}")
                        else:
                            have.add(s)
    return have

def main():
    sdk, bins = sys.argv[1], sys.argv[2:]
    have = sdk_symbols(sdk)
    nm = os.environ.get("NM", "nm")
    strong = 0
    for b in bins:
        out = subprocess.run([nm, "-m", "-u", b], capture_output=True, text=True, check=True).stdout
        for line in out.splitlines():
            m = re.match(r"\s*\(undefined\)\s*(weak\s+)?(?:external\s+)?(\S+)\s*\(from ([^)]+)\)", line)
            if not m:
                continue
            weak, sym, lib = m.groups()
            if lib in ("libSystem", "libobjc", "libc++", "libc++abi", "libresolv", "libiconv", "libz") and sym in have:
                continue
            if sym not in have:
                print(f"{'weak' if weak else 'STRONG'} {sym} (from {lib}) in {os.path.basename(b)}")
                strong += 0 if weak else 1
    sys.exit(1 if strong else 0)

main()
