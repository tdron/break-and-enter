#!/usr/bin/env bash
# Rebuilds the local toolchain this repo's tools/ scripts need:
#
#   ~/.tools/venv            python env with pillow + numpy (render_preview.py) and pyflakes
#   ~/.tools/bin/luau        Luau interpreter (tests run against it)
#   ~/.tools/bin/luau-analyze
#   ~/.tools/ref/database.json              Roblox API dump (build_place.py --database)
#   ~/.tools/ref/globalTypes.None.d.luau    Roblox globals for luau-analyze
#
# Idempotent: re-running skips whatever is already there. Takes a few minutes
# the first time (it compiles Luau from source).
set -euo pipefail

TOOLS="${TOOLS:-$HOME/.tools}"
LUAU_VERSION="${LUAU_VERSION:-0.690}"
CODELOAD="https://codeload.github.com"
API="https://api.github.com"

# Prefers the authenticated gh CLI; falls back to plain curl.
if command -v gh >/dev/null 2>&1; then
	api_get() { gh api "$1"; }
	api_file() { gh api "$1" -H "Accept: application/vnd.github.raw" > "$2"; }
else
	api_get() { curl -fsSL "$API/repos/$1"; }
	api_file() { curl -fsSL -H "Accept: application/vnd.github.raw" "$API/repos/$1" -o "$2"; }
fi

mkdir -p "$TOOLS/bin" "$TOOLS/ref"

# cmake/ninja live in the venv: put them on PATH so cmake finds its build program.
export PATH="$TOOLS/venv/bin:$PATH"

echo "== python venv =="
if [ ! -x "$TOOLS/venv/bin/python" ]; then
	python3 -m venv "$TOOLS/venv"
fi
"$TOOLS/venv/bin/pip" install --quiet --upgrade pip
"$TOOLS/venv/bin/pip" install --quiet pillow numpy pyflakes cmake ninja

echo "== luau $LUAU_VERSION =="
if [ ! -x "$TOOLS/bin/luau-analyze" ]; then
	src="$TOOLS/src"
	rm -rf "$src"
	mkdir -p "$src"
	curl -fsSL "$CODELOAD/luau-lang/luau/tar.gz/refs/tags/$LUAU_VERSION" |
		tar xz -C "$src" --strip-components=1
	cmake -S "$src" -B "$src/build" -G Ninja \
		-DCMAKE_BUILD_TYPE=Release \
		-DLUAU_BUILD_CLI=ON \
		-DLUAU_BUILD_TESTS=OFF
	ninja -C "$src/build"
	find "$src/build" -maxdepth 2 -type f \( -name 'luau' -o -name 'luau-analyze' \) -executable \
		-exec cp {} "$TOOLS/bin/" \;
	rm -rf "$src"
fi
"$TOOLS/bin/luau" -h >/dev/null

echo "== roblox API database =="
if [ ! -s "$TOOLS/ref/database.json" ]; then
	# The dump has moved around rbx-dom before, so ask the repo tree where it is.
	tree=$(api_get "repos/rojo-rbx/rbx-dom/git/trees/master?recursive=1")
	path=$(printf '%s' "$tree" | tr ',' '\n' | sed -n 's/.*"path": *"\([^"]*database\.json\)".*/\1/p' | head -1)
	echo "   $path"
	api_file "repos/rojo-rbx/rbx-dom/contents/$path?ref=master" "$TOOLS/ref/database.json"
fi
python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$TOOLS/ref/database.json"
echo "   $(du -h "$TOOLS/ref/database.json" | cut -f1) database.json"

echo "== roblox globals for luau-analyze =="
if [ ! -s "$TOOLS/ref/globalTypes.None.d.luau" ]; then
	api_file "repos/JohnnyMorganz/luau-lsp/contents/scripts/globalTypes.None.d.luau?ref=main" \
		"$TOOLS/ref/globalTypes.None.d.luau"
fi
echo "   $(du -h "$TOOLS/ref/globalTypes.None.d.luau" | cut -f1) globalTypes.None.d.luau"

echo
echo "Toolchain ready:"
ls -1 "$TOOLS/bin" "$TOOLS/ref"
echo
echo "Run the tests with:  PATH=$TOOLS/bin:\$PATH python3 tools/run_luau_tests.py"
