"""One-time mechanical migration of existing reviewed translations to a catalog."""
import hashlib
import json
import re
from pathlib import Path

root = Path(__file__).resolve().parents[1]
sources = root / "Sources/ShenyingControl"
file = sources / "Localization.swift"
text = file.read_text()
quoted = r'"((?:[^"\\]|\\.)*)"'
messages_block = text.split("private static let messages:", 1)[1].split("private static let table:", 1)[0]
table_block = text.split("private static let table:", 1)[1].split("\n    ]", 1)[0]
decode = lambda value: json.loads('"' + value + '"')
pairs = [(decode(a), decode(b)) for a, b in re.findall(quoted + r"\s*:\s*" + quoted, messages_block)]
entries = {}
aliases = {}
def add(key, zh, en):
    entries[key] = {
        "extractionState": "manual",
        "localizations": {
            language: {"stringUnit": {"state": "translated", "value": value}}
            for language, value in [("en", en), ("zh-Hans", zh)]
        },
    }
for key, zh, en in re.findall(quoted + r"\s*:\s*\[\.chinese:\s*" + quoted + r",\s*\.english:\s*" + quoted, table_block):
    add(decode(key), decode(zh), decode(en))
for zh, en in pairs + [("后退", "Back"), ("前进", "Forward")]:
    key = re.sub(r"[^a-z0-9]+", "_", en.lower()).strip("_")[:70] or "message"
    if key in entries:
        key += "_" + hashlib.sha256(zh.encode()).hexdigest()[:8]
    add(key, zh, en)
    aliases[zh] = key
for key, zh, en in [
    ("language_system", "跟随系统", "System"),
    ("language_chinese", "简体中文", "简体中文"),
    ("dashboard_title", "仪表盘", "Dashboard"),
    ("apply_settings", "应用设置", "Apply Settings"),
]:
    add(key, zh, en)
catalog = {"sourceLanguage": "en", "strings": dict(sorted(entries.items())), "version": "1.0"}
(sources / "Localizable.xcstrings").write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + "\n")
lines = ["// Compatibility keys for cached hardware status; translations live in Localizable.xcstrings.",
         "enum LegacyLocalizationKeys {", "    static let aliases: [String: String] = ["]
for original, key in sorted(aliases.items()):
    lines.append(f"        {json.dumps(original, ensure_ascii=False)}: {json.dumps(key)},")
lines += ["    ]", "}"]
(sources / "LegacyLocalizationKeys.swift").write_text("\n".join(lines) + "\n")
for path in sources.glob("*.swift"):
    if path.name in ("Localization.swift", "LegacyLocalizationKeys.swift"):
        continue
    content = path.read_text()
    for original, key in aliases.items():
        content = content.replace('t(' + json.dumps(original, ensure_ascii=False) + ')', 't("' + key + '")')
    content = content.replace('t("dashboard")', 't("dashboard_title")')
    path.write_text(content)
start = text.index("    // Translate at the presentation boundary")
end = text.index("\n}\n", start)
file.write_text(text[:start] + text[end:])
print(f"Migrated {len(entries)} entries; {len(aliases)} legacy status aliases")
