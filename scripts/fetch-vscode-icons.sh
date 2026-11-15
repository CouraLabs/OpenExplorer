#!/bin/bash
# Downloads the vscode-icons extension (MIT, https://github.com/vscode-icons/vscode-icons) from Open VSX
# and extracts the SVG icons plus a compact name/extension → icon mapping into Resources/vscode-icons.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="13.0.0"
URL="https://open-vsx.org/api/vscode-icons-team/vscode-icons/${VERSION}/file/vscode-icons-team.vscode-icons-${VERSION}.vsix"
OUT="Resources/vscode-icons"
WORK="build/vscode-icons-download"

rm -rf "$WORK"
mkdir -p "$WORK"
echo "Downloading vscode-icons ${VERSION}…"
curl -fsSL -o "$WORK/pkg.vsix" "$URL"
unzip -q "$WORK/pkg.vsix" 'extension/icons/*' 'extension/dist/src/vsicons-icon-theme-zed.json' 'extension/LICENSE.txt' -d "$WORK"

rm -rf "$OUT"
mkdir -p "$OUT/icons"

# Build mapping.json from the Zed theme manifest (it maps suffixes directly, without VS Code language IDs).
python3 -I - "$WORK/extension/dist/src/vsicons-icon-theme-zed.json" "$OUT/mapping.json" "$VERSION" <<'PY'
import json, os, sys
src, dst, version = sys.argv[1], sys.argv[2], sys.argv[3]
themes = {t["name"]: t for t in json.load(open(src))["themes"]}

def name(path):
    return os.path.basename(path)

def convert(theme):
    icons = {key: name(v["path"]) for key, v in theme["file_icons"].items()}
    resolve = lambda table: {k: icons[v] for k, v in table.items() if v in icons}
    return {
        "stems": resolve(theme["file_stems"]),
        "suffixes": resolve(theme["file_suffixes"]),
        "folders": {k.lower(): [name(v["collapsed"]), name(v["expanded"])]
                    for k, v in theme["named_directory_icons"].items()},
        "defaultFile": icons.get("default", "default_file.svg"),
        "defaultFolder": [name(theme["directory_icons"]["collapsed"]), name(theme["directory_icons"]["expanded"])],
    }

mapping = {
    "version": version,
    "dark": convert(themes["VSCode Icons for Zed (Dark)"]),
    "light": convert(themes["VSCode Icons for Zed (Light)"]),
}

# Fixes for entries VS Code resolves through language IDs (missing or wrong in the Zed manifest).
OVERRIDES = {
    "suffixes": {"css": "file_type_css.svg", "graphql": "file_type_graphql.svg", "gql": "file_type_graphql.svg"},
    "stems": {"Makefile": "file_type_gnu.svg", "makefile": "file_type_gnu.svg", "GNUmakefile": "file_type_gnu.svg"},
}
for variant in ("dark", "light"):
    for table, entries in OVERRIDES.items():
        mapping[variant][table].update(entries)
json.dump(mapping, open(dst, "w"), separators=(",", ":"), sort_keys=True)
used = set()
for variant in ("dark", "light"):
    m = mapping[variant]
    used |= set(m["stems"].values()) | set(m["suffixes"].values())
    used |= {i for pair in m["folders"].values() for i in pair}
    used |= {m["defaultFile"], *m["defaultFolder"]}
open(dst + ".files", "w").write("\n".join(sorted(used)))
print(f"mapping: {len(mapping['dark']['suffixes'])} suffixes, {len(mapping['dark']['stems'])} file names, "
      f"{len(mapping['dark']['folders'])} folders, {len(used)} icons")
PY

# Copy only the icons the mapping uses.
while IFS= read -r file; do
    [ -f "$WORK/extension/icons/$file" ] && cp "$WORK/extension/icons/$file" "$OUT/icons/"
done < "$OUT/mapping.json.files"
rm "$OUT/mapping.json.files"
cp "$WORK/extension/LICENSE.txt" "$OUT/LICENSE.txt"
rm -rf "$WORK"
echo "Installed $(ls "$OUT/icons" | wc -l | tr -d ' ') icons into $OUT"
