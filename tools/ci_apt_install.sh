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

# GitHub's Ubuntu images read their mirrors from a list (mirror+file:/etc/apt/apt-mirrors.txt) whose first entry is Azure's
# mirror, and apt tries it again for every file. When its name doesn't resolve, each try waits for the timeout, so we point
# apt at Ubuntu's own archive instead.
MIRRORS=/etc/apt/apt-mirrors.txt
if [ -f "$MIRRORS" ]; then
	first_host=$(awk 'NF { print $1; exit }' "$MIRRORS" | sed -E 's|^[a-z+]+://||; s|/.*||')
	if [ -n "$first_host" ] && ! getent hosts "$first_host" >/dev/null; then
		echo "$first_host doesn't resolve: using archive.ubuntu.com directly"
		for sources in /etc/apt/sources.list /etc/apt/sources.list.d/*; do
			if [ -f "$sources" ] && grep -q "mirror+file:$MIRRORS" "$sources"; then
				sudo sed -i "s|mirror+file:$MIRRORS|http://archive.ubuntu.com/ubuntu/|" "$sources"
			fi
		done
	fi
fi

options=(-o Acquire::Retries=2 -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20)
sudo apt-get "${options[@]}" update
sudo apt-get "${options[@]}" install -y "${missing[@]}"
