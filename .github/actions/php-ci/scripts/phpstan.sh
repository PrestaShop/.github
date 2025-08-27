#!/bin/bash
set -e

if [ $# -lt 3 ]; then
  echo "Usage: scripts/phpstan.sh [PrestaShop_version] [PHP_version] [Module_name] [Config_file (optional)]"
  exit 1
fi

PS_VERSION=$1
PHP_VERSION=$2
MODULE_NAME=$3
CUSTOM_CONFIG=$4   # optional
BASEDIR=$(dirname "$0")
MODULEDIR=$(cd "$BASEDIR/.." && pwd)

# Choose phpstan image version depending on PrestaShop version
if [[ "$PS_VERSION" == "latest" ]] || [[ "$(printf '%s\n' "$PS_VERSION" "9.0.0" | sort -V | head -n1)" == "9.0.0" ]]; then
  # PrestaShop >= 9.0.0 or "latest" → use phpstan 1.10
  PHPSTAN_IMAGE="ghcr.io/phpstan/phpstan:1.10.45-php${PHP_VERSION}"
else
  # PrestaShop < 9.0.0 → use phpstan 0.12
  PHPSTAN_IMAGE="ghcr.io/phpstan/phpstan:0.12.100-php${PHP_VERSION}"
fi

echo "Using PHPStan image: $PHPSTAN_IMAGE"

# Resolve config file
if [ -n "$CUSTOM_CONFIG" ]; then
  CONFIG_FILE=$CUSTOM_CONFIG
  echo "Using custom PHPStan config: $CONFIG_FILE"
else
  CONFIG_FILE="$MODULEDIR/tests/phpstan/phpstan-$PS_VERSION.neon"
  if [ ! -f "$CONFIG_FILE" ]; then
    echo "Configuration file for PrestaShop $PS_VERSION does not exist."
    echo "Please provide a custom config as 4th parameter."
    exit 2
  fi
  echo "Using default PHPStan config: $CONFIG_FILE"
fi

# Docker images prestashop/prestashop are used to get source files
echo "Pull PrestaShop files (Tag ${PS_VERSION})"

docker rm -f temp-ps || true
docker run -tid --rm -v ps-volume:/var/www/html -e DISABLE_MAKE=1 --name temp-ps prestashop/prestashop:$PS_VERSION-$PHP_VERSION

# Wait for docker initialization
until docker exec temp-ps ls /var/www/html/vendor/autoload.php 2> /dev/null; do
  echo "Waiting for docker initialization..."
  sleep 5
done

# Clear previous instance of the module in the PrestaShop volume
echo "Clear previous module and copy current one"
docker exec -t temp-ps rm -rf /var/www/html/modules/$MODULE_NAME

echo "Run PHPStan"
docker run --rm --volumes-from temp-ps \
       -v "$PWD":/var/www/html/modules/$MODULE_NAME \
       -e _PS_ROOT_DIR_=/var/www/html \
       -e DISABLE_MAKE=1 \
       --workdir=/var/www/html/modules/$MODULE_NAME $PHPSTAN_IMAGE \
       analyse \
       --error-format=github \
       --configuration=/var/www/html/modules/$MODULE_NAME/$(basename "$CONFIG_FILE")
