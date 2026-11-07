#!/bin/sh
# Fills Formula/xcblame.rb from a built release tarball and prints the result.
# usage: Scripts/make-formula.sh <tarball> [url] [version] [output]
#   tarball  the .tar.gz made by `make dist-tarball` (its sha256 goes into the formula)
#   url      where the tarball will be downloaded from; default: a placeholder GitHub release URL
#   version  default: read from the tarball name (xcblame-<version>-macos-universal.tar.gz)
#   output   default: dist/xcblame.rb
# Nothing is published; the printed formula goes into the Homebrew tap by hand.
set -eu
cd "$(dirname "$0")/.."

tarball=${1:-}
url=${2:-}
version=${3:-}
output=${4:-dist/xcblame.rb}

if [ -z "$tarball" ] || [ ! -f "$tarball" ]; then
    echo "error: tarball '$tarball' not found; run 'make dist-binary dist-tarball' first" >&2
    exit 1
fi
name=$(basename "$tarball")
if [ -z "$version" ]; then
    version=${name#xcblame-}
    version=${version%-macos-universal.tar.gz}
fi
if [ -z "$url" ]; then
    url="https://github.com/OWNER/xcblame/releases/download/v${version}/${name}"
    echo "note: no URL given; using the placeholder $url" >&2
fi
case "$url" in
    */releases/download/*) homepage=${url%/releases/download/*} ;;
    *) homepage=$(dirname "$url") ;;
esac
sha256=$(shasum -a 256 "$tarball" | cut -d ' ' -f 1)

mkdir -p "$(dirname "$output")"
sed -e "s#__VERSION__#$version#g" -e "s#__URL__#$url#g" -e "s#__SHA256__#$sha256#g" \
    -e "s#__HOMEPAGE__#$homepage#g" Formula/xcblame.rb > "$output"
if grep -q '__[A-Z0-9]*__' "$output"; then
    echo "error: placeholders left in $output" >&2
    exit 1
fi
cat "$output"
