"""Bus: append (locked) for producers, read_new (cursor-tracked) for consumers."""
import fcntl, pathlib

def append(path, content):
    pathlib.Path(path).parent.mkdir(parents=True, exist_ok=True)
    with open(path, "a") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        f.write(content)

def read_new(stream_path, offset_path):
    try: pos = int(open(offset_path).read())
    except (FileNotFoundError, ValueError): pos = 0
    try: data = open(stream_path, "rb").read()
    except FileNotFoundError: return ""
    if pos > len(data): pos = 0
    new = data[pos:].decode("utf-8", errors="replace")
    pathlib.Path(offset_path).write_text(str(len(data)))
    return new
