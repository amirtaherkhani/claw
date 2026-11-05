#!/bin/sh
# Rebuilds Sources/ClawApp/Resources/Localizable.xcstrings from the strings the compiler finds in ClawApp.
# Run it after changing UI text (macOS only). Translations already in the catalog are kept.
set -eu

cd "$(dirname "$0")/.."
catalog=Sources/ClawApp/Resources/Localizable.xcstrings
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

[ -f "$catalog" ] || printf '{"sourceLanguage":"en","strings":{},"version":"1.0"}\n' >"$catalog"
swift build --product ClawApp --scratch-path "$work" -Xswiftc -emit-localized-strings >/dev/null

set --
for source in Sources/ClawApp/*.swift; do
    data=$(find "$work" -path '*ClawApp*' -name "$(basename "$source" .swift).stringsdata" | head -n 1)
    # A missing file would only warn, and sync would then mark every string as gone.
    [ -n "$data" ] || { echo "error: no strings extracted for $source" >&2; exit 1; }
    set -- "$@" "$data"
done
xcrun xcstringstool sync "$catalog" --stringsdata "$@"
