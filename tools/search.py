from ddgs import DDGS

SCHEMA = {
    "type": "function",
    "function": {
        "name": "SEARCH",
        "description": "Search the web via DuckDuckGo. Returns title, URL, and snippet for up to 10 results.",
        "parameters": {"type": "object", "properties": {"query": {"type": "string"}, "n": {"type": "integer"}}, "required": ["query"]},
    },
}


def run(args):
    n = min(args.get("n", 5), 10)
    try:
        results = list(DDGS().text(args["query"], max_results=n))
        out = []
        for i, r in enumerate(results):
            out.append(f"{i+1}. {r['title']}\n   {r['href']}\n   {r['body']}")
        return "\n\n".join(out) or "(no results)"
    except Exception as e:
        return f"search error: {e}"
