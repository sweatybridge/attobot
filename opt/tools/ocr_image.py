"""OCR an image to a spatial ASCII layout.

Ports the tetratorus/ascii-screenshot pipeline (via nanobot/utils/ascii_screenshot.py),
keeping only the RapidOCR backend.

Requires (install in the agent venv):
  pip install rapidocr-onnxruntime opencv-python
"""

import math
import os
import re

import cv2

NAME = "OCR_IMAGE"
DESCRIPTION = "Run OCR on an image and return an ASCII spatial layout — text placed at its approximate position, with detected lines overlaid as | and _. Use this when you cannot view images natively, or when layout matters (screenshots, forms, tables)."
PARAMETERS = {
    "type": "object",
    "properties": {
        "path": {"type": "string"},
        "canvas_width": {"type": "integer"},
    },
    "required": ["path"],
}

_WORD_SPLIT_RE = re.compile(
    r"(?<=[a-z])(?=[A-Z])"
    r"|(?<=[A-Z])(?=[A-Z][a-z])"
    r"|(?<=[a-zA-Z])(?=\d)"
    r"|(?<=\d)(?=[a-zA-Z])"
)


def _split_concatenated_text(text):
    if not text:
        return []
    result = []
    for part in text.split():
        result.extend([t for t in _WORD_SPLIT_RE.split(part) if t])
    return result


_engine = None


def _ocr_engine():
    global _engine
    if _engine is None:
        from rapidocr_onnxruntime import RapidOCR
        _engine = RapidOCR()
    return _engine


def _ocr_annotations(image_path):
    if not os.path.exists(image_path):
        return None
    img = cv2.imread(image_path)
    if img is None:
        return None
    ocr_result, _ = _ocr_engine()(img)
    if not ocr_result:
        return []
    img_h, img_w = img.shape[:2]
    annotations = []
    for bbox, text, score in ocr_result:
        if not text or not bbox:
            continue
        xs = [p[0] for p in bbox]
        ys = [p[1] for p in bbox]
        min_x, max_x = min(xs), max(xs)
        min_y, max_y = min(ys), max(ys)
        bbox_width = max(max_x - min_x, 1)
        norm_height = (max_y - min_y) / img_h
        norm_y = 1.0 - max_y / img_h
        words = _split_concatenated_text(text)
        if len(words) > 1:
            total_len = sum(len(w) for w in words)
            x_offset = min_x
            for word in words:
                ww = (len(word) / total_len) * bbox_width if total_len > 0 else bbox_width
                annotations.append({
                    "text": word,
                    "origin": {"x": x_offset / img_w, "y": norm_y},
                    "size": {"width": ww / img_w, "height": norm_height},
                })
                x_offset += ww
        else:
            annotations.append({
                "text": text,
                "origin": {"x": min_x / img_w, "y": norm_y},
                "size": {"width": (max_x - min_x) / img_w, "height": norm_height},
            })
    return annotations


def _group_words_in_sentence(line_annotations):
    grouped = []
    current = []
    for ann in line_annotations:
        if not current:
            current.append(ann)
            continue
        prev = current[-1]
        prev_w = prev["size"]["width"]
        prev_n = len(prev["text"])
        char_w = (prev_w / prev_n) * 2 if prev_n > 0 else prev_w
        next_x = prev["origin"]["x"] + prev_w
        if ann["origin"]["x"] <= next_x + char_w:
            current.append(ann)
        else:
            grouped.append(_merge_group(current))
            current = [ann]
    if current:
        grouped.append(_merge_group(current))
    return grouped


def _merge_group(group):
    seps = {".", ",", '"', "'", ":", ";", "!", "?", "{", "}", "’", "”"}
    parts = []
    for idx, w in enumerate(group):
        if w["text"] in seps:
            parts.append(w["text"])
        else:
            if idx > 0:
                parts.append(" ")
            parts.append(w["text"])
    return {
        "text": "".join(parts),
        "origin": {"x": group[0]["origin"]["x"], "y": group[0]["origin"]["y"]},
        "size": {
            "width": sum(w["size"]["width"] for w in group),
            "height": group[0]["size"]["height"],
        },
    }


def _format_text(ocr_data, canvas_width, canvas_height):
    line_cluster = {}
    for ann in ocr_data:
        y_key = math.floor((1 - ann["origin"]["y"]) * canvas_height)
        line_cluster.setdefault(y_key, []).append(ann)

    canvas = [[" "] * canvas_width for _ in range(canvas_height)]
    for y_key, line in line_cluster.items():
        row = max(0, min(y_key, canvas_height - 1))
        line.sort(key=lambda a: a["origin"]["x"])
        grouped = _group_words_in_sentence(line)
        last_x = 0
        for ann in grouped:
            text = ann["text"]
            x = math.floor(ann["origin"]["x"] * canvas_width)
            start_x = max(x, last_x)
            if start_x + len(text) >= canvas_width:
                for _ in range(len(text) + 1):
                    canvas[row].append(" ")
            for j, ch in enumerate(text):
                if start_x + j < canvas_width:
                    canvas[row][start_x + j] = ch
            last_x = start_x + len(text) + 1

    page = "\n".join("".join(row[:canvas_width]) for row in canvas)
    return "_" * canvas_width + "\n" + page + "\n" + "_" * canvas_width


def _edge_lines():
    return [
        {"text": "|", "origin": {"x": 0, "y": 0}, "size": {"width": 0, "height": 1}},
        {"text": "|", "origin": {"x": 1, "y": 0}, "size": {"width": 0, "height": 1}},
        {"text": "_", "origin": {"x": 0, "y": 0}, "size": {"width": 1, "height": 0}},
        {"text": "_", "origin": {"x": 0, "y": 1}, "size": {"width": 1, "height": 0}},
    ]


def _merge_lines(lines, axis):
    """axis = 'x' for vertical (|), 'y' for horizontal (_)."""
    remaining = list(lines)
    groups = []
    while remaining:
        head = remaining.pop(0)
        group = [head]
        i = 0
        while i < len(remaining):
            if abs(head["origin"][axis] - remaining[i]["origin"][axis]) < 0.01:
                group.append(remaining.pop(i))
            else:
                i += 1
        groups.append(group)
    merged = []
    span_axis = "y" if axis == "x" else "x"
    span_key = "height" if axis == "x" else "width"
    for group in groups:
        fixed = group[0]["origin"][axis]
        min_s = min(g["origin"][span_axis] for g in group)
        max_s = max(g["origin"][span_axis] + g["size"][span_key] for g in group)
        merged.append({
            "text": "|" if axis == "x" else "_",
            "origin": {axis: fixed, span_axis: min_s},
            "size": {span_key: max_s - min_s, "width" if axis == "x" else "height": 0},
        })
    return merged


def _detect_lines(image_path, img_w, img_h):
    try:
        img = cv2.imread(image_path, cv2.IMREAD_COLOR)
        if img is None:
            return _edge_lines()
        gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
        edges = cv2.Canny(gray, 20, 200, 3)
        lines = cv2.HoughLinesP(edges, 1, math.pi / 180, 800, minLineLength=50, maxLineGap=10)
        bboxes = []
        if lines is not None:
            for line in lines:
                x1, y1, x2, y2 = line[0]
                dx = x2 - x1
                dy = y2 - y1
                if abs(dx) < 5:
                    avg_x = (x1 + x2) / 2
                    bboxes.append({
                        "text": "|",
                        "origin": {"x": avg_x / img_w, "y": min(y1, y2) / img_h},
                        "size": {"width": 0, "height": abs(y1 - y2) / img_h},
                    })
                elif abs(dy) < 5:
                    avg_y = (y1 + y2) / 2
                    bboxes.append({
                        "text": "_",
                        "origin": {"x": min(x1, x2) / img_w, "y": avg_y / img_h},
                        "size": {"width": abs(x1 - x2) / img_w, "height": 0},
                    })
        bboxes.extend(_edge_lines())
        vertical = [b for b in bboxes if b["text"] == "|"]
        horizontal = [b for b in bboxes if b["text"] == "_"]
        return _merge_lines(vertical, "x") + _merge_lines(horizontal, "y")
    except Exception:
        return _edge_lines()


def _add_lines(ascii_lines, line_data, canvas_width, canvas_height):
    lines_canvas = [[" "] * canvas_width for _ in range(canvas_height)]
    for line in line_data:
        if line["text"] == "|":
            x = min(math.floor(line["origin"]["x"] * canvas_width), canvas_width - 1)
            start_y = max(math.floor(line["origin"]["y"] * canvas_height), 0)
            end_y = min(
                math.floor((line["origin"]["y"] + line["size"]["height"]) * canvas_height),
                canvas_height - 1,
            )
            for y in range(start_y, end_y + 1):
                lines_canvas[y][x] = "|"
        elif line["text"] == "_":
            y = min(math.floor(line["origin"]["y"] * canvas_height), canvas_height - 1)
            start_x = max(math.floor(line["origin"]["x"] * canvas_width), 0)
            end_x = min(
                start_x + math.floor(line["size"]["width"] * canvas_width),
                canvas_width - 1,
            )
            for x in range(start_x, end_x + 1):
                lines_canvas[y][x] = "_"

    ascii_rows = ascii_lines.split("\n")[1:-1]
    final_rows = []
    for row_idx, row in enumerate(ascii_rows):
        max_col = len(row)
        if row_idx < len(lines_canvas) and len(lines_canvas[row_idx]) < max_col:
            lines_canvas[row_idx].extend([" "] * (max_col - len(lines_canvas[row_idx])))
        new_row = []
        for col_idx, ch in enumerate(row):
            lc = lines_canvas[row_idx][col_idx] if row_idx < len(lines_canvas) and col_idx < len(lines_canvas[row_idx]) else " "
            if ch == " ":
                new_row.append(lc)
            elif lc == "_":
                new_row.append(ch + "̲")
            else:
                new_row.append(ch)
        final_rows.append("".join(new_row))
    return "\n".join(final_rows)


def run(args):
    path = args["path"]
    canvas_width = args.get("canvas_width", 80)
    try:
        ocr_data = _ocr_annotations(path)
        if ocr_data is None:
            return f"error: could not read image {path}"
        if not ocr_data:
            return f"(no text detected in {path})"
        img = cv2.imread(path)
        img_h, img_w = img.shape[:2]
        canvas_height = min(max(1, math.floor(canvas_width * img_h / img_w * 0.5)), 100)
        line_data = _detect_lines(path, img_w, img_h)
        ascii_text = _format_text(ocr_data, canvas_width, canvas_height)
        return _add_lines(ascii_text, line_data, canvas_width, canvas_height)
    except ImportError as e:
        return f"OCR_IMAGE not available: missing dep ({e}). Install rapidocr-onnxruntime and opencv-python."
    except Exception as e:
        return f"OCR error: {e}"
