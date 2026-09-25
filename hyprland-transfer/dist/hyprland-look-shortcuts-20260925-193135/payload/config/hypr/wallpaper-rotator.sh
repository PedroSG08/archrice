#!/usr/bin/env bash
# Alterna el fondo de pantalla de Hyprpaper entre las imágenes de la carpeta
# gestionada por hyprland-transfer.
#
# La imagen reservada para el logo de fastfetch (SKIP) queda fuera de la
# rotación aunque esté en la misma carpeta.
#
# Uso:
#   wallpaper-rotator.sh        rota en segundo plano hasta que se cierre la sesión
#   wallpaper-rotator.sh next   cambia el fondo una vez y termina
#   wallpaper-rotator.sh list   muestra las imágenes que entran en la rotación
set -uo pipefail

DIR="${WALLPAPER_DIR:-__WALLPAPER_DIR__}"

# Segundos entre cambios. 1200 = 20 minutos.
INTERVAL="${WALLPAPER_INTERVAL:-1200}"

# Imágenes que NO se usan como fondo de pantalla.
# Son las dos versiones del mismo dibujo reservadas para el logo de fastfetch.
SKIP=(
  "ALLqk82.png"
  "ALLqk82-cropped.png"
)

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/hyprland-transfer"
STATE_FILE="$STATE_DIR/wallpaper-actual"
LOCK_FILE="$STATE_DIR/wallpaper-rotator.lock"

log() { printf '[fondos] %s\n' "$*" >&2; }

# Devuelve una imagen válida por salida, en orden aleatorio, excluyendo SKIP.
candidatos() {
  local archivo base omitida
  [[ -d "$DIR" ]] || return 1
  for archivo in "$DIR"/*; do
    [[ -f "$archivo" ]] || continue
    base=${archivo##*/}
    case "${base,,}" in
      *.jpg|*.jpeg|*.png|*.webp) ;;
      *) continue ;;
    esac
    for omitida in "${SKIP[@]}"; do
      [[ $base == "$omitida" ]] && continue 2
    done
    printf '%s\n' "$archivo"
  done
}

sesion_activa() {
  [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]] || return 1
  hyprctl instances >/dev/null 2>&1
}

leer_actual() {
  [[ -f "$STATE_FILE" ]] || return 0
  cat -- "$STATE_FILE"
}

# hyprpaper 0.8.x solo expone "wallpaper" por IPC, así que la espera se hace
# mirando el proceso y su socket en vez de poner una imagen de prueba.
hyprpaper_listo() {
  pgrep -x hyprpaper >/dev/null 2>&1 || return 1
  [[ -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hypr/${HYPRLAND_INSTANCE_SIGNATURE:-}/.hyprpaper.sock" ]]
}

# hyprpaper se ponía en marcha solo desde hyprland-gui.lua, que es un archivo
# generado por HyprMod: si HyprMod lo regenera sin esa parte, o si hyprpaper se
# muere a mitad de sesión, no hay quien aplique el fondo y el escritorio se
# queda con el fondo propio de Hyprland. Por eso el rotador también lo arranca.
arrancar_hyprpaper() {
  pgrep -x hyprpaper >/dev/null 2>&1 && return 0
  log "hyprpaper no está en marcha; se arranca"
  setsid hyprpaper >/dev/null 2>&1 &
}

esperar_hyprpaper() {
  local intento
  for ((intento = 0; intento < 60; intento++)); do
    hyprpaper_listo && return 0
    # A mitad de espera se le ofrece levantarlo, por si el autostart no existió.
    ((intento == 10)) && arrancar_hyprpaper
    sleep 0.5
  done
  return 1
}

# Elige una imagen distinta de la actual para que nunca se repita seguidas.
elegir() {
  local actual=${1:-} opciones
  mapfile -t opciones < <(candidatos)
  ((${#opciones[@]} > 0)) || return 1
  if ((${#opciones[@]} > 1)); then
    local candidatas=() opcion
    for opcion in "${opciones[@]}"; do
      [[ $opcion == "$actual" ]] || candidatas+=("$opcion")
    done
    opciones=("${candidatas[@]}")
  fi
  printf '%s\n' "${opciones[$((RANDOM % ${#opciones[@]}))]}"
}

aplicar() {
  local nueva=${1:-} anterior
  [[ -n $nueva ]] || return 1
  mkdir -p -- "$STATE_DIR" || return 1

  # La coma sin nombre de monitor aplica la imagen a todos los monitores.
  hyprctl hyprpaper wallpaper ",$nueva" >/dev/null 2>&1 || return 1

  # hyprpaper 0.8.x sustituye la imagen anterior por su cuenta al aplicar otra.
  anterior=$(leer_actual)
  printf '%s\n' "$nueva" >"$STATE_FILE"
  log "fondo: ${nueva##*/}"
  if [[ -n $anterior && $anterior != "$nueva" ]]; then
    log "antes: ${anterior##*/}"
  fi
  return 0
}

cambiar_una() {
  sesion_activa || { log "no hay una sesión Hyprland activa"; return 1; }
  local nueva
  nueva=$(elegir "$(leer_actual)") || { log "no hay imágenes en $DIR"; return 1; }
  esperar_hyprpaper || { log "hyprpaper no responde"; return 1; }
  aplicar "$nueva"
}

rotar() {
  mkdir -p -- "$STATE_DIR" || return 1

  # Una sola instancia: si ya hay un rotador vivo, no se inicia otro.
  exec 9>"$LOCK_FILE" || return 1
  if ! flock -n 9; then
    log "ya hay un rotador en marcha"
    return 0
  fi

  sesion_activa || { log "no hay una sesión Hyprland activa"; return 1; }

  # El primer cambio va sin espera. Antes se dormía hasta 30 s al arrancar, y
  # durante ese rato el escritorio enseña el fondo propio de Hyprland, que es
  # justo lo que hace pensar que los fondos no se activan. El cerrojo de arriba
  # ya evita que dos sesiones roten a la vez, así que el retardo no hace falta.
  #
  # El 9>&- del sleep importa: sleep heredaría el descriptor del cerrojo y lo
  # seguiría teniendo abierto, así que al morirse el rotador el cerrojo quedaba
  # en manos del sleep huérfano y ninguna recarga podía volver a arrancarlo.
  while :; do
    cambiar_una || log "no se pudo cambiar el fondo; se reintenta en $INTERVAL s"
    sleep "$INTERVAL" 9>&-
  done
}

case ${1:-rotar} in
  rotar) rotar ;;
  next)  cambiar_una ;;
  list)  candidatos ;;
  *)     printf 'Uso: %s [rotar|next|list]\n' "${0##*/}" >&2; exit 2 ;;
esac
