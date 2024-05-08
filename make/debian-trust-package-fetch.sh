#!/usr/bin/env bash

# Copyright 2022 The cert-manager Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -o errexit
set -o nounset
set -o pipefail

# This script uses a container to install the latest ca-certificates package, and then
# checks to see if the installed version of that package matches the latest available
# debian trust package image in our container registry.

# If we installed a newer version in the local container, we build a new image container
# and push it upstream

CTR=${CTR:-docker}
BIN_VALIDATE_TRUST_PACKAGE=${BIN_VALIDATE_TRUST_PACKAGE:-}

DEBIAN_SOURCE_IMAGE=${1:-}
DESTINATION_FILE=${2:-}

## a) If these are set, we will fetch the specified version of ca-certificates
TARGET_DEBIAN_BUNDLE_VERSION=${3:-}

## b) If the TARGET_* variables are not set, we will fetch the latest version of ca-certificates
# Suffix to append to the version of ca-certificates package when we fetch the latest
# version. This will be used to create a PR to bump the version in the ./make/00_debian_version.mk file.
LATEST_VERSION_SUFFIX=".1"

function print_usage() {
	echo "usage: $0 <debian-source-image> <destination file> [target version]"
}

if ! command -v "$CTR" &>/dev/null; then
	print_usage
	echo "This script requires a docker CLI compatible runtime, either docker or podman"
	echo "If CTR is not set, defaults to using docker"
	echo "Couldn't find $CTR command; exiting"
	exit 1
fi

if [[ -z $BIN_VALIDATE_TRUST_PACKAGE ]]; then
	print_usage
	echo "BIN_VALIDATE_TRUST_PACKAGE must be set to the path of the validate-trust-package binary"
	exit 1
fi

if [[ -z $DEBIAN_SOURCE_IMAGE ]]; then
	print_usage
	echo "debian source image must be specified"
	exit 1
fi

if [[ -z $DESTINATION_FILE ]]; then
	print_usage
	echo "destination file must be specified"
	exit 1
fi

target_ca_certificates_version=""
if [[ -z $TARGET_DEBIAN_BUNDLE_VERSION ]]; then
	echo "no target version specified, will use the latest version"
else
	# strip the patch version from the target version
	target_ca_certificates_version=${TARGET_DEBIAN_BUNDLE_VERSION%.*}
	echo "target ca-certificates version specified: $target_ca_certificates_version"
fi

echo "+++ fetching latest version of ca-certificates package"

TMP_DIR=$(mktemp -d)

# register the cleanup function to be called on the EXIT signal
trap 'rm -rf -- "$TMP_DIR"' EXIT

# Install the latest version of ca-certificates in a fresh container and print the
# installed version

# There are several commands for querying remote repos (e.g. apt-cache madison) but
# it's not clear that these commands are guaranteed to return installable versions
# in order or in a parseable format

# We specifically only want to query the latest version and without a guarantee on
# output ordering it's safest to install what apt thinks is the latest version and
# then see what we got.

# NB: It's also very difficult to make 'apt-get' stay quiet when installing packages
# so we just let it be loud and then only take the last line of output

install_target="ca-certificates"
if [[ -n $target_ca_certificates_version ]]; then
	install_target="${install_target}=${target_ca_certificates_version}"
fi

cat << EOF > "$TMP_DIR/run.sh"
#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

apt-get -y update

DEBIAN_FRONTEND=noninteractive \
apt-get install -y --no-install-recommends ${install_target}

dpkg-query --show --showformat="\\\${Version}" ca-certificates | tail -n 1 > /workdir/version.txt

cp /etc/ssl/certs/ca-certificates.crt /workdir/ca-certificates.crt
EOF

$CTR run --rm --mount type=bind,source="$TMP_DIR",target=/workdir "$DEBIAN_SOURCE_IMAGE" /bin/bash /workdir/run.sh

INSTALLED_VERSION=$(cat "$TMP_DIR/version.txt")

echo "{}" | jq \
	--rawfile bundle /etc/ssl/certs/ca-certificates.crt \
	--arg name "cert-manager-debian" \
	--arg version "$INSTALLED_VERSION$LATEST_VERSION_SUFFIX" \
	'.name = $name | .bundle = $bundle | .version = $version' \
	> "$DESTINATION_FILE"

${BIN_VALIDATE_TRUST_PACKAGE} < "$DESTINATION_FILE"
