#!/usr/bin/env bash
#
# ha-qwenpaw-autoupdate.sh
#
# Автоматическое обновление локального HA add-on QwenPaw (repository: local)
# до последнего GitHub-релиза https://github.com/agentscope-ai/QwenPaw
#
# Принцип:
#   1. Берём последний стабильный релиз из GitHub API (tag_name, без prerelease).
#   2. Сравниваем с версией, прописанной в /addons/qwenpaw/config.yaml на HA.
#   3. Если отличается — фиксируем тег в Dockerfile, bump версии в config.yaml,
#      и делаем uninstall + supervisor restart + install (именно uninstall
#      заставляет Supervisor стереть старый Docker-образ и перетянуть свежий).
#
# Supervisor не умеет автоапдейтить local-аддоны сам (он следит за registry
# только для store-репозиториев), поэтому этот скрипт — единственный способ
# настоящего автообновления локальной сборки.
#
# Запуск: вручную или по cron, например раз в сутки:
#   17 4 * * * /storage/GITHUB/CoPaw/ha-qwenpaw-autoupdate.sh >> /var/log/qwenpaw-autoupdate.log 2>&1
#
# Авторизация на HA: SSH add-on, порт 22222. Скрипт поддерживает sshpass
# (HA_PASSWORD) или SSH-ключ (SSH_KEY). Ключ надёжнее — не храним пароль.

set -euo pipefail

# ──────────────────────────── НАСТРОЙКИ ────────────────────────────
HA_HOST="${HA_HOST:-192.168.1.52}"
HA_SSH_PORT="${HA_SSH_PORT:-22222}"
HA_USER="${HA_USER:-root}"

# Пароль (если используется sshpass). Лучше — SSH-ключ.
HA_PASSWORD="${HA_PASSWORD:-}"

# Путь к SSH-ключу (если пусто и нет пароля — упадёт с подсказкой).
SSH_KEY="${SSH_KEY:-}"

# Внутренние пути HA
ADDON_DIR="/addons/qwenpaw"
CONFIG_FILE="${ADDON_DIR}/config.yaml"
DOCKERFILE="${ADDON_DIR}/Dockerfile"
SLUG="local_qwenpaw"
# HEALTH_URL можно задать через env; иначе IP берётся динамически из ha addons info
HEALTH_URL="${HEALTH_URL:-}"

# Источник версии
GITHUB_API="https://api.github.com/repos/agentscope-ai/QwenPaw/releases/latest"

# Бэкап данных перед обновлением (workspace + секреты)
BACKUP_DIR="/share"

# Таймауты (сек)
INSTALL_TIMEOUT=600         # максимум на rebuild (тянет ~2ГБ образ)
HEALTH_RETRIES=30           # попыток healthcheck после старта
HEALTH_DELAY=10             # пауза между попытками

# Разрешить обновление до prerelease (по умолчанию — нет)
ALLOW_PRERELEASE="${ALLOW_PRERELEASE:-0}"

# Логирование в systemd-стиле
log()  { echo "$(date '+%Y-%m-%d %H:%M:%S')  $*"; }
err()  { echo "$(date '+%Y-%m-%d %H:%M:%S')  ERROR: $*" >&2; }
die()  { err "$*"; exit 1; }

# ──────────────────────────── SSH-ОБЁРТКА ────────────────────────────
# ha_ssh "remote command..." — выполнить на HA
ha_ssh() {
  if [[ -n "${HA_PASSWORD}" ]]; then
    # -o StrictHostKeyChecking=no чтобы не зависать на первом подключении
    sshpass -p "${HA_PASSWORD}" ssh \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR \
      -p "${HA_SSH_PORT}" \
      "${HA_USER}@${HA_HOST}" "$@"
  else
    [[ -n "${SSH_KEY}" ]] || die "Нужен HA_PASSWORD или SSH_KEY"
    ssh \
      -i "${SSH_KEY}" \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR \
      -p "${HA_SSH_PORT}" \
      "${HA_USER}@${HA_HOST}" "$@"
  fi
}

# ──────────────────────────── ВСПОМОГАТЕЛЬНЫЕ ────────────────────────────

# Последний релиз GitHub → печатает tag_name (например v1.1.11.post2)
get_latest_release() {
  local tmp
  tmp="$(mktemp)"
  local url
  if [[ "${ALLOW_PRERELEASE}" == "1" ]]; then
    url="https://api.github.com/repos/agentscope-ai/QwenPaw/releases?per_page=1"
  else
    url="${GITHUB_API}"
  fi
  curl -fsSL -H 'Accept: application/vnd.github+json' "${url}" -o "${tmp}"
  grep -m1 '"tag_name"' "${tmp}" | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/'
  rm -f "${tmp}"
}

# Текущая установленная версия из config.yaml на HA
get_installed_version() {
  ha_ssh "sed -nE 's/^version:[[:space:]]*\"?([^\"]+)\"?.*/\1/p' ${CONFIG_FILE} | head -1"
}

# Нормализация: убираем ведущий v, чтобы сравнивать 1.1.11.post2 == v1.1.11.post2
norm() { echo "${1#v}" | tr -d '[:space:]'; }

# ──────────────────────────── ОСНОВНАЯ ЛОГИКА ────────────────────────────

main() {
  command -v curl >/dev/null || die "curl не найден"
  if [[ -z "${HA_PASSWORD}" ]]; then
    command -v ssh >/dev/null || die "ssh не найден"
    [[ -n "${SSH_KEY}" ]] || die "Задайте HA_PASSWORD или SSH_KEY"
  else
    command -v sshpass >/dev/null || die "sshpass не найден (нужен для HA_PASSWORD)"
  fi

  log "Запуск автоапдейта QwenPaw на ${HA_HOST}:${HA_SSH_PORT}"

  local latest installed
  latest="$(get_latest_release)" || die "Не удалось получить последний релиз с GitHub"
  [[ -n "${latest}" ]] || die "GitHub вернул пустой tag_name"
  log "Последний релиз GitHub: ${latest}"

  installed="$(get_installed_version)" || die "Не удалось прочитать версию из ${CONFIG_FILE} на HA"
  installed="${installed:-unknown}"
  log "Установленная версия на HA: ${installed}"

  if [[ "$(norm "${latest}")" == "$(norm "${installed}")" ]]; then
    log "Версии совпадают — обновление не требуется."
    exit 0
  fi

  log "Обнаружена новая версия. Запускаю обновление → ${latest}"

  # Бэкап данных (workspace + секреты) перед любыми изменениями
  local backup_name="qwenpaw-backup-$(date +%Y%m%d-%H%M%S).tgz"
  log "Создаю бэкап /share/qwenpaw → ${BACKUP_DIR}/${backup_name}"
  ha_ssh "tar czf '${BACKUP_DIR}/${backup_name}' \
            -C /share qwenpaw/working qwenpaw/working.secret 2>/dev/null || \
          tar czf '${BACKUP_DIR}/${backup_name}' -C /share qwenpaw || true" \
    || err "Бэкап завершился с ошибкой (продолжаю — данные персистентны вне контейнера)"

  # 1. Фиксируем конкретный тег в Dockerfile (надёжнее плавающего :latest)
  log "Обновляю ${DOCKERFILE}: agentscope/qwenpaw:${latest}"
  ha_ssh "sed -i -E 's|agentscope/qwenpaw:[A-Za-z0-9._-]+|agentscope/qwenpaw:${latest}|' ${DOCKERFILE}"
  ha_ssh "grep -E '^FROM' ${DOCKERFILE}"

  # 2. Обновляем version в config.yaml (Supervisor видит новую версию → пересобирает)
  log "Обновляю version в ${CONFIG_FILE}: \"${latest#v}\""
  ha_ssh "sed -i -E 's|^version:.*|version: \"${latest#v}\"|' ${CONFIG_FILE}"
  ha_ssh "grep -E '^version:' ${CONFIG_FILE}"

  # 3. rebuild пересобирает add-on по новому Dockerfile. Поскольку мы фиксируем
  #    КОНКРЕТНЫЙ тег (vX.Y.Z), а не плавающий :latest, этого тега нет в кэше
  #    Docker — значит rebuild гарантированно тянет свежий образ из registry.
  #    (uninstall+install оказался ненадёжным: protected-add-on не всегда
  #     удаляется полностью, и install падал с "already installed".)
  log "Пересобираю add-on по новому образу (до ${INSTALL_TIMEOUT}s)..."
  if ! ha_ssh "timeout ${INSTALL_TIMEOUT} ha apps rebuild ${SLUG}"; then
    die "rebuild завершился с ошибкой. Проверьте логи: ha apps logs ${SLUG}"
  fi

  log "Запускаю add-on..."
  ha_ssh "ha apps start ${SLUG}" || true

  # 5. Healthcheck
  # Если HEALTH_URL не задан — определяем IP add-on динамически
  if [[ -z "${HEALTH_URL}" ]]; then
    local addon_ip
    addon_ip="$(ha_ssh "ha addons info ${SLUG} 2>/dev/null | sed -nE 's/^ip_address:[[:space:]]*(.+)/\1/p' | tr -d '[:space:]'")"
    [[ -n "${addon_ip}" ]] || addon_ip="172.30.33.5"
    HEALTH_URL="http://${addon_ip}:8088/api/agent/health"
  fi
  log "Жду подъёма сервиса (healthcheck ${HEALTH_URL})..."
  local ok=0
  for ((i=1; i<=HEALTH_RETRIES; i++)); do
    if ha_ssh "curl -fsS ${HEALTH_URL} >/dev/null 2>&1"; then
      ok=1
      break
    fi
    sleep "${HEALTH_DELAY}"
  done

  if [[ "${ok}" == "1" ]]; then
    log "✓ QwenPaw обновлён до ${latest} и работает."
    ha_ssh "ha apps info ${SLUG} | grep -iE 'version|state|ip_address'" || true
    exit 0
  else
    err "QwenPaw установлен, но healthcheck не прошёл за отведённое время."
    err "Проверьте: ssh -p ${HA_SSH_PORT} ${HA_USER}@${HA_HOST} 'ha apps logs ${SLUG} | tail -50'"
    exit 2
  fi
}

main "$@"
