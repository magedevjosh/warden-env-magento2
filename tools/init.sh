#!/usr/bin/env bash
set -eu
trap 'error "$(printf "Command \`%s\` on line $LINENO failed with exit code $?" "$BASH_COMMAND")"' ERR

## setup functions for use throughout the script
function warning {
  >&2 printf "\033[33mWARNING\033[0m: $@\n" 
}

function error {
  >&2 printf "\033[31mERROR\033[0m: $@\n"
}

function fatal {
  error "$@"
  exit -1
}

function version {
  echo "$@" | awk -F. '{ printf("%d%03d%03d%03d\n", $1,$2,$3,$4); }';
}

function :: {
  echo
  echo "==> [$(date +%H:%M:%S)] $@"
}

## find directory above where this script is located following symlinks if neccessary
readonly BASE_DIR="$(
  cd "$(
    dirname "$(
      (readlink "${BASH_SOURCE[0]}" || echo "${BASH_SOURCE[0]}") \
        | sed -e "s#^../#$(dirname "$(dirname "${BASH_SOURCE[0]}")")/#"
    )"
  )/.." >/dev/null \
  && pwd
)"
cd "${BASE_DIR}"

## load configuration needed for setup
source .env
WARDEN_WEB_ROOT="$(echo "${WARDEN_WEB_ROOT:-/}" | sed 's#^/#./#')"
REQUIRED_FILES=("${WARDEN_WEB_ROOT}/auth.json")
DB_DUMP="${DB_DUMP:-./backfill/magento-db.sql.gz}"
DB_IMPORT=1
CLEAN_INSTALL=
META_PACKAGE="magento/project-community-edition"
META_VERSION=""
URL_FRONT="https://${TRAEFIK_SUBDOMAIN}.${TRAEFIK_DOMAIN}/"
URL_ADMIN="https://${TRAEFIK_SUBDOMAIN}.${TRAEFIK_DOMAIN}/backend/"

## argument parsing
## parse arguments
while (( "$#" )); do
    case "$1" in
        --clean-install)
            REQUIRED_FILES+=("${WARDEN_WEB_ROOT}/app/etc/env.php.init.php")
            CLEAN_INSTALL=1
            DB_IMPORT=
            shift
            ;;
        --meta-package)
            shift
            META_PACKAGE="$1"
            shift
            ;;
        --meta-version)
            shift
            META_VERSION="$1"
            if
                ! test $(version "${META_VERSION}") -ge "$(version 2.3.4)" \
                && [[ ! "${META_VERSION}" =~ ^2\.[3-9]\.x$ ]]
            then
                fatal "Invalid --meta-version=${META_VERSION} specified (valid values are 2.3.4 or later and 2.[3-9].x)"
            fi
            shift
            ;;
        --skip-db-import)
            DB_IMPORT=
            shift
            ;;
        --db-dump)
            shift
            DB_DUMP="$1"
            shift
            ;;
        -h|--help)
            echo "Usage: $(basename $0) [--skip-db-import] [--db-dump <file>.sql.gz]"
            echo ""
            echo "       --clean-install              install from scratch rather than use existing database dump;"
            echo "                                    implied when no composer.json file is present in web root" 
            echo "       --meta-package               passed to 'composer create-project' when --clean-install is"
            echo "                                    specified and defaults to 'magento/project-community-edition'"
            echo "       --meta-version               specify alternate version to install; defaults to latest; may"
            echo "                                    be (for example) specified as 2.3.x (latest minor) or 2.3.4"
            echo "       --skip-db-import             skips over db import (assume db has already been imported)"
            echo "       --db-dump <file>.sql.gz      expects path to .sql.gz file for import during init"
            echo ""
            exit -1
            ;;
        *)
            error "Unrecognized argument '$1'"
            exit -1
            ;;
    esac
done

## if no composer.json is present in web root imply --clean-install flag when not specified explicitly
if [[ ! ${CLEAN_INSTALL} ]] && [[ ! -f "${WARDEN_WEB_ROOT}/composer.json" ]]; then
  warning "Implying --clean-install since file ${WARDEN_WEB_ROOT}/composer.json not present"
  REQUIRED_FILES+=("${WARDEN_WEB_ROOT}/app/etc/env.php.init.php")
  CLEAN_INSTALL=1
  DB_IMPORT=
fi

## include check for DB_DUMP file only when database import is expected
[[ ${DB_IMPORT} ]] && REQUIRED_FILES+=("${DB_DUMP}" "${WARDEN_WEB_ROOT}/app/etc/env.php.warden.php")

:: Verifying configuration
INIT_ERROR=

## attempt to install mutagen if not already present
if [[ $OSTYPE =~ ^darwin ]] && ! which mutagen 2>/dev/null >/dev/null && which brew 2>/dev/null >/dev/null; then
    warning "Mutagen could not be found; attempting install via brew."
    brew install havoc-io/mutagen/mutagen
fi

## check for presence of host machine dependencies
for DEP_NAME in warden mutagen docker-compose pv; do
  if [[ "${DEP_NAME}" = "mutagen" ]] && [[ ! $OSTYPE =~ ^darwin ]]; then
    continue
  fi

  if ! which "${DEP_NAME}" 2>/dev/null >/dev/null; then
    error "Command '${DEP_NAME}' not found. Please install."
    INIT_ERROR=1
  fi
done

## verify warden version constraint
WARDEN_VERSION=$(warden version 2>/dev/null) || true
WARDEN_REQUIRE=0.2.0
if ! test $(version ${WARDEN_VERSION}) -ge $(version ${WARDEN_REQUIRE}); then
  error "Warden ${WARDEN_REQUIRE} or greater is required (version ${WARDEN_VERSION} is installed)"
  INIT_ERROR=1
fi

## verify docker is running
if ! docker system info >/dev/null 2>&1; then
    error "Docker does not appear to be running. Please start Docker."
    INIT_ERROR=1
fi

## copy global Marketplace credentials into webroot to satisfy REQUIRED_FILES list; in ideal
## configuration the per-project auth.json will already exist with project specific keys
if [[ ! -f "${WARDEN_WEB_ROOT}/auth.json" ]] && [[ -f ~/.composer/auth.json ]]; then
  if docker run --rm -v ~/.composer/auth.json:/tmp/auth.json \
      composer config -g http-basic.repo.magento.com >/dev/null 2>&1
  then
    warning "Configuring ${WARDEN_WEB_ROOT}/auth.json with global credentials for repo.magento.com"
    echo "{\"http-basic\":{\"repo.magento.com\":$(
      docker run --rm -v ~/.composer/auth.json:/tmp/auth.json composer config -g http-basic.repo.magento.com
    )}}" > ${WARDEN_WEB_ROOT}/auth.json
  fi
fi

## verify mutagen version constraint
MUTAGEN_VERSION=$(mutagen version 2>/dev/null) || true
MUTAGEN_REQUIRE=0.10.3
if [[ $OSTYPE =~ ^darwin ]] && ! test $(version ${MUTAGEN_VERSION}) -ge $(version ${MUTAGEN_REQUIRE}); then
  error "Mutagen ${MUTAGEN_REQUIRE} or greater is required (version ${MUTAGEN_VERSION} is installed)"
  INIT_ERROR=1
fi

## check for presence of local configuration files to ensure they exist
for REQUIRED_FILE in ${REQUIRED_FILES[@]}; do
  if [[ ! -f "${REQUIRED_FILE}" ]]; then
    error "Missing local file: ${REQUIRED_FILE}"
    INIT_ERROR=1
  fi
done

## exit script if there are any missing dependencies or configuration files
[[ ${INIT_ERROR} ]] && exit 1

:: Starting Warden
warden up
if [[ ! -f ~/.warden/ssl/certs/${TRAEFIK_DOMAIN}.crt.pem ]]; then
    warden sign-certificate ${TRAEFIK_DOMAIN}
fi

:: Initializing environment
warden env pull --ignore-pull-failures || true
warden env build --pull
warden env up -d

## wait for mariadb to start listening for connections
warden shell -c "while ! nc -z db 3306 </dev/null; do sleep 2; done"

## start sync session on macOS where Warden is too old to automatically start mutagen sync
if [[ $OSTYPE =~ ^darwin ]] && test $(version ${WARDEN_VERSION}) -lt $(version 0.3.0); then
  warden sync start
fi

if [[ ${CLEAN_INSTALL} ]] && [[ ! -f "${WARDEN_WEB_ROOT}/composer.json" ]]; then
  :: Installing meta-package
  warden env exec -T php-fpm composer create-project -q --no-interaction --prefer-dist --no-install \
      --repository-url=https://repo.magento.com/ "${META_PACKAGE}" /tmp/create-project "${META_VERSION}"
  warden env exec -T php-fpm rsync -a /tmp/create-project/ /var/www/html/
fi

:: Installing dependencies
warden env exec -T php-fpm composer global require hirak/prestissimo
warden env exec -T php-fpm composer install

## import database only if --skip-db-import is not specified
if [[ ${DB_IMPORT} ]]; then
  :: Importing database
  warden db connect -e 'drop database magento; create database magento;'
  pv "${DB_DUMP}" | gunzip -c | warden db import
elif [[ ${CLEAN_INSTALL} ]]; then
  :: Installing application
  warden env exec -- -T php-fpm rm -vf app/etc/config.php app/etc/env.php
  warden env exec -- -T php-fpm bin/magento setup:install \
      --cleanup-database \
      --backend-frontname=backend \
      --amqp-host=rabbitmq \
      --amqp-port=5672 \
      --amqp-user=guest \
      --amqp-password=guest \
      --consumers-wait-for-messages=0 \
      --db-host=db \
      --db-name=magento \
      --db-user=magento \
      --db-password=magento \
      --http-cache-hosts=varnish:80 \
      --session-save=redis \
      --session-save-redis-host=redis \
      --session-save-redis-port=6379 \
      --session-save-redis-db=2 \
      --session-save-redis-max-concurrency=20 \
      --cache-backend=redis \
      --cache-backend-redis-server=redis \
      --cache-backend-redis-db=0 \
      --cache-backend-redis-port=6379 \
      --page-cache=redis \
      --page-cache-redis-server=redis \
      --page-cache-redis-db=1 \
      --page-cache-redis-port=6379

  :: Configuring application
  warden env exec -T php-fpm php -r '
    $env = "<?php\nreturn " . var_export(array_merge_recursive(
      include("app/etc/env.php"),
      include("app/etc/env.php.init.php")
    ), true) . ";\n";
    file_put_contents("app/etc/env.php", $env);
  '
  warden env exec -T php-fpm cp -n app/etc/env.php app/etc/env.php.warden.php
  warden env exec -T php-fpm ln -fsn env.php.warden.php app/etc/env.php
  warden env exec -T php-fpm bin/magento app:config:import

  warden env exec -T php-fpm bin/magento config:set -q --lock-env web/unsecure/base_url ${URL_FRONT}
  warden env exec -T php-fpm bin/magento config:set -q --lock-env web/secure/base_url ${URL_FRONT}

  warden env exec -T php-fpm bin/magento deploy:mode:set -s developer
  warden env exec -T php-fpm bin/magento cache:disable block_html full_page
  warden env exec -T php-fpm bin/magento app:config:dump themes scopes i18n

  :: Rebuilding indexes
  warden env exec -T php-fpm bin/magento indexer:reindex
fi

if [[ ! ${CLEAN_INSTALL} ]]; then
  :: Configuring application
  warden env exec -T php-fpm ln -fsn env.php.warden.php app/etc/env.php

  :: Updating application
  warden env exec -T php-fpm bin/magento cache:flush
  warden env exec -T php-fpm bin/magento app:config:import
  warden env exec -T php-fpm bin/magento setup:db-schema:upgrade
  warden env exec -T php-fpm bin/magento setup:db-data:upgrade
fi

:: Flushing cache
warden env exec -T php-fpm bin/magento cache:flush

:: Creating admin user
ADMIN_PASS=$(warden env exec -T php-fpm pwgen -n1 16)
ADMIN_USER=localadmin

warden env exec -T php-fpm bin/magento admin:user:create \
    --admin-password="${ADMIN_PASS}" \
    --admin-user="${ADMIN_USER}" \
    --admin-firstname="Local" \
    --admin-lastname="Admin" \
    --admin-email="${ADMIN_USER}@example.com"

:: Initialization complete
function print_install_info {
    FILL=$(printf "%0.s-" {1..128})
    C1_LEN=8
    let "C2_LEN=${#URL_ADMIN}>${#ADMIN_PASS}?${#URL_ADMIN}:${#ADMIN_PASS}"

    # note: in CentOS bash .* isn't supported (is on Darwin), but *.* is more cross-platform
    printf "+ %*.*s + %*.*s + \n" 0 $C1_LEN $FILL 0 $C2_LEN $FILL
    printf "+ %-*s + %-*s + \n" $C1_LEN FrontURL $C2_LEN "$URL_FRONT"
    printf "+ %*.*s + %*.*s + \n" 0 $C1_LEN $FILL 0 $C2_LEN $FILL
    printf "+ %-*s + %-*s + \n" $C1_LEN AdminURL $C2_LEN "$URL_ADMIN"
    printf "+ %*.*s + %*.*s + \n" 0 $C1_LEN $FILL 0 $C2_LEN $FILL
    printf "+ %-*s + %-*s + \n" $C1_LEN Username $C2_LEN "$ADMIN_USER"
    printf "+ %*.*s + %*.*s + \n" 0 $C1_LEN $FILL 0 $C2_LEN $FILL
    printf "+ %-*s + %-*s + \n" $C1_LEN Password $C2_LEN "$ADMIN_PASS"
    printf "+ %*.*s + %*.*s + \n" 0 $C1_LEN $FILL 0 $C2_LEN $FILL
}
print_install_info
