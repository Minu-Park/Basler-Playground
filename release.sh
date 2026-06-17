#!/usr/bin/env bash
# Local release helper for basler-playground.
# Requires: git, GitHub CLI (`gh auth login`), and access to the private Playground repository.

set -euo pipefail

PLAYGROUND_REPO="${PLAYGROUND_REPO:-git@github.com:minu-park/playground.git}"
PLAYGROUND_TAG="${1:-}"

if [[ -z "$PLAYGROUND_TAG" ]]; then
  echo "Usage: ./release.sh vX.Y.Z" >&2
  exit 1
fi

if [[ ! "$PLAYGROUND_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]]; then
  echo "Playground tag must look like vX.Y.Z." >&2
  exit 1
fi

command -v git >/dev/null
command -v gh >/dev/null
gh auth status >/dev/null

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKOUT_DIR="$ROOT_DIR/playground"
DIST_DIR="$ROOT_DIR/dist"

if [[ ! -d "$CHECKOUT_DIR/.git" ]]; then
  git clone --filter=blob:none "$PLAYGROUND_REPO" "$CHECKOUT_DIR"
fi

git -C "$CHECKOUT_DIR" fetch --tags origin
git -C "$CHECKOUT_DIR" checkout --force "$PLAYGROUND_TAG"
# Initialize Playground's own private/internal submodules after the tag checkout.
git -C "$CHECKOUT_DIR" submodule update --init --recursive

if [[ -d "$ROOT_DIR/pylon" ]]; then
  export PLAYGROUND_LOCAL_PYLON_RUNTIME_DIR="$ROOT_DIR/pylon"
fi

if [[ -x "$CHECKOUT_DIR/package_bundle.sh" ]]; then
  (cd "$CHECKOUT_DIR" && ./package_bundle.sh Release)
elif [[ -f "$CHECKOUT_DIR/package_bundle.sh" ]]; then
  (cd "$CHECKOUT_DIR" && bash ./package_bundle.sh Release)
else
  echo "No package_bundle.sh found in Playground checkout." >&2
  exit 1
fi

mkdir -p "$DIST_DIR"
mapfile -t BUNDLE_FILES < <(
  find "$CHECKOUT_DIR/build/bundle" -maxdepth 1 -type f \
    \( -name '*.dmg' -o -name '*.pkg' -o -name '*.deb' -o -name '*.AppImage' -o -name '*.tar.gz' -o -name '*.zip' \) \
    | sort
)

if [[ "${#BUNDLE_FILES[@]}" -eq 0 ]]; then
  echo "No release asset found under playground/build/bundle." >&2
  exit 1
fi

COMMIT="$(git -C "$CHECKOUT_DIR" rev-parse HEAD)"
gh release create "$PLAYGROUND_TAG" "${BUNDLE_FILES[@]}" \
  --title "Basler Playground $PLAYGROUND_TAG" \
  --notes "Installer built from private Playground tag $PLAYGROUND_TAG ($COMMIT)." \
  --draft
