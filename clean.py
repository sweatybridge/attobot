#!/usr/bin/env python3
"""Clean runtime artifacts."""
import os, shutil, sys

DIRS = ["agents", "blobs", "bus"]

def main():
    what = sys.argv[1:] if len(sys.argv) > 1 else ["all"]
    targets = DIRS if "all" in what else [d for d in what if d in DIRS]
    if not targets:
        print(f"usage: clean.py [all | {' | '.join(DIRS)}]")
        return
    for d in targets:
        if not os.path.isdir(d):
            continue
        entries = os.listdir(d)
        if not entries:
            print(f"{d}/ already clean")
            continue
        for e in entries:
            p = os.path.join(d, e)
            if os.path.isdir(p):
                shutil.rmtree(p)
            else:
                os.remove(p)
        print(f"{d}/ cleaned ({len(entries)} entries)")

if __name__ == "__main__":
    main()
