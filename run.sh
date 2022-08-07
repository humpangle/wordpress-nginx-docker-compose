#!/bin/bash
# shellcheck disable=1090

set -e

function _env {
  local env
  local splitted_envs=""

  if [[ -n "$1" ]]; then
    env="$1"
  elif [[ -e .env ]]; then
    env=".env"
  fi

  if [[ -n "$env" ]]; then
    set -a
    . $env
    set +a

    splitted_envs=$(splitenvs "$env" --lines)
  fi

  printf "%s" "$splitted_envs"
}

function _wait_until {
  command="${1}"
  timeout="${2:-30}"

  echo -e "\n\n\n=Running: $command=\n\n"

  i=0
  until eval "${command}"; do
    ((i++))

    if [ "${i}" -gt "${timeout}" ]; then
      echo -e "\n\n\n=Command: $command="
      echo -e "failed, aborting due to ${timeout}s timeout!\n\n"
      exit 1
    fi

    sleep 1
  done

  echo -e "\n\n\n= Done successfully running: $command =\n\n"
}

function _timestamp {
  date +'%s'
}

function _raise_on_no_env_file {
  if [[ -n "$DOCKER_ENV_FILE" ]]; then
    return 0
  fi

  if [[ -z "$1" ]] || [[ ! -e "$1" ]]; then
    printf "\nenv filename has not been provided or invalid.\n"
    printf "You may also source your environment file.\n\n"
    exit 1
  fi
}

function _has_internet {
  if ping -q -c 1 -W 1 8.8.8.8 >/dev/null; then
    printf 0
  fi

  printf 1
}

function cert {
  : "Generate certificate for use with HTTPS"

  _raise_on_no_env_file "$@"

  _env "$1"

  local path
  path="$(_timestamp)"

  mkdir -p "$path"
  rm -rf certs && mkdir -p certs

  cd "$path"

  mkcert -install "${DOMAIN}"

  cd -

  find "./$path" -type f -name "*.pem" -exec mv {} certs \;
  rm -rf "./$path"

  local host_entry="127.0.0.1 $DOMAIN"

  if [[ ! "$(cat /etc/hosts)" =~ $host_entry ]]; then
    printf "%s\n" "$host_entry" | sudo tee -a /etc/hosts
  fi

  mkdir -p ./_certs

  cat "$(mkcert -CAROOT)/rootCA.pem" >./_certs/mkcert-ca-root.pem
}

function dev {
  : "Start docker compose services required for development"

  _raise_on_no_env_file "$@"

  clear

  if ! compgen -G "./certs/*.pem" >/dev/null; then
    # shellcheck disable=2145
    _wait_until "cert $@"
  fi

  _env "$1"

  if [[ "$(_has_internet)" ]]; then
    cd src
    composer install
    cd -
  fi

  local services="mysql app ng p-admin mail"

  # shellcheck disable=2086
  docker compose up -d $services &&
    docker compose logs -f $services
}

function clean {
  docker compose kill
  docker compose down -v

  rm -rf \
    src/vendor/ \
    src/web/wp \
    src/composer.lock \
    src/web/app/upgrade

  for frag in "plugins" "themes" "uploads"; do

    local path="./src/web/app/$frag"

    if [[ -e "$path" ]]; then
      # shellcheck disable=2045
      for content in $(ls "$path"); do
        # shellcheck disable=2115
        rm -rf "$path/$content"
      done
    fi

  done

  sudo chown -R "$USER:$USER" docker/
  rm -rf ./docker/
}

function help {
  : "List available tasks."
  compgen -A function | grep -v "^_" | while read -r name; do
    paste <(printf '%s' "$name") <(type "$name" | sed -nEe 's/^[[:space:]]*: ?"(.*)";/    \1/p')
  done

  printf "\n"
}

TIMEFORMAT="Task completed in %3lR"
time "${@:-help}"
