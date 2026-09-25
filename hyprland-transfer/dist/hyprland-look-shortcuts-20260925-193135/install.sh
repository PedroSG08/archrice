#!/usr/bin/env bash
# Exporta e instala de forma portable el aspecto y los atajos de Hyprland.
# Compatible con Arch Linux y derivadas que usan pacman.
set -Eeuo pipefail
IFS=$'\n\t'

PROGRAM=${0##*/}
VERSION="1.3.0"
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

# Segundos entre cambios de fondo. Debe coincidir con INTERVAL de
# wallpaper-rotator.sh, que es quien aplica la rotación.
ROTATOR_INTERVAL=1200

readonly -a OFFICIAL_PACKAGES=(
  hyprland
  hyprpaper
  kitty
  rofi
  yazi
  fastfetch
  discord
  hyprshot
  hyprshutdown
  wireplumber
  brightnessctl
  playerctl
  xdg-desktop-portal-hyprland
  ttf-jetbrains-mono-nerd
)

readonly -a AUR_PACKAGES=(
  zen-browser-bin
  otf-departure-mono-nerd
)

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_BLUE=$'\033[1;34m'
  C_GREEN=$'\033[1;32m'
  C_YELLOW=$'\033[1;33m'
  C_RED=$'\033[1;31m'
else
  C_RESET=''
  C_BLUE=''
  C_GREEN=''
  C_YELLOW=''
  C_RED=''
fi

info() { printf '%s[INFO]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok() { printf '%s[ OK ]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[AVISO]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
error() { printf '%s[ERROR]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die() { error "$*"; exit 1; }

usage() {
  cat <<EOF
${PROGRAM} ${VERSION} — transferidor portable de Hyprland

Uso:
  ${PROGRAM} export [DIRECTORIO_SALIDA]
  ${PROGRAM} install [DIRECTORIO_DEL_BUNDLE] [OPCIONES]
  ${PROGRAM} doctor [DIRECTORIO_DEL_BUNDLE]
  ${PROGRAM} --help

Comandos:
  export   Crea un bundle portable desde la configuración actual.
  install  Instala únicamente las dependencias y archivos de este bundle.
  doctor   Comprueba paquetes, comandos, fuentes, archivos y errores de Hyprland.

Opciones de install:
  --yes              No pide la confirmación final.
  --dry-run          Muestra el plan y no modifica nada.
  --skip-packages    No instala paquetes; solo aplica la configuración.
  --skip-aur         Omite los dos paquetes de AUR.
  --no-activate      No habilita servicios ni recarga Hyprland.
  --keep-config      Conserva archivos extra de las carpetas de configuración.
  --backup-root DIR  Directorio adicional para copias de seguridad.

Limpieza:
  Por defecto se respaldan y reemplazan por completo las carpetas hypr, kitty,
  rofi y fastfetch, además de la carpeta de fondos gestionada. Los perfiles de
  otras aplicaciones no se tocan.

Fondos:
  wallpaper-rotator.sh alterna los fondos cada 20 minutos al arrancar Hyprland.
  La imagen reservada para el logo de fastfetch queda fuera de la rotación.

Portabilidad:
  El bloque hl.monitor se exporta con output = "" para que el fondo y la escala
  se apliquen a todas las salidas del equipo destino; el nombre de la salida de
  origen queda anotado en un comentario.
  El bloque wallpaper de hyprpaper se conserva y se normaliza a monitor = *.
  El perfil de Zen y el .bashrc NO se tocan: viajan en payload/extra y se
  aplican a mano.

Ejemplo desde un bundle extraído:
  ./${PROGRAM}

Ejemplo para crear otro bundle después de cambiar la configuración:
  ./${PROGRAM} export
EOF
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Falta el comando requerido: $1"
}

is_true() {
  case ${1,,} in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

confirm() {
  local prompt=$1 answer
  [[ ${ASSUME_YES:-0} -eq 1 ]] && return 0
  [[ -t 0 ]] || die "Se necesita una terminal interactiva. Usa --yes para confirmar."
  read -r -p "$prompt [s/N] " answer
  is_true "$answer" || return 1
}

resolve_path() {
  local path=$1
  [[ -e "$path" ]] || die "No existe la ruta: $path"
  realpath -e -- "$path"
}

timestamp() {
  date +%Y%m%d-%H%M%S
}

join_by_space() {
  local separator='' item
  for item in "$@"; do
    printf '%s%s' "$separator" "$item"
    separator=' '
  done
  printf '\n'
}

# Sustitución literal, sin interpretar caracteres regulares de sed.
replace_literal() {
  local file=$1 needle=$2 replacement=$3 tmp line
  tmp=$(mktemp "${TMPDIR:-/tmp}/hyprland-transfer.XXXXXX")
  while IFS= read -r line || [[ -n "$line" ]]; do
    printf '%s\n' "${line//"$needle"/"$replacement"}"
  done <"$file" >"$tmp"
  cat "$tmp" >"$file"
  rm -f -- "$tmp"
}

write_package_files() {
  local root=$1 package
  mkdir -p "$root/packages"

  : >"$root/packages/official.txt"
  for package in "${OFFICIAL_PACKAGES[@]}"; do
    printf '%s\n' "$package" >>"$root/packages/official.txt"
  done

  : >"$root/packages/aur.txt"
  for package in "${AUR_PACKAGES[@]}"; do
    printf '%s\n' "$package" >>"$root/packages/aur.txt"
  done
}

read_package_file() {
  local file=$1 package
  [[ -f "$file" ]] || die "El bundle no contiene la lista de paquetes: $file"
  while IFS= read -r package || [[ -n "$package" ]]; do
    [[ -z "$package" || "$package" == \#* ]] && continue
    [[ "$package" =~ ^[a-z0-9][a-z0-9@._+-]*$ ]] \
      || die "Nombre de paquete no válido en $file: $package"
    printf '%s\n' "$package"
  done <"$file"
}

hyprland_version() {
  local version=''
  if command -v hyprctl >/dev/null 2>&1; then
    version=$(hyprctl version 2>/dev/null | awk '/^Hyprland / {print $2; exit}')
  fi
  printf '%s' "$version"
}

check_source_config() {
  local errors
  if command -v hyprctl >/dev/null 2>&1 && hyprctl instances -j >/dev/null 2>&1; then
    errors=$(hyprctl configerrors 2>&1 || true)
    if [[ -n ${errors//[[:space:]]/} ]]; then
      warn "La configuración activa de Hyprland ya contiene errores:"
      printf '%s\n' "$errors" >&2
      return 1
    fi
  fi
  return 0
}

# hyprpaper 0.8+ configura el fondo con un bloque propio:
#
#   wallpaper { monitor = *  path = RUTA  fit_mode = cover }
#
# Antes esta función quitaba el bloque para no dejar el nombre de monitor del
# origen, pero con el formato nuevo quitarlo dejaba a hyprpaper sin NINGÚN fondo
# configurado. Ahora el bloque se conserva y solo se normaliza a monitor = "*",
# que es la forma de aplicar el fondo a todas las salidas del equipo destino.
# La ruta se vuelve portátil después, al sustituir __WALLPAPER_DIR__.
portable_hyprpaper() {
  local source=$1 destination=$2
  local legacy_path

  HYPRPAPER_NOTE='sin bloque wallpaper: el fondo lo aplica wallpaper-rotator.sh'

  if grep -qE '^[[:space:]]*wallpaper[[:space:]]*\{' "$source"; then
    awk '
      # El bloque wallpaper, copiado tal cual.
      # El nombre de la salida del origen no se transporta: "*" son todas.
      in_block && match($0, /^[[:space:]]*monitor[[:space:]]*=/) {
        print "    monitor = *"
        next
      }
      { print }
    ' "$source" >"$destination"
    HYPRPAPER_NOTE='bloque wallpaper conservado con monitor = *'

    grep -qE '^[[:space:]]*path[[:space:]]*=' "$destination" \
      || die "El bloque wallpaper de $source no tiene ninguna línea path."
  elif grep -qE '^[[:space:]]*wallpaper[[:space:]]*=' "$source"; then
    # Forma antigua "wallpaper = ,RUTA". hyprpaper 0.8 la ignora en silencio,
    # así que se traduce al bloque nuevo en vez de perder el fondo.
    legacy_path=$(sed -n \
      's/^[[:space:]]*wallpaper[[:space:]]*=[[:space:]]*,\{1\}\(.*\)$/\1/p' \
      "$source" | head -n1)
    if [[ -n $legacy_path ]]; then
      grep -vE '^[[:space:]]*wallpaper[[:space:]]*=' "$source" >"$destination"
      {
        printf '\n'
        printf '# Traducido desde la forma antigua "wallpaper = ,RUTA", que\n'
        printf '# hyprpaper 0.8+ ignora en silencio. monitor = * aplica el mismo\n'
        printf '# fondo a todas las salidas del equipo destino.\n'
        printf 'wallpaper {\n'
        printf '    monitor = *\n'
        printf '    path = %s\n' "$legacy_path"
        printf '    fit_mode = cover\n'
        printf '}\n'
      } >>"$destination"
      HYPRPAPER_NOTE='forma antigua "wallpaper = ,RUTA" traducida al bloque nuevo'
    else
      cp -a -- "$source" "$destination"
    fi
  else
    cp -a -- "$source" "$destination"
  fi
}

# El bloque hl.monitor del equipo de origen nombra su salida (aquí eDP-1, el
# panel del portátil). En el destino esa salida puede no existir, así que en el
# bundle el campo output se deja vacío, que es la forma de aplicar el bloque a
# todas las salidas, y el nombre de origen queda anotado en un comentario.
# Los comentarios del propio archivo (que traen ejemplos como DP-1) se ignoran.
portable_monitor() {
  local source=$1 destination=$2

  MONITOR_BLOCKS=$(grep -cE '^[[:space:]]*hl\.monitor[[:space:]]*\(' "$source" || true)
  MONITOR_OUTPUTS=()

  awk '
    BEGIN { in_block = 0 }

    # Un ejemplo en comentario no es un bloque real, así que ni se cuenta ni
    # cambia el estado.
    /^[[:space:]]*--/ { print; next }

    in_block && /^[[:space:]]*\}/ { in_block = 0; print; next }

    # Apertura de bloque: a partir de aquí se busca el campo output.
    /^[[:space:]]*hl\.monitor[[:space:]]*\(/ { in_block = 1; print; next }

    in_block && match($0, /^[[:space:]]*output[[:space:]]*=[[:space:]]*"[^"]*"/) {
      original = substr($0, RSTART, RLENGTH)
      sub(/^[[:space:]]*output[[:space:]]*=[[:space:]]*"/, "", original)
      sub(/"$/, "", original)
      print "    -- La salida del equipo de origen era \"" original "\"."
      print "    -- \"\" deja el bloque para todas las salidas del equipo destino."
      print "    output   = \"\","
      next
    }

    # Un bloque entero en una sola línea no se puede partir aquí: se copia tal
    # cual y más abajo se avisa de ello.
    { print }
  ' "$source" >"$destination"

  while IFS= read -r origin_output; do
    [[ -n $origin_output ]] && MONITOR_OUTPUTS+=("$origin_output")
  done < <(
    sed -n 's/^[[:space:]]*-- La salida del equipo de origen era "\(.*\)"\.$/\1/p' \
      "$destination"
  )

  if grep -vE '^[[:space:]]*--' "$destination" \
    | grep -qE 'hl\.monitor[[:space:]]*\(.*output[[:space:]]*=[[:space:]]*"[^"]+"'; then
    warn "Hay un hl.monitor con el output en una sola línea que no se ha vuelto"
    warn "portable: revisa a mano ese bloque en hyprland.lua del bundle."
  fi
}

# Intervalo con el que el rotador de este equipo va cambiando de fondo, para
# poder compararlo con ROTATOR_INTERVAL y no dejar los documentos mintiendo.
rotator_interval_of() {
  local rotator=$1
  [[ -f "$rotator" ]] || return 1
  sed -n \
    's/^[[:space:]]*INTERVAL="${WALLPAPER_INTERVAL:-\([0-9][0-9]*\)}".*/\1/p' \
    "$rotator" | head -n1
}

# Perfil de Zen del equipo de origen. Solo se copia su configuración de aspecto
# escrita a mano, nunca el perfil entero: ni cookies, ni historial, ni sesión.
find_zen_profile() {
  local config_home=$1 candidate
  [[ -d "$config_home/zen" ]] || return 1
  for candidate in "$config_home"/zen/*/; do
    candidate=${candidate%/}
    [[ -d "$candidate" ]] || continue
    if [[ -f "$candidate/user.js" || -f "$candidate/prefs.js" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

export_zen_look() {
  local config_home=$1 destination=$2
  local profile theme_dir theme_id

  ZEN_LOOK_NOTE='sin configuración de aspecto de Zen'
  profile=$(find_zen_profile "$config_home") || return 0

  mkdir -p -- "$destination"

  if [[ -f "$profile/user.js" ]]; then
    cp -a -- "$profile/user.js" "$destination/user.js"
  else
    warn "El perfil de Zen $profile no tiene user.js."
  fi

  if [[ -d "$profile/chrome" ]]; then
    cp -a -- "$profile/chrome" "$destination/chrome"
  fi
  if [[ -f "$profile/zen-themes.json" ]]; then
    cp -a -- "$profile/zen-themes.json" "$destination/"
  fi

  ZEN_LOOK_NOTE='user.js y tema CSS copiados del perfil de origen'
  if [[ -d "$profile/chrome/zen-themes" ]]; then
    for theme_dir in "$profile"/chrome/zen-themes/*/; do
      theme_dir=${theme_dir%/}
      [[ -f "$theme_dir/chrome.css" ]] || continue
      theme_id=${theme_dir##*/}
      ZEN_LOOK_NOTE="user.js y tema CSS ($theme_id) copiados del perfil de origen"
      break
    done
  fi

  cat >"$destination/APLICAR.txt" <<'EOF'
ASPECTO DE ZEN BROWSER
======================
Esto NO lo instala el programa. Son archivos de configuración, no de sesión:
copia solo el user.js y el tema, nunca el resto del perfil.

Desde el directorio del bundle, con el navegador cerrado:

  ZEN="$HOME/.config/zen/<TU-PERFIL>"
  cp -a payload/extra/zen-look/user.js "$ZEN/user.js"
  cp -a payload/extra/zen-look/chrome/. "$ZEN/chrome/"
  cp -a payload/extra/zen-look/zen-themes.json "$ZEN/zen-themes.json"

El nombre del perfil se ve en ~/.config/zen: es la carpeta que contiene
prefs.js (por ejemplo "3usbbg9k.Default (release)").

Qué hace:
- user.js: pone el fondo del navegador transparente y activa el barra lateral y
  la barra de direcciones con acrylic. Es lo que hace que el desenfoque de
  Hyprland se vea detrás de la ventana.
- Lo mismo fuerza el modo oscuro del navegador.
- chrome/: el tema CSS que limpia la barra de direcciones.

Requisitos: en Hyprland hace falta decoration.blur con ignore_opacity = true,
que es lo que trae ya hyprland.lua.

El logo del fastfetch solo se ve dentro de kitty; el resto de ajustes de Zen no
se transportan.
EOF
}

# El .bashrc del equipo de origen llama a fastfetch al abrir cada terminal, y es
# lo que hace que aparezca el logo. Un .bashrc ajeno no se pisa, así que viaja
# un fragmento que el usuario pega.
write_fastfetch_snippet() {
  local destination=$1
  mkdir -p -- "$destination"
  cat >"$destination/snippet.bash" <<'EOF'
# Rótulo de información del sistema al abrir cada terminal.
#
# Pega esta línea al FINAL de ~/.bashrc, dentro del bloque que ya solo se lee
# con terminal interactivo. El programa no sobrescribe tu .bashrc.
#
# Con esto, cada terminal muestra fastfetch con el logo configurado en
# ~/.config/fastfetch/config.jsonc. La imagen solo se dibuja dentro de kitty:
# el logo usa el protocolo de gráficos de kitty (kitty-direct).
fastfetch
EOF
}

# payload/extra no se instala nunca: son archivos personales del equipo destino
# (el perfil del navegador y el .bashrc). Al terminar solo se recuerda dónde
# están y qué queda por hacer a mano.
announce_extras() {
  local root=$1
  local extra="$root/payload/extra"

  [[ -d "$extra" ]] || return 0
  if [[ -d "$extra/zen-look" ]]; then
    info "Queda aplicar a mano el aspecto de Zen: $extra/zen-look"
    info "  Las instrucciones están en APLICAR.txt; el perfil no se ha tocado."
  fi
  if [[ -f "$extra/fastfetch/snippet.bash" ]]; then
    info "Para ver el rótulo de fastfetch, pega la línea de:"
    info "  $extra/fastfetch/snippet.bash"
  fi
}

export_bundle() {
  local output=${1:-}
  local source_config_home=${XDG_CONFIG_HOME:-$HOME/.config}
  local source_wallpapers=""
  local created source_version stage_name bundle_root archive archive_hash
  local source_file

  [[ $EUID -ne 0 ]] || die "Ejecuta la exportación como el usuario normal, no como root."
  require_command tar
  require_command sha256sum
  require_command awk
  require_command find
  require_command cp
  require_command realpath

  local hypr_dir="$source_config_home/hypr"
  local kitty_dir="$source_config_home/kitty"
  local rofi_dir="$source_config_home/rofi"
  local fastfetch_dir="$source_config_home/fastfetch"

  for source_file in \
    "$hypr_dir/hyprland.lua" \
    "$hypr_dir/hyprland-gui.lua" \
    "$hypr_dir/hyprpaper.conf" \
    "$kitty_dir/kitty.conf" \
    "$kitty_dir/theme.conf" \
    "$rofi_dir/config.rasi"; do
    [[ -f "$source_file" ]] || die "No se encuentra el archivo necesario: $source_file"
  done

  # El logo de fastfetch es opcional: si no existe, no se copia nada.
  local has_fastfetch=0
  [[ -f "$fastfetch_dir/config.jsonc" ]] && has_fastfetch=1

  if [[ -d "$HOME/Imágenes/wallpapers" ]]; then
    source_wallpapers="$HOME/Imágenes/wallpapers"
  elif [[ -d "$HOME/Pictures/wallpapers" ]]; then
    source_wallpapers="$HOME/Pictures/wallpapers"
  elif [[ -d "$source_config_home/hypr/wallpapers" ]]; then
    source_wallpapers="$source_config_home/hypr/wallpapers"
  elif [[ -d "${XDG_DATA_HOME:-$HOME/.local/share}/hyprland/wallpapers" ]]; then
    source_wallpapers="${XDG_DATA_HOME:-$HOME/.local/share}/hyprland/wallpapers"
  else
    die "No se encuentra la carpeta de fondos del sistema actual."
  fi

  mapfile -d '' -t wallpaper_files < <(
    find -L "$source_wallpapers" -maxdepth 1 -type f \
      \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \) \
      -print0 | sort -z
  )
  ((${#wallpaper_files[@]} > 0)) || die "No se encontraron fondos en: $source_wallpapers"

  check_source_config || warn "La exportación continuará, pero revisa los errores indicados."

  created=$(timestamp)
  if [[ -z "$output" ]]; then
    output="$SCRIPT_DIR/dist/hyprland-look-shortcuts-$created"
  fi
  [[ ! -e "$output" ]] || die "La salida ya existe: $output"
  mkdir -p -- "$output"
  bundle_root=$(realpath -e -- "$output")
  stage_name=$(basename -- "$bundle_root")

  mkdir -p \
    "$bundle_root/payload/config/hypr" \
    "$bundle_root/payload/config/kitty" \
    "$bundle_root/payload/config/rofi" \
    "$bundle_root/payload/wallpapers" \
    "$bundle_root/payload/extra"
  if ((has_fastfetch)); then
    mkdir -p "$bundle_root/payload/config/fastfetch"
  fi

  cp -a -- "$hypr_dir/hyprland.lua" "$bundle_root/payload/config/hypr/hyprland.lua"
  portable_monitor \
    "$hypr_dir/hyprland.lua" \
    "$bundle_root/payload/config/hypr/hyprland.lua"
  cp -a -- "$hypr_dir/hyprland-gui.lua" "$bundle_root/payload/config/hypr/"
  portable_hyprpaper \
    "$hypr_dir/hyprpaper.conf" \
    "$bundle_root/payload/config/hypr/hyprpaper.conf"
  if [[ -f "$hypr_dir/wallpaper-rotator.sh" ]]; then
    cp -a -- "$hypr_dir/wallpaper-rotator.sh" "$bundle_root/payload/config/hypr/"
  fi

  cp -a -- "$kitty_dir/kitty.conf" "$bundle_root/payload/config/kitty/"
  cp -a -- "$kitty_dir/theme.conf" "$bundle_root/payload/config/kitty/"
  cp -a -- "$rofi_dir/config.rasi" "$bundle_root/payload/config/rofi/"

  if ((has_fastfetch)); then
    cp -a -- "$fastfetch_dir/config.jsonc" "$bundle_root/payload/config/fastfetch/"
  fi

  # Lo que el instalador NO aplica solo, porque pisa archivos personales del
  # equipo destino: el aspecto de Zen y el fragmento de .bashrc que lanza
  # fastfetch. Viaja en payload/extra y se aplica a mano, con sus instrucciones.
  export_zen_look "$source_config_home" "$bundle_root/payload/extra/zen-look"
  write_fastfetch_snippet "$bundle_root/payload/extra/fastfetch"

  for source_file in "${wallpaper_files[@]}"; do
    cp -a -- "$source_file" "$bundle_root/payload/wallpapers/"
  done

  local old_wallpaper_dir="$source_wallpapers"
  replace_literal \
    "$bundle_root/payload/config/hypr/hyprpaper.conf" \
    "$old_wallpaper_dir" "__WALLPAPER_DIR__"
  if [[ -f "$bundle_root/payload/config/hypr/wallpaper-rotator.sh" ]]; then
    replace_literal \
      "$bundle_root/payload/config/hypr/wallpaper-rotator.sh" \
      "$old_wallpaper_dir" "__WALLPAPER_DIR__"
  fi
  if ((has_fastfetch)); then
    replace_literal \
      "$bundle_root/payload/config/fastfetch/config.jsonc" \
      "$old_wallpaper_dir" "__WALLPAPER_DIR__"
  fi
  local home_config_literal="\$HOME/.config"
  replace_literal \
    "$bundle_root/payload/config/kitty/theme.conf" \
    "$home_config_literal" '__CONFIG_HOME__'

  write_package_files "$bundle_root"

  # Los documentos citan el intervalo del rotador, así que manda el valor real
  # del script de este equipo y no la constante, que se podría desfasar.
  local rotator_interval=''
  if [[ -f "$hypr_dir/wallpaper-rotator.sh" ]]; then
    rotator_interval=$(rotator_interval_of "$hypr_dir/wallpaper-rotator.sh" || true)
    if [[ -n $rotator_interval && $rotator_interval != "$ROTATOR_INTERVAL" ]]; then
      warn "wallpaper-rotator.sh rota cada ${rotator_interval} s y este programa"
      warn "tenía anotados $ROTATOR_INTERVAL s; mandan los $rotator_interval s del"
      warn "script, así que revisa la constante ROTATOR_INTERVAL."
    fi
    [[ -n $rotator_interval ]] && ROTATOR_INTERVAL=$rotator_interval
  fi

  source_version=$(hyprland_version)
  [[ -n "$source_version" ]] || source_version='no detectada'
  local fastfetch_note='sin configuración de fastfetch'
  ((has_fastfetch)) && fastfetch_note='incluida'
  # Texto del monitor ya calculado: dentro de los heredocs de abajo es más
  # simple interpolar una variable normal que un array.
  local monitor_note
  if ((${#MONITOR_OUTPUTS[@]} > 0)); then
    monitor_note=$(join_by_space "${MONITOR_OUTPUTS[@]}")
  elif ((MONITOR_BLOCKS > 0)); then
    monitor_note='el bloque ya venía sin nombre de salida, portable tal cual'
  else
    monitor_note='el archivo no trae bloque hl.monitor'
  fi
  cat >"$bundle_root/MANIFIESTO.txt" <<EOF
Bundle de aspecto y atajos de Hyprland
======================================
Formato: 3
Creado: $(date --iso-8601=seconds)
Origen: Arch Linux
Hyprland de origen: ${source_version}
Configuración: ${#OFFICIAL_PACKAGES[@]} paquetes oficiales y ${#AUR_PACKAGES[@]} paquetes AUR
Fondos incluidos: ${#wallpaper_files[@]}
Rotación de fondos: wallpaper-rotator.sh, intervalo $ROTATOR_INTERVAL segundos
Fastfetch: ${fastfetch_note}
Monitor: ${monitor_note}
Hyprpaper: ${HYPRPAPER_NOTE}
Zen (aspecto, a mano): ${ZEN_LOOK_NOTE}
Limpieza predeterminada: completa, después de crear una copia de seguridad

El bloque wallpaper de hyprpaper se conserva con monitor = *, de modo que el
fondo de arranque se aplica a todas las salidas del equipo destino. El rotador
lo sustituye enseguida por una imagen al azar de la carpeta de fondos.

El bloque hl.monitor sale con output = "": en el origen valía para
${monitor_note}, y en el destino se aplica a todas las salidas. El nombre
original queda en un comentario junto al bloque, por si en el equipo destino
hay que volver a fijarlo.

El rotador wallpaper-rotator.sh se inicia con Hyprland y va cambiando de fondo
cada $ROTATOR_INTERVAL segundos. Las imágenes que aparecen en su lista SKIP no
entran en la rotación porque se usan en otro sitio, en este caso como logo de
fastfetch.

payload/extra NO se instala: son ajustes de archivos personales del equipo
destino (perfil de Zen y fragmento de .bashrc) y se aplican a mano con las
instrucciones que trae cada carpeta.
EOF

  cat >"$bundle_root/LEEME.txt" <<EOF
INSTALACIÓN
===========
1. Extrae este directorio.
2. Ejecuta como el usuario normal:
       ./install.sh
3. Si aparecen dependencias AUR, debe existir yay, paru o pikaur.
4. Revisa la lista mostrada. El programa no actualiza todo Arch.

El instalador:
- instala solamente los paquetes ausentes;
- respalda las carpetas hypr, kitty, rofi, fastfetch y los fondos gestionados;
- elimina esas configuraciones anteriores y deja solo esta instalación;
- copia Hyprland, Hyprpaper, Kitty, Rofi, Fastfetch y los fondos;
- adapta las rutas al usuario y XDG del equipo destino;
- deja el bloque hl.monitor y el bloque wallpaper de hyprpaper puestos para
  todas las salidas, no solo para la del equipo de origen;
- recarga Hyprland si ya hay una sesión activa;
- no cambia la sesión de inicio ni modifica perfiles de otras aplicaciones.

Usa «./install.sh --keep-config» si quieres conservar archivos adicionales
dentro de esas carpetas. La copia de seguridad se conserva en ambos casos.

FONDOS Y FASTFETCH
==================
- Los fondos van alternándose solos cada $((ROTATOR_INTERVAL / 60)) minutos. Para
  cambiar uno antes de tiempo: ~/.config/hypr/wallpaper-rotator.sh next
- Para ver cuáles entran en la rotación: ~/.config/hypr/wallpaper-rotator.sh list
- El intervalo se cambia en la variable INTERVAL de ese mismo script.
- Una de las imágenes queda reservada como logo de fastfetch en lugar del de
  Arch, y por eso el rotador la ignora. Esa imagen solo se ve en kitty.
- El logo sale porque ~/.bashrc llama a fastfetch. El programa NO toca tu
  .bashrc: la línea va en payload/extra/fastfetch/snippet.bash, para pegarla.

MONITOR
=======
- hyprland.lua sale con output = "" en el bloque hl.monitor, que es la forma de
  aplicarlo a todas las salidas del equipo destino. El nombre de la salida del
  equipo de origen se queda escrito en un comentario justo encima.
- Si en el destino hay varios monitores y quieres posiciones o escalas
  distintas, edita ese bloque antes de arrancar Hyprland. En el equipo de
  origen era: ${monitor_note}

ASPECTO DE ZEN (A MANO)
=======================
- El perfil del navegador no se toca nunca. Lo único que viaja es la
  configuración de aspecto escrita a mano: payload/extra/zen-look.
- Ahí está user.js (fondo transparente, acrylic y modo oscuro), que es lo que
  deja ver el desenfoque de Hyprland detrás de la ventana, y el tema CSS.
- Las instrucciones de copia están en payload/extra/zen-look/APLICAR.txt.

RECOMENDACIONES
===============
- Revisa el hash del archivo .tar si te lo proporcionaron.
- Usa «./install.sh --dry-run» para inspeccionar el plan.
- Las copias de seguridad están en:
  ~/.local/share/hyprland-transfer/backups/AAAAMMDD-HHMMSS
EOF

  cp -a -- "$SCRIPT_DIR/$PROGRAM" "$bundle_root/install.sh"
  chmod 0755 "$bundle_root/install.sh"

  if grep -RIl --exclude='MANIFIESTO.txt' --exclude='LEEME.txt' '__[A-Z_][A-Z_]*__' "$bundle_root/payload" >/dev/null 2>&1; then
    ok "Plantillas portables detectadas en el payload."
  fi

  (
    cd "$bundle_root"
    find payload -type f -print0 | sort -z | xargs -0 sha256sum >manifest.sha256
  )

  archive="${bundle_root}.tar"
  tar -cf "$archive" -C "$(dirname "$bundle_root")" "$stage_name"
  archive_hash=$(sha256sum "$archive")
  printf '%s  %s\n' "${archive_hash%% *}" "$(basename "$archive")" >"${archive}.sha256"

  ok "Bundle creado: $bundle_root"
  ok "Archivo portable: $archive"
  ok "Comprobación: ${archive}.sha256"
  info "Contenido: ${#wallpaper_files[@]} fondos y configuración Lua portable."
  if [[ -d "$bundle_root/payload/extra/zen-look" ]]; then
    info "Extras a aplicar a mano: payload/extra/{zen-look,fastfetch}"
  fi
  if ((${#MONITOR_OUTPUTS[@]} > 0)); then
    info "hl.monitor portable: output vacío en vez de $(join_by_space "${MONITOR_OUTPUTS[@]}")"
  fi
}

verify_bundle() {
  local root=$1
  local wallpaper_path wallpaper_monitor bad_monitor
  [[ -d "$root/payload/config/hypr" ]] || die "No parece un bundle válido: falta payload/config/hypr."
  [[ -f "$root/packages/official.txt" ]] || die "Falta packages/official.txt."
  [[ -f "$root/packages/aur.txt" ]] || die "Falta packages/aur.txt."
  if find "$root/payload" -type l -print -quit | grep -q .; then
    die "El payload contiene enlaces simbólicos y no se acepta por seguridad."
  fi
  for required_file in \
    payload/config/hypr/hyprland.lua \
    payload/config/hypr/hyprland-gui.lua \
    payload/config/hypr/hyprpaper.conf \
    payload/config/kitty/kitty.conf \
    payload/config/kitty/theme.conf \
    payload/config/rofi/config.rasi; do
    [[ -f "$root/$required_file" ]] || die "Falta un archivo obligatorio: $required_file"
  done
  find "$root/payload/wallpapers" -maxdepth 1 -type f -print -quit | grep -q . \
    || die "El bundle no contiene fondos."
  if [[ -f "$root/payload/config/hypr/wallpaper-rotator.sh" ]] \
    && [[ ! -x "$root/payload/config/hypr/wallpaper-rotator.sh" ]]; then
    warn "El rotador de fondos no tiene permiso de ejecución; se corregirá al instalar."
  fi

  # hyprpaper 0.8+ arranca sin fondo si el bloque wallpaper no trae una ruta, y
  # tampoco si esa ruta no está entre las imágenes del bundle. Antes esto solo
  # selige el bloque entero, así que el destino se quedaba sin fondo.
  wallpaper_path=$(sed -n 's/^[[:space:]]*path[[:space:]]*=[[:space:]]*//p' \
    "$root/payload/config/hypr/hyprpaper.conf" | head -n1)
  if [[ -z $wallpaper_path ]]; then
    warn "hyprpaper.conf no fija un fondo de arranque; lo aplicará el rotador."
  elif [[ $wallpaper_path == *__WALLPAPER_DIR__/* ]]; then
    [[ -f "$root/payload/wallpapers/${wallpaper_path##*/}" ]] \
      || die "El fondo de arranque no está entre los wallpapers del bundle: $wallpaper_path"
  elif [[ $wallpaper_path == /* ]]; then
    die "La ruta del fondo de arranque es absoluta y no es portable: $wallpaper_path"
  fi

  # El bloque wallpaper con un nombre de salida solo pintaría ese monitor del
  # equipo de origen, que en el destino puede no existir.
  wallpaper_monitor=$(sed -n 's/^[[:space:]]*monitor[[:space:]]*=[[:space:]]*//p' \
    "$root/payload/config/hypr/hyprpaper.conf" | head -n1)
  if [[ -n $wallpaper_monitor && $wallpaper_monitor != '*' ]]; then
    warn "El fondo de arranque de hyprpaper solo se aplica a $wallpaper_monitor;"
    warn "usa monitor = * para que valga para todas las salidas del destino."
  fi

  # Un nombre de salida dentro de hl.monitor ataría el bundle a este equipo.
  # Solo se miran las líneas de verdad: los ejemplos en comentarios se dejan.
  bad_monitor=$(awk '
    /^[[:space:]]*--/ { next }
    /^[[:space:]]*hl\.monitor[[:space:]]*\(/ { in_block = 1 }
    in_block && /^[[:space:]]*\}/ { in_block = 0 }
    in_block && match($0, /^[[:space:]]*output[[:space:]]*=[[:space:]]*"[^"]+"/) {
      print NR
      exit
    }
  ' "$root/payload/config/hypr/hyprland.lua")
  [[ -z $bad_monitor ]] \
    || die "El bundle fija un nombre de salida en hl.monitor (línea $bad_monitor) y no es portable."
  if [[ -f "$root/manifest.sha256" ]]; then
    require_command sha256sum
    (cd "$root" && sha256sum --quiet -c manifest.sha256) \
      || die "La suma SHA-256 del bundle no coincide. No se instalará nada."
    ok "Integridad del payload verificada."
  else
    warn "El bundle no contiene manifest.sha256; se omite la verificación de integridad."
  fi
}

detect_arch() {
  local id=''
  if [[ -r /etc/os-release ]]; then
    id=$(awk -F= '$1=="ID" {gsub(/"/, "", $2); print $2; exit}' /etc/os-release)
  fi
  [[ "$id" == arch ]] || die "Este instalador está preparado para Arch Linux; el destino es: ${id:-desconocido}."
  require_command pacman
}

package_is_installed() {
  pacman -Q "$1" >/dev/null 2>&1
}

find_aur_helper() {
  local helper
  for helper in yay paru pikaur; do
    if command -v "$helper" >/dev/null 2>&1; then
      printf '%s' "$helper"
      return 0
    fi
  done
  return 1
}

validate_required_commands() {
  local command_name
  local -a missing_commands=()
  for command_name in \
    hyprctl hyprpaper kitty yazi rofi zen-browser discord fastfetch \
    hyprshot hyprshutdown wpctl brightnessctl playerctl; do
    command -v "$command_name" >/dev/null 2>&1 || missing_commands+=("$command_name")
  done
  if ((${#missing_commands[@]} > 0)); then
    error "Comandos ausentes tras instalar: $(join_by_space "${missing_commands[@]}")"
    return 1
  fi
  ok "Todos los comandos de los atajos están disponibles."
}

install_dependencies() {
  local package helper
  if ((${#MISSING_OFFICIAL[@]} > 0)); then
    info "Paquetes oficiales faltantes: $(join_by_space "${MISSING_OFFICIAL[@]}")"
    command -v sudo >/dev/null 2>&1 || die "Se requiere sudo para instalar paquetes oficiales."
    sudo pacman -S --needed --noconfirm "${MISSING_OFFICIAL[@]}"
  else
    ok "Todos los paquetes oficiales requeridos ya están instalados."
  fi

  if ((${#MISSING_AUR[@]} > 0)); then
    helper=$(find_aur_helper) || die "Faltan $(join_by_space "${MISSING_AUR[@]}") y no se encontró yay, paru o pikaur. Instala un helper AUR y repite."
    info "Paquetes AUR faltantes: $(join_by_space "${MISSING_AUR[@]}") (helper: $helper)"
    case "$helper" in
      yay) yay -S --needed --noconfirm "${MISSING_AUR[@]}" ;;
      paru) paru -S --needed --noconfirm "${MISSING_AUR[@]}" ;;
      pikaur) pikaur -S --noconfirm "${MISSING_AUR[@]}" ;;
    esac
  else
    ok "Todos los paquetes AUR requeridos ya están instalados."
  fi

  for package in "${MISSING_OFFICIAL[@]}" "${MISSING_AUR[@]}"; do
    package_is_installed "$package" || die "El gestor no dejó instalado el paquete requerido: $package"
  done
}

backup_destination() {
  local backup=$1 clean_install=$2
  local component relative source destination backup_copy
  : >"$backup/archivos-Existentes.txt"
  : >"$backup/archivos-nuevos.txt"

  if ((clean_install)); then
    : >"$backup/directorios-originales.txt"
    mkdir -p -- "$backup/directorios-originales"
    for component in "${COMPONENTS[@]}"; do
      source="$CONFIG_HOME/$component"
      if [[ -e "$source" || -L "$source" ]]; then
        cp -a -- "$source" "$backup/directorios-originales/$component"
        printf '%s\n' "$component" >>"$backup/directorios-originales.txt"
      fi
    done
  else
    while IFS= read -r -d '' source; do
      relative=${source#"$STAGE_DIR/config/"}
      destination="$CONFIG_HOME/$relative"
      if [[ -e "$destination" || -L "$destination" ]]; then
        backup_copy="$backup/existentes/$relative"
        mkdir -p -- "$(dirname -- "$backup_copy")"
        cp -a -- "$destination" "$backup_copy"
        printf '%s\n' "$relative" >>"$backup/archivos-Existentes.txt"
      else
        printf '%s\n' "$relative" >>"$backup/archivos-nuevos.txt"
      fi
    done < <(find "$STAGE_DIR/config" -type f -print0)
  fi

  if [[ -e "$WALLPAPER_DIR" || -L "$WALLPAPER_DIR" ]]; then
    cp -a -- "$WALLPAPER_DIR" "$backup/fondos-originales"
    printf 'Los fondos originales están en: %s\n' "$backup/fondos-originales" >"$backup/fondos.txt"
  else
    printf 'No existía una carpeta de fondos gestionada.\n' >"$backup/fondos.txt"
  fi
}

apply_staged_files() {
  local clean_install=$1
  local component source relative destination
  mkdir -p -- "$CONFIG_HOME"

  if ((clean_install)); then
    for component in "${COMPONENTS[@]}"; do
      rm -rf -- "${CONFIG_HOME:?}/$component" || return 1
      cp -a -- "$STAGE_DIR/config/$component" "$CONFIG_HOME/$component" || return 1
    done
    rm -rf -- "$WALLPAPER_DIR" || return 1
  else
    while IFS= read -r -d '' source; do
      relative=${source#"$STAGE_DIR/config/"}
      destination="$CONFIG_HOME/$relative"
      mkdir -p -- "$(dirname -- "$destination")"
      rm -rf -- "$destination"
      cp -a -- "$source" "$destination"
    done < <(find "$STAGE_DIR/config" -type f -print0)
  fi

  # El rotador tiene que quedar ejecutable aunque el bundle lo traiga sin permiso.
  if [[ -f "$CONFIG_HOME/hypr/wallpaper-rotator.sh" ]]; then
    chmod 0755 "$CONFIG_HOME/hypr/wallpaper-rotator.sh" || return 1
  fi

  mkdir -p -- "$WALLPAPER_DIR" || return 1
  cp -a -- "$STAGE_DIR/wallpapers/." "$WALLPAPER_DIR/" || return 1
}

restore_backup() {
  local backup=$1 component relative destination
  warn "Restaurando la configuración anterior..."

  if [[ -f "$backup/directorios-originales.txt" ]]; then
    for component in "${COMPONENTS[@]}"; do
      rm -rf -- "${CONFIG_HOME:?}/$component"
    done
    while IFS= read -r component || [[ -n "$component" ]]; do
      [[ -n "$component" ]] || continue
      local conocido=0
      local permitido
      for permitido in "${COMPONENTS[@]}"; do
        [[ $permitido == "$component" ]] && conocido=1
      done
      ((conocido)) || { error "Componente inválido en la copia de seguridad: $component"; return 1; }
      cp -a -- "$backup/directorios-originales/$component" "$CONFIG_HOME/$component"
    done <"$backup/directorios-originales.txt"
  else
    if [[ -f "$backup/archivos-nuevos.txt" ]]; then
      while IFS= read -r relative; do
        [[ -n "$relative" ]] || continue
        destination="$CONFIG_HOME/$relative"
        rm -f -- "$destination"
      done <"$backup/archivos-nuevos.txt"
    fi

    if [[ -f "$backup/archivos-Existentes.txt" ]]; then
      while IFS= read -r relative; do
        [[ -n "$relative" ]] || continue
        destination="$CONFIG_HOME/$relative"
        mkdir -p -- "$(dirname -- "$destination")"
        cp -a -- "$backup/existentes/$relative" "$destination"
      done <"$backup/archivos-Existentes.txt"
    fi
  fi

  rm -rf -- "$WALLPAPER_DIR"
  if [[ -e "$backup/fondos-originales" || -L "$backup/fondos-originales" ]]; then
    mkdir -p -- "$(dirname -- "$WALLPAPER_DIR")"
    cp -a -- "$backup/fondos-originales" "$WALLPAPER_DIR"
  fi
}

activate_installation() {
  local errors

  if command -v fc-cache >/dev/null 2>&1; then
    fc-cache -f >/dev/null 2>&1 || warn "No se pudo regenerar la caché de fuentes."
  fi

  if systemctl --user has-unit wireplumber.service >/dev/null 2>&1; then
    systemctl --user enable --now wireplumber.service >/dev/null 2>&1 \
      || warn "WirePlumber quedó instalado; no se pudo iniciar el servicio de usuario."
  fi

  if ! hyprctl instances -j >/dev/null 2>&1; then
    info "No hay una sesión Hyprland activa: los cambios se aplicarán al próximo inicio de sesión."
    return 0
  fi

  if hyprctl reload config-only >/dev/null 2>&1; then
    errors=$(hyprctl configerrors 2>&1 || true)
    if [[ -n ${errors//[[:space:]]/} ]]; then
      printf '%s\n' "$errors" >&2
      return 1
    fi
    ok "Hyprland recargó la configuración sin errores."
  else
    return 1
  fi

  pkill -x hyprpaper >/dev/null 2>&1 || true
  # El rotador se relanza con hyprpaper; el cerrojo del script evita duplicados.
  pkill -f 'wallpaper-rotator\.sh rotar' >/dev/null 2>&1 || true
  sleep 0.3
  # Con la configuración Lua de Hyprland 0.55+ el dispatch necesita una
  # expresión de Lua, no la forma antigua "exec <orden>".
  hyprctl dispatch "hl.dsp.exec_cmd('hyprpaper')" >/dev/null 2>&1 \
    || hyprpaper >/dev/null 2>&1 &
  ok "Hyprpaper reiniciado con la configuración nueva."
}

install_bundle() {
  local bundle=${1:-}
  local stage_timestamp package
  local ASSUME_YES=0 DRY_RUN=0 SKIP_PACKAGES=0 SKIP_AUR=0 NO_ACTIVATE=0
  local CLEAN_INSTALL=1
  local custom_backup_root=''

  if (($# > 0)) && [[ "$1" != -* ]]; then
    shift
  fi

  while (($# > 0)); do
    case "$1" in
      --yes) ASSUME_YES=1 ;;
      --dry-run) DRY_RUN=1 ;;
      --skip-packages) SKIP_PACKAGES=1 ;;
      --skip-aur) SKIP_AUR=1 ;;
      --no-activate) NO_ACTIVATE=1 ;;
      --keep-config) CLEAN_INSTALL=0 ;;
      --backup-root)
        (($# >= 2)) || die "--backup-root requiere una ruta."
        custom_backup_root=$2
        shift
        ;;
      -h|--help) usage; return 0 ;;
      *) die "Opción desconocida: $1" ;;
    esac
    shift
  done

  [[ $EUID -ne 0 ]] || die "Ejecuta el instalador como el usuario normal; usará sudo solo para pacman."
  [[ -n ${HOME:-} ]] || die "HOME no está definido."
  require_command realpath

  BUNDLE_ROOT=$(resolve_path "${bundle:-$SCRIPT_DIR}")
  verify_bundle "$BUNDLE_ROOT"
  detect_arch

  mapfile -t OFFICIAL_PACKAGE_LIST < <(read_package_file "$BUNDLE_ROOT/packages/official.txt")
  mapfile -t AUR_PACKAGE_LIST < <(read_package_file "$BUNDLE_ROOT/packages/aur.txt")

  if ((SKIP_AUR)); then
    AUR_PACKAGE_LIST=()
  fi

  MISSING_OFFICIAL=()
  MISSING_AUR=()
  for package in "${OFFICIAL_PACKAGE_LIST[@]}"; do
    [[ -z "$package" ]] || ! package_is_installed "$package" || continue
    MISSING_OFFICIAL+=("$package")
  done
  for package in "${AUR_PACKAGE_LIST[@]}"; do
    [[ -z "$package" ]] || ! package_is_installed "$package" || continue
    MISSING_AUR+=("$package")
  done

  if ((SKIP_AUR)); then
    warn "Se omiten Zen Browser y la fuente Departure porque se usó --skip-aur."
  fi
  if ((!SKIP_PACKAGES)); then
    if ((${#MISSING_OFFICIAL[@]} > 0)); then
      command -v sudo >/dev/null 2>&1 || die "Se requiere sudo para instalar los paquetes oficiales."
      for package in "${MISSING_OFFICIAL[@]}"; do
        pacman -Si "$package" >/dev/null 2>&1 \
          || die "La base de pacman no conoce $package. Ejecuta «sudo pacman -Syu» y repite; el programa no hará una actualización parcial."
      done
    fi
    if ((${#MISSING_AUR[@]} > 0)); then
      find_aur_helper >/dev/null \
        || die "Faltan $(join_by_space "${MISSING_AUR[@]}") y no se encontró yay, paru o pikaur. Instala un helper AUR y repite."
    fi
  fi

  CONFIG_HOME=${XDG_CONFIG_HOME:-$HOME/.config}
  DATA_HOME=${XDG_DATA_HOME:-$HOME/.local/share}
  WALLPAPER_DIR="$DATA_HOME/hyprland/wallpapers"
  STAGE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/hyprland-transfer-install.XXXXXX")
  trap 'rm -rf -- "${STAGE_DIR:-}"' EXIT

  [[ "$CONFIG_HOME" != *$'\n'* && "$DATA_HOME" != *$'\n'* ]] || die "Las rutas XDG no pueden contener saltos de línea."
  [[ "$CONFIG_HOME" == /* && "$DATA_HOME" == /* ]] || die "Las rutas XDG deben ser absolutas."
  [[ "$CONFIG_HOME" != / && "$DATA_HOME" != / ]] || die "Se ha rechazado una ruta XDG peligrosa."

  cp -a -- "$BUNDLE_ROOT/payload/config" "$STAGE_DIR/config"
  mkdir -p "$STAGE_DIR/wallpapers"
  cp -a -- "$BUNDLE_ROOT/payload/wallpapers/." "$STAGE_DIR/wallpapers/"

  # Solo los componentes que el bundle trae de verdad. Así una instalación
  # limpia no borra una carpeta que el payload no va a reponer.
  COMPONENTS=()
  for candidate_component in hypr kitty rofi fastfetch; do
    [[ -d "$STAGE_DIR/config/$candidate_component" ]] \
      && COMPONENTS+=("$candidate_component")
  done
  ((${#COMPONENTS[@]} > 0)) || die "El bundle no contiene ninguna configuración que instalar."

  replace_literal "$STAGE_DIR/config/hypr/hyprpaper.conf" '__WALLPAPER_DIR__' "$WALLPAPER_DIR"
  if [[ -f "$STAGE_DIR/config/hypr/wallpaper-rotator.sh" ]]; then
    replace_literal "$STAGE_DIR/config/hypr/wallpaper-rotator.sh" '__WALLPAPER_DIR__' "$WALLPAPER_DIR"
  fi
  if [[ -f "$STAGE_DIR/config/fastfetch/config.jsonc" ]]; then
    replace_literal "$STAGE_DIR/config/fastfetch/config.jsonc" '__WALLPAPER_DIR__' "$WALLPAPER_DIR"
  fi
  replace_literal "$STAGE_DIR/config/kitty/theme.conf" '__CONFIG_HOME__' "$CONFIG_HOME"

  if grep -RIl '__[A-Z_][A-Z_]*__' "$STAGE_DIR" >/dev/null 2>&1; then
    die "Quedaron plantillas sin sustituir en la configuración; no se aplicará nada."
  fi

  stage_timestamp=$(timestamp)
  if [[ -n "$custom_backup_root" ]]; then
    BACKUP_DIR="$custom_backup_root/$stage_timestamp"
  else
    BACKUP_DIR="$DATA_HOME/hyprland-transfer/backups/$stage_timestamp"
  fi

  info "Destino de configuración: $CONFIG_HOME"
  info "Destino de fondos: $WALLPAPER_DIR"
  info "Copia de seguridad: $BACKUP_DIR"
  if ((CLEAN_INSTALL)); then
    info "Limpieza: se reemplazarán por completo $(join_by_space "${COMPONENTS[@]}") y los fondos gestionados."
  else
    info "Conservación: se sobrescribirán solo los archivos incluidos y se mantendrán los adicionales."
  fi
  if ((${#MISSING_OFFICIAL[@]} > 0)); then
    info "Oficiales faltantes: $(join_by_space "${MISSING_OFFICIAL[@]}")"
  else
    ok "No faltan paquetes oficiales."
  fi
  if ((${#MISSING_AUR[@]} > 0)); then
    info "AUR faltantes: $(join_by_space "${MISSING_AUR[@]}")"
  else
    ok "No faltan paquetes AUR."
  fi
  if ((SKIP_PACKAGES)); then
    warn "La instalación de paquetes está desactivada por --skip-packages."
  fi

  if ((DRY_RUN)); then
    ok "Simulación completada. No se instaló ni modificó nada."
    return 0
  fi

  if ((CLEAN_INSTALL)); then
    confirm "Se respaldarán y eliminarán las configuraciones de $(join_by_space "${COMPONENTS[@]}") y los fondos gestionados. ¿Continuar?" \
      || die "Operación cancelada; no se modificó nada."
  else
    confirm "Se instalarán los paquetes faltantes y se aplicará esta configuración. ¿Continuar?" \
      || die "Operación cancelada; no se modificó nada."
  fi

  if ((!SKIP_PACKAGES)); then
    install_dependencies
    validate_required_commands \
      || die "Hay comandos de la configuración que no se pudieron instalar; no se copiaron archivos."
  fi

  local version
  version=$(hyprland_version)
  if [[ -n "$version" ]] && [[ "$(printf '%s\n%s\n' 0.55 "$version" | sort -V | head -n1)" != 0.55 ]]; then
    die "Hyprland $version no admite la configuración Lua; se requiere 0.55 o posterior. No se copiaron archivos."
  fi

  mkdir -p -- "$BACKUP_DIR"
  backup_destination "$BACKUP_DIR" "$CLEAN_INSTALL"
  if ! apply_staged_files "$CLEAN_INSTALL"; then
    restore_backup "$BACKUP_DIR"
    die "No se pudieron aplicar todos los archivos. Se restauró la copia anterior: $BACKUP_DIR"
  fi
  if ((CLEAN_INSTALL)); then
    ok "Configuración anterior eliminada y archivos nuevos aplicados."
  else
    ok "Archivos de configuración aplicados sin borrar los adicionales."
  fi

  if ((!NO_ACTIVATE)); then
    if ! activate_installation; then
      restore_backup "$BACKUP_DIR"
      if hyprctl instances -j >/dev/null 2>&1; then
        hyprctl reload config-only >/dev/null 2>&1 || true
      fi
      die "La configuración activa produjo errores y fue restaurada. Revisa: $BACKUP_DIR"
    fi
  else
    info "Servicios y recarga desactivados por --no-activate."
  fi

  ok "Instalación finalizada. Resumen: $BACKUP_DIR"
  info "Si Hyprland no estaba activo, cierra la sesión y vuelve a iniciarla."
  announce_extras "$BUNDLE_ROOT"
}

doctor() {
  local bundle=${1:-}
  local root package config_file command_name version errors failures=0
  local font_family config_home data_home wallpaper_dir

  config_home=${XDG_CONFIG_HOME:-$HOME/.config}
  data_home=${XDG_DATA_HOME:-$HOME/.local/share}
  wallpaper_dir="$data_home/hyprland/wallpapers"

  printf '%sDiagnóstico de Hyprland%s\n' "$C_BLUE" "$C_RESET"
  version=$(hyprland_version)
  if [[ -n "$version" ]]; then
    if [[ "$(printf '%s\n%s\n' 0.55 "$version" | sort -V | head -n1)" == 0.55 ]]; then
      ok "Hyprland $version (compatible con Lua)"
    else
      error "Hyprland $version requiere actualización a 0.55+"
      failures=1
    fi
  else
    warn "Hyprland no está instalado o no se puede consultar"
  fi

  for package in "${OFFICIAL_PACKAGES[@]}"; do
    if package_is_installed "$package" 2>/dev/null; then
      ok "Paquete instalado: $package"
    else
      warn "Paquete oficial ausente: $package"
      failures=1
    fi
  done
  for package in "${AUR_PACKAGES[@]}"; do
    if package_is_installed "$package" 2>/dev/null; then
      ok "Paquete AUR instalado: $package"
    else
      warn "Paquete AUR ausente: $package"
      failures=1
    fi
  done

  for command_name in hyprctl hyprpaper kitty yazi rofi zen-browser discord fastfetch hyprshot hyprshutdown wpctl brightnessctl playerctl; do
    if command -v "$command_name" >/dev/null 2>&1; then
      ok "Comando disponible: $command_name"
    else
      warn "Comando ausente: $command_name"
    fi
  done

  for config_file in \
    "$config_home/hypr/hyprland.lua" \
    "$config_home/hypr/hyprland-gui.lua" \
    "$config_home/hypr/hyprpaper.conf" \
    "$config_home/kitty/kitty.conf" \
    "$config_home/kitty/theme.conf" \
    "$config_home/rofi/config.rasi"; do
    if [[ -f "$config_file" ]]; then
      ok "Archivo presente: $config_file"
    else
      error "Archivo ausente: $config_file"
      failures=1
    fi
  done

  # Si el bloque hl.monitor nombra una salida, esa salida tiene que existir en
  # este equipo; si no, Hyprland se queda sin la escala ni la posición pedidas.
  if command -v hyprctl >/dev/null 2>&1 && hyprctl instances -j >/dev/null 2>&1; then
    local monitor_output monitor_outputs
    monitor_output=$(sed -n \
      's/^[[:space:]]*output[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
      "$config_home/hypr/hyprland.lua" 2>/dev/null | head -n1)
    monitor_outputs=$(hyprctl monitors all 2>/dev/null \
      | sed -n 's/^Monitor \([^ ]*\) .*/\1/p' | tr '\n' ' ')
    if [[ -z $monitor_output ]]; then
      ok "hl.monitor sin nombre de salida: vale para todas."
    elif [[ " $monitor_outputs " == *" $monitor_output "* ]]; then
      ok "hl.monitor aplica a $monitor_output, que está conectada."
    else
      warn "hl.monitor nombra $monitor_output y no está entre las salidas"
      warn "  detectadas: ${monitor_outputs:-ninguna}. Cambia el output si es otro."
    fi
  fi

  if [[ -d "$wallpaper_dir" ]] && find -L "$wallpaper_dir" -maxdepth 1 -type f -print -quit | grep -q .; then
    ok "Fondos presentes en: $wallpaper_dir"
  else
    warn "No se encontraron fondos gestionados en: $wallpaper_dir"
  fi

  # El bloque wallpaper de hyprpaper 0.8 es lo que da un fondo en el arranque,
  # antes de que el rotador aplique el primero suyo. Si falta, el escritorio
  # enseña el fondo propio de Hyprland y parece que los fondos no funcionan.
  local boot_wallpaper
  boot_wallpaper=$(sed -n 's/^[[:space:]]*path[[:space:]]*=[[:space:]]*//p' \
    "$config_home/hypr/hyprpaper.conf" 2>/dev/null | head -n1)
  if [[ -n $boot_wallpaper ]]; then
    if [[ -f $boot_wallpaper ]]; then
      ok "Fondo de arranque de hyprpaper: $boot_wallpaper"
    else
      error "El fondo de arranque de hyprpaper no existe: $boot_wallpaper"
      failures=1
    fi
  elif [[ -f "$config_home/hypr/wallpaper-rotator.sh" ]]; then
    warn "hyprpaper.conf no fija un fondo de arranque; lo pondrá el rotador."
  else
    error "No hay fondo de arranque: hyprpaper.conf sin bloque wallpaper y sin rotador."
    failures=1
  fi

  # El logo solo se ve si el .bashrc llama a fastfetch en cada terminal.
  if [[ -f "$HOME/.bashrc" ]] && grep -qE '^[[:space:]]*fastfetch([[:space:]]|$)' "$HOME/.bashrc"; then
    ok "~/.bashrc lanza fastfetch al abrir cada terminal."
  else
    warn "~/.bashrc no llama a fastfetch: el logo solo se verá al ejecutarlo a mano."
  fi

  # El aspecto de Zen no se transfiere, pero conviene avisar si este equipo lo
  # tiene a medias, porque es lo que hace visible el desenfoque de Hyprland.
  local zen_profile
  zen_profile=$(find_zen_profile "$config_home" || true)
  if [[ -n $zen_profile ]]; then
    if [[ -f "$zen_profile/user.js" ]] \
      && grep -q 'zen\.widget\.linux\.transparency' "$zen_profile/user.js"; then
      ok "Aspecto de Zen activo: $zen_profile/user.js"
    else
      warn "El perfil de Zen no activa la transparencia; el desenfoque no se verá."
    fi
  else
    info "No hay perfil de Zen en $config_home/zen."
  fi

  # El rotador solo sirve si el logo de fastfetch apunta a una imagen que exista.
  local fastfetch_config="$config_home/fastfetch/config.jsonc"
  local logo_file
  if [[ -f "$fastfetch_config" ]]; then
    ok "Configuración de fastfetch presente: $fastfetch_config"
    logo_file=$(sed -n 's/.*"source"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
      "$fastfetch_config" | head -n1)
    if [[ -n "$logo_file" ]]; then
      if [[ -f "$logo_file" ]]; then
        ok "Logo de fastfetch disponible: $logo_file"
      else
        error "El logo de fastfetch no existe: $logo_file"
        failures=1
      fi
    fi
  else
    info "Sin configuración de fastfetch; se usará el logo de Arch."
  fi

  if [[ -f "$config_home/hypr/wallpaper-rotator.sh" ]]; then
    if [[ -x "$config_home/hypr/wallpaper-rotator.sh" ]]; then
      ok "Rotador de fondos ejecutable: $config_home/hypr/wallpaper-rotator.sh"
    else
      error "El rotador de fondos no es ejecutable: $config_home/hypr/wallpaper-rotator.sh"
      failures=1
    fi
    if pgrep -f 'wallpaper-rotator\.sh' >/dev/null 2>&1; then
      ok "El rotador de fondos está en marcha."
    else
      warn "El rotador de fondos no está en marcha; se iniciará al recargar Hyprland."
    fi
  else
    info "No hay rotador de fondos; el fondo no cambiará solo."
  fi

  if command -v fc-match >/dev/null 2>&1; then
    font_family=$(fc-match -f '%{family}' 'DepartureMono Nerd Font Mono' 2>/dev/null || true)
    if [[ "$font_family" == *Departure* ]]; then
      ok "Fuente DepartureMono Nerd Font Mono: $font_family"
    else
      warn "La fuente DepartureMono no coincide; fontconfig usa: ${font_family:-desconocida}"
    fi
    font_family=$(fc-match -f '%{family}' 'JetBrainsMono NF' 2>/dev/null || true)
    if [[ "$font_family" == *JetBrains* ]]; then
      ok "Fuente JetBrainsMono NF: $font_family"
    else
      warn "La fuente JetBrainsMono NF no coincide; fontconfig usa: ${font_family:-desconocida}"
    fi
  fi

  if hyprctl instances -j >/dev/null 2>&1; then
    errors=$(hyprctl configerrors 2>&1 || true)
    if [[ -z ${errors//[[:space:]]/} ]]; then
      ok "Hyprland no reporta errores de configuración."
    else
      error "Hyprland reporta errores:"
      printf '%s\n' "$errors"
      failures=1
    fi
  else
    info "No hay una sesión Hyprland activa para validar en caliente."
  fi

  if [[ -n "$bundle" ]]; then
    root=$(resolve_path "$bundle")
    verify_bundle "$root"
    info "Bundle verificado: $root"
  fi

  if ((failures)); then
    warn "El diagnóstico encontró elementos pendientes."
    return 1
  fi
  ok "Todos los elementos comprobados están listos."
}

main() {
  local command_name=${1:-}
  case "$command_name" in
    export)
      shift
      export_bundle "$@"
      ;;
    install)
      shift
      install_bundle "$@"
      ;;
    doctor|check)
      shift
      doctor "$@"
      ;;
    -h|--help|help)
      usage
      ;;
    --yes|--dry-run|--skip-packages|--skip-aur|--no-activate|--keep-config|--backup-root)
      if [[ -f "$SCRIPT_DIR/payload/config/hypr/hyprland.lua" ]]; then
        install_bundle "$SCRIPT_DIR" "$@"
      else
        die "Esta opción solo se puede usar desde un bundle extraído."
      fi
      ;;
    '')
      if [[ -f "$SCRIPT_DIR/payload/config/hypr/hyprland.lua" ]]; then
        install_bundle "$SCRIPT_DIR"
      else
        usage
      fi
      ;;
    *) usage >&2; die "Comando desconocido: $command_name" ;;
  esac
}

main "$@"
