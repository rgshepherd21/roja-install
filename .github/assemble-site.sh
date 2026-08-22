#!/usr/bin/env bash
# Assemble the static site published at install.getroja.ai.
#
# Called by BOTH jobs in .github/workflows/pages.yml — `validate` (which runs
# on pull_request and must be able to fail) and `deploy` (which publishes).
# Keeping it in one file is the point: if validate assembled the site from a
# second copy of these lines, the check could pass while describing a site
# that differs from what actually ships.
#
# `set -euo pipefail` matters here. Without -e a failed cp leaves _site short
# a file and the job still exits 0, which is precisely the silent-success
# shape this check exists to prevent.
set -euo pipefail

rm -rf _site
mkdir -p _site

# The published set. Anything added here must also be advertised in
# index.html, and anything index.html advertises must appear here — the
# validate job asserts that both directions hold.
cp install.sh   _site/install.sh
cp install.ps1  _site/install.ps1
cp index.html   _site/index.html

# Apex CNAME for the Pages custom domain. Written rather than committed so
# the published set is assembled in exactly one place.
echo "install.getroja.ai" > _site/CNAME

ls -la _site/
