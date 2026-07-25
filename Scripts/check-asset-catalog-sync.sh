#!/bin/bash
# ConvosComposer carries its own copy of the design-system assets so the
# package has no dependency on the app target. This check fails when a shared
# colorset/imageset diverges between the two catalogs - otherwise a designer
# editing the app catalog silently leaves the conversation UI (rendered from
# the package copy) on stale values.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_CATALOG="Convos/Assets.xcassets"
PKG_CATALOG="ConvosCore/Sources/ConvosComposer/Resources/Assets.xcassets"
status=0

for asset in "$PKG_CATALOG"/*.colorset "$PKG_CATALOG"/*.imageset; do
    [ -d "$asset" ] || continue
    name=$(basename "$asset")
    app_asset="$APP_CATALOG/$name"
    # Package-only assets have no app counterpart to drift from.
    [ -d "$app_asset" ] || continue
    if ! diff -rq "$app_asset" "$asset" > /dev/null; then
        echo "error: asset '$name' differs between $APP_CATALOG and the ConvosComposer copy."
        echo "       Sync the package copy (or consolidate) before merging."
        status=1
    fi
done

if [ "$status" -eq 0 ]; then
    echo "Asset catalogs in sync."
fi
exit $status
