import re, requests

SCHEMA = {
    "type": "function",
    "function": {
        "name": "WEB_FETCH",
        "description": "Fetch and extract text from a URL.",
        "parameters": {"type": "object", "properties": {"url": {"type": "string"}}, "required": ["url"]},
    },
}


def run(args):
    try:
        r = requests.get(args["url"], headers={"User-Agent": "Mozilla/5.0"}, timeout=15)
        r.raise_for_status()
        text = r.text
        text = re.sub(r'<script[^>]*>.*?</script>', '', text, flags=re.DOTALL|re.IGNORECASE)
        text = re.sub(r'<style[^>]*>.*?</style>', '', text, flags=re.DOTALL|re.IGNORECASE)
        text = re.sub(r'<[^>]+>', ' ', text)
        text = re.sub(r'\s+', ' ', text).strip()
        return text[:5000]
    except Exception as e:
        return f"fetch error: {e}"
