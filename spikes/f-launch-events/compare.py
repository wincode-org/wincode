"""Compare the lifecycle events a plugin recorded in each variant of the sample app (spike F).

Usage: python3 compare.py <out dir>   (reads <out dir>/logs/<variant>/<scenario>.log, writes <out dir>/summary.md)

A is the stock storyboard launch. The others make the window in code: B as winCode's runner did, C and D with a fix.
Each line of a log is "<number> <event> <details>"; the number is dropped, so only the events and their order are compared.
"""
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
VARIANTS = {
    "A": "storyboard (the Flutter template)",
    "B": "window in code, init()",
    "C": "window in code, init(coder:) + awakeFromNib()",
    "D": "window in code, init() + Flutter's fallback selectors",
}
SCENARIOS = {
    "cold": "a normal launch",
    "cold-url": "a cold launch from a URL (xcrun simctl openurl on a stopped app)",
    "warm-url": "a launch, then a URL while the app runs",
}


def load(variant, scenario):
    path = root / "logs" / variant / f"{scenario}.log"
    if not path.exists():
        return None
    return [re.sub(r"^\d+ ", "", line) for line in path.read_text().splitlines() if line.strip()]


def verdict(events, reference):
    if events is None:
        return "NO LOG (the app did not run, or wrote nothing)"
    if reference is None:
        return "no reference to compare with"
    missing = [e for e in reference if e not in events]
    extra = [e for e in events if e not in reference]
    common_here = [e for e in events if e in reference]
    common_ref = [e for e in reference if e in events]
    parts = []
    if missing:
        parts.append(f"missing {len(missing)}: " + "; ".join(missing))
    if extra:
        parts.append(f"extra {len(extra)}: " + "; ".join(extra))
    if common_here != common_ref:
        parts.append("the common events are in a different order")
    return "identical to A, same order" if not parts else " | ".join(parts)


lines = ["# Lifecycle events a plugin receives: storyboard launch against a window made in code", ""]
for scenario, what in SCENARIOS.items():
    lines += [f"## {scenario}: {what}", ""]
    reference = load("A", scenario)
    for variant, name in VARIANTS.items():
        events = load(variant, scenario)
        lines += [f"### {variant}: {name}", "", f"**{'reference' if variant == 'A' else verdict(events, reference)}**", "", "```"]
        lines += events if events is not None else ["(no log)"]
        lines += ["```", ""]
text = "\n".join(lines)
(root / "summary.md").write_text(text)
print(text)
