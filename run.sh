#!/bin/bash
# shellcheck disable=1090

set -e

components_roots='./src/components'
word_press_components_root='/var/www/html/web/app'
copy_watch_cmd='bash run.sh app.cp'

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
    if [[ "$DOCKER_ENV_FILE" =~ .env.example ]]; then
      printf "\nERROR: env filename can not be .env.example.\n\n"
      exit 1
    fi

    return 0
  fi

  if [[ -z "$1" ]] || [[ ! -e "$1" ]]; then
    printf "\nERROR: env filename has not been provided or invalid.\n"
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

function _cert_folder {
  printf '%s' "${SITE_CERT_FOLDER:-./certs}"
}

function cert {
  : "Generate certificate for use with HTTPS"

  _raise_on_no_env_file "$@"

  _env "$1"

  local path
  path="$(_timestamp)"

  local cert_folder
  cert_folder="$(_cert_folder)"

  mkdir -p "$path"
  rm -rf "${cert_folder}" && mkdir -p "${cert_folder}"

  cd "$path"

  mkcert -install "${DOMAIN}"

  cd -

  find "./$path" -type f -name "*.pem" -exec mv {} "${cert_folder}" \;
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

  if ! compgen -G "${cert_folder}/*.pem" >/dev/null; then
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

  sudo chown -R "$USER:$USER" .

  rm -rf ./*certs "$(_cert_folder)"

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

  rm -rf ./docker/
}

function app.cpwk {
  : "Stop watching copy."

  local pid
  pid="$(ps a | grep "${copy_watch_cmd}" | grep -v grep | awk '{print $1}')"

  if [[ -n "$pid" ]]; then
    local cmd="kill -9 ${pid}"
    printf '%s\n\n' "${cmd}"
    eval "${cmd}"
  fi
}

function app.rm {
  : "Delete a wordpress component."
  local component_type="$1"
  local component_name="$2"

  if [[ -z "$component_type" ]] || [[ -z "$component_name" ]]; then
    printf '\nERROR: You must specify component type and component name.\n\n'
    exit 1
  fi

  app.cpwk

  # shellcheck disable=2115
  rm -rf "${components_roots}/${component_type}/${component_name}"

  docker compose \
    exec app \
    rm -rf "${word_press_components_root}/$component_type/${component_name}"
}

function app.m {
  : "Make a wordpress component. Examples:"
  : "  run.sh component themes theme-name"

  local component_type="$1"

  if [[ "$component_type" != "themes" ]] && [[ "$component_type" != "plugins" ]]; then
    printf '\nERROR: "%s" must be "themes" or "plugins"\n\n' "$component_type"
    exit 1
  fi

  local component_name="$2"

  local component_root="${components_roots}/${component_type}/${component_name}"

  mkdir -p "${component_root}"

  if [[ "$component_type" == 'themes' ]]; then
    for theme_file in 'style.css' 'index.php'; do
      local theme_file_abs="${component_root}/${theme_file}"

      if [[ ! -e "$theme_file_abs" ]]; then
        touch "$theme_file_abs"
      fi
    done
  elif [[ ! -e "${component_root}/index.php" ]]; then
    touch "${component_root}/index.php"
    touch "${component_root}/${component_name}.php"
  fi

  printf '%s\n\n' "$component_root"
}

function app.cp {
  : "Copy from our app codes to appropriate wordpress folders"

  if [[ ! -e "${components_roots}" ]]; then
    printf '\nERROR: You have not created any custom wordpress component. Exiting!\n\n'
    exit 1
  fi

  clear

  # shellcheck disable=2045
  for component_type in $(ls "${components_roots}"); do
    local word_press_component_path="${word_press_components_root}/$component_type"
    local component_root="${components_roots}/${component_type}"

    # shellcheck disable=2045
    for filename in $(ls "$component_root"); do
      local component_file_full_path="${component_root}/${filename}"

      local cmd="docker cp \
        ${component_file_full_path} \
        ${CONTAINER_NAME:project-name-app}:${word_press_component_path}"

      printf 'Executing:\n\t %s\n\n' "${cmd}"
      eval "${cmd}"
    done
  done

}

function app.cpw {
  : "Copy from our app codes to appropriate wordpress folders in watch mode."

  chokidar \
    "${components_roots}" \
    --initial \
    -c "${copy_watch_cmd}" &

  disown
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
