#!/bin/sh
# Fetches the Arch/CachyOS `ruby-docs` package (~670 MB — mostly C-API HTML)
# and extracts ONLY the ri documentation database into
#   ~/.local/share/ruby-bible/ri/<abi>/system
# No root required. ruby-bible picks it up automatically on next start.
set -eu

ver="$(ruby -e 'print RUBY_VERSION')"
pkg="ruby-docs-${ver}-1-x86_64.pkg.tar.zst"
mirror="https://geo.mirror.pkgbuild.com/extra/os/x86_64"
dest="${HOME}/.local/share/ruby-bible"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "==> downloading $pkg (~670 MB) from Arch mirror"
curl -fLo "$tmp/$pkg" "$mirror/$pkg"

echo "==> extracting usr/share/ri"
bsdtar -x -f "$tmp/$pkg" -C "$tmp" usr/share/ri

echo "==> installing to $dest"
mkdir -p "$dest"
rm -rf "$dest/ri"
mv "$tmp/usr/share/ri" "$dest/ri"

echo "==> done. ruby-bible will now show 'docs: core + gems'."
