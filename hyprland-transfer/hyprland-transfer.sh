#!/usr/bin/env bash
# Exporta e instala de forma portable el aspecto y los atajos de Hyprland.
# Compatible con Arch Linux y derivadas que usan pacman.
set -Eeuo pipefail
IFS=$'\n\t'

PROGRAM=${0##*/}
VERSION="1.1.0"
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

readonly -a OFFICIAL_PACKAGES=(
  hyprland
  hyprpaper
  kitty
  rofi
  yazi
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
  doctor   Comprueba paquetes, comandos, fuentes, archivos y erros de Hyprland.

Opciones de install:
  --yes              No pide la confirmación final.
  --dry-run          Muestra el plan y no modifica nada.
  --skip-packages    No instala paquetes; solo aplica la configuración.
  --skip-aur         Omite los dos paquetes de AUR.
  --no-activate      No habilita servicios ni recarga Hyprland.
  --keep-config      Conserva archivos extra de las carpetas de configuración.
  --backup-root DIR  Directorio adicional para copias de seguridad.

Limpieza:
  Por defecto se respaldan y reemplazan por completo las carpetas hypr, kitty y
  rofi, además de la carpeta de fondos gestionada. Los perfiles de otras
  aplicaciones no se tocan.

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

portable_hyprpaper() {
  local source=$1 destination=$2
  awk '
    /^wallpaper[[:space:]]*\{/ { in_block=1; next }
    in_block && /^}/ { in_block=0; next }
    !in_block { print }
  ' "$source" >"$destination"
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

  for source_file in \
    "$hypr_dir/hyprland.lua" \
    "$hypr_dir/hyprland-gui.lua" \
    "$hypr_dir/hyprpaper.conf" \
    "$kitty_dir/kitty.conf" \
    "$kitty_dir/theme.conf" \
    "$rofi_dir/config.rasi"; do
    [[ -f "$source_file" ]] || die "No se encuentra el archivo necesario: $source_file"
  done

  if [[ -d "$HOME/Imágenes/wallpapers" ]]; then
    source_wallpapers="$HOME/Imágenes/wallpapers"
  elif [[ -d "$HOME/Pictures/wallpapers" ]]; then
    source_wallpapers="$HOME/Pictures/wallpapers"
  elif [[ -d "$source_config_home/hypr/wallpapers" ]]; then
    source_wallpapers="$source_config_home/hypr/wallpapers"
  else
    die "No se encuentra la carpeta de fondos del sistema actual."
  fi

  mapfile -d '' -t wallpaper_files < <(
    find "$source_wallpapers" -maxdepth 1 -type f \
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
    "$bundle_root/payload/wallpapers"

  cp -a -- "$hypr_dir/hyprland.lua" "$bundle_root/payload/config/hypr/"
  cp -a -- "$hypr_dir/hyprland-gui.lua" "$bundle_root/payload/config/hypr/"
  portable_hyprpaper \
    "$hypr_dir/hyprpaper.conf" \
    "$bundle_root/payload/config/hypr/hyprpaper.conf"
  if [[ -f "$hypr_dir/hyprpaper-cambios.conf" ]]; then
    cp -a -- "$hypr_dir/hyprpaper-cambios.conf" "$bundle_root/payload/config/hypr/"
  fi

  cp -a -- "$kitty_dir/kitty.conf" "$bundle_root/payload/config/kitty/"
  cp -a -- "$kitty_dir/theme.conf" "$bundle_root/payload/config/kitty/"
  cp -a -- "$rofi_dir/config.rasi" "$bundle_root/payload/config/rofi/"

  for source_file in "${wallpaper_files[@]}"; do
    cp -a -- "$source_file" "$bundle_root/payload/wallpapers/"
  done

  local old_wallpaper_dir="$source_wallpapers"
  replace_literal \
    "$bundle_root/payload/config/hypr/hyprpaper.conf" \
    "$old_wallpaper_dir" "__WALLPAPER_DIR__"
  if [[ -f "$bundle_root/payload/config/hypr/hyprpaper-cambios.conf" ]]; then
    replace_literal \
      "$bundle_root/payload/config/hypr/hyprpaper-cambios.conf" \
      "$old_wallpaper_dir" "__WALLPAPER_DIR__"
  fi
  local home_config_literal="\$HOME/.config"
  replace_literal \
    "$bundle_root/payload/config/kitty/theme.conf" \
    "$home_config_literal" '__CONFIG_HOME__'

  write_package_files "$bundle_root"

  source_version=$(hyprland_version)
  [[ -n "$source_version" ]] || source_version='no detectada'
  cat >"$bundle_root/MANIFIESTO.txt" <<EOF
Bundle de aspecto y atajos de Hyprland
======================================
Formato: 2
Creado: $(date --iso-8601=seconds)
Origen: Arch Linux
Hyprland de origen: ${source_version}
Configuración: ${#OFFICIAL_PACKAGES[@]} paquetes oficiales y ${#AUR_PACKAGES[@]} paquetes AUR
Fondos incluidos: ${#wallpaper_files[@]}
Limpieza predeterminada: completa, después de crear una copia de seguridad

El bloque hyprpaper específico del monitor de origen se omite; la línea
"wallpaper = ,RUTA" aplica el mismo fondo a todos los monitores de destino.
EOF

  cat >"$bundle_root/LEEME.txt" <<'EOF'
INSTALACIÓN
===========
1. Extrae este directorio.
2. Ejecuta como el usuario normal:
       ./install.sh
3. Si aparecen dependencias AUR, debe existir yay, paru o pikaur.
4. Revisa la lista mostrada. El programa no actualiza todo Arch.

El instalador:
- instala solamente los paquetes ausentes;
- respalda las carpetas hypr, kitty, rofi y los fondos gestionados;
- elimina esas configuraciones anteriores y deja solo esta instalación;
- copia Hyprland, Hyprpaper, Kitty, Rofi y los fondos;
- adapta las rutas al usuario y XDG del equipo destino;
- recarga Hyprland si ya hay una sesión activa;
- no cambia la sesión de inicio ni modifica perfiles de otras aplicaciones.

Usa «./install.sh --keep-config» si quieres conservar archivos adicionales
dentro de esas carpetas. La copia de seguridad se conserva en ambos casos.

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
}

verify_bundle() {
  local root=$1
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
    hyprctl hyprpaper kitty yazi rofi zen-browser discord \
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
    for component in hypr kitty rofi; do
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
    for component in hypr kitty rofi; do
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

  mkdir -p -- "$WALLPAPER_DIR" || return 1
  cp -a -- "$STAGE_DIR/wallpapers/." "$WALLPAPER_DIR/" || return 1
}

restore_backup() {
  local backup=$1 component relative destination
  warn "Restaurando la configuración anterior..."

  if [[ -f "$backup/directorios-originales.txt" ]]; then
    for component in hypr kitty rofi; do
      rm -rf -- "${CONFIG_HOME:?}/$component"
    done
    while IFS= read -r component || [[ -n "$component" ]]; do
      [[ -n "$component" ]] || continue
      case "$component" in
        hypr|kitty|rofi) ;;
        *) error "Componente inválido en la copia de seguridad: $component"; return 1 ;;
      esac
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
  sleep 0.2
  if ! hyprctl dispatch exec hyprpaper >/dev/null 2>&1; then
    hyprpaper >/dev/null 2>&1 &
  fi
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

  replace_literal "$STAGE_DIR/config/hypr/hyprpaper.conf" '__WALLPAPER_DIR__' "$WALLPAPER_DIR"
  if [[ -f "$STAGE_DIR/config/hypr/hyprpaper-cambios.conf" ]]; then
    replace_literal "$STAGE_DIR/config/hypr/hyprpaper-cambios.conf" '__WALLPAPER_DIR__' "$WALLPAPER_DIR"
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
    info "Limpieza: se reemplazarán por completo hypr, kitty, rofi y los fondos gestionados."
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
    confirm "Se respaldarán y eliminarán las configuraciones de hypr, kitty, rofi y los fondos gestionados. ¿Continuar?" \
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

  for command_name in hyprctl hyprpaper kitty yazi rofi zen-browser discord hyprshot hyprshutdown wpctl brightnessctl playerctl; do
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

  if [[ -d "$wallpaper_dir" ]] && find "$wallpaper_dir" -maxdepth 1 -type f -print -quit | grep -q .; then
    ok "Fondos presentes en: $wallpaper_dir"
  else
    warn "No se encontraron fondos gestionados en: $wallpaper_dir"
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
