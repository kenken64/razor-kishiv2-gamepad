#!/bin/sh
# Build and launch the Linux desktop receiver from any working directory.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if ! /usr/bin/python3 -c 'import gi; gi.require_version("Gtk", "3.0"); gi.require_version("WebKit2", "4.1"); gi.require_foreign("cairo")' 2>/dev/null; then
    echo 'Install desktop dependencies: sudo apt install python3-gi python3-gi-cairo gir1.2-gtk-3.0 gir1.2-webkit2-4.1' >&2
    exit 1
fi
cargo build --locked --release --manifest-path "$here/../server/Cargo.toml"
binary=$(cargo metadata --locked --no-deps --format-version 1 --manifest-path "$here/../server/Cargo.toml" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"] + "/release/padrelay-receiver")')
preview="$here/../macos/preview"
if [ ! -x "$preview/node_modules/.bin/esbuild" ]; then
    npm --prefix "$preview" ci --no-audit --no-fund
fi
mkdir -p "$here/build/preview"
"$preview/node_modules/.bin/esbuild" "$preview/preview.js" --bundle --minify --target=es2020 --outfile="$here/build/preview/scene.js"
cp "$preview/index.html" "$preview/style.css" "$here/build/preview/"
cp "$preview/node_modules/three/LICENSE" "$here/build/preview/three-LICENSE.txt"
exec /usr/bin/python3 "$here/receiver.py" --receiver "$binary" "$@"
