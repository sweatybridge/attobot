"""Bus: append (locked) for producers, read_new (cursor-tracked) for consumers."""
import fcntl, os, pathlib

def append(path, content):
    p = pathlib.Path(path)
    # ensure both the symlink's parent and the resolved target's parent exist
    p.parent.mkdir(parents=True, exist_ok=True)
    p.resolve().parent.mkdir(parents=True, exist_ok=True)
    with open(path, "a") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        try:
            f.write(content)
        finally:
            fcntl.flock(f, fcntl.LOCK_UN)

def read_new(stream_path, offset_path):
    try: pos = int(open(offset_path).read())
    except (FileNotFoundError, ValueError): pos = 0
    try: data = open(stream_path, "rb").read()
    except FileNotFoundError: return ""
    if pos > len(data): pos = 0  # rotated/truncated
    new = data[pos:].decode("utf-8", errors="replace")
    pathlib.Path(offset_path).write_text(str(len(data)))
    return new
