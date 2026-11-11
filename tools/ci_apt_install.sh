#!/usr/bin/env bash
# Installs the Debian packages that aren't installed yet, for CI. The runner images have most of them, and then apt doesn't run
# at all; when it must, it gives up on a mirror that doesn't answer after a few tries instead of retrying for ten minutes.
#
#   tools/ci_apt_install.sh <package>...

set -euo pipefail

missing=()
for package in "$@"; do
	if ! dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'install ok installed'; then
		missing+=("$package")
	fi
done
if [ ${#missing[@]} -eq 0 ]; then
	echo "Installed already: $*"
	exit 0
fi
echo "Installing: ${missing[*]}"
options=(-o Acquire::Retries=2 -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20)
sudo apt-get "${options[@]}" update
sudo apt-get "${options[@]}" install -y "${missing[@]}"
