# Hyprland Transfer

Programa portable para copiar **el aspecto y los atajos** de la configuración
Hyprland de este equipo a otro equipo **Arch Linux**.

El bundle generado:

- instala únicamente los paquetes que falten y estén relacionados con la
  configuración, el aspecto o los comandos registrados en sus atajos;
- copia Hyprland, Hyprpaper, Kitty, Rofi, Fastfetch, los fondos y el aspecto de
  Zen que este equipo tiene escrito a mano, pero **no** los perfiles de Zen,
  Discord, Yazi, navegadores ni otras aplicaciones personales;
- lleva en `payload/extra` lo que no se puede instalar sin pisar archivos
  personales del equipo destino: el `user.js` y el tema CSS de Zen, y el
  fragmento de `.bashrc` que lanza `fastfetch`;
- respalda y reemplaza por completo las carpetas de configuración `hypr`, `kitty`,
  `rofi` y `fastfetch`, además de la carpeta de fondos gestionada;
- convierte las rutas absolutas del equipo de origen a rutas portables;
- deja el bloque `hl.monitor` y el bloque `wallpaper` de hyprpaper puestos para
  **todas** las salidas del destino, no solo para la del equipo de origen, y
  anota el nombre de la salida de origen en un comentario;
- comprueba los SHA-256 del payload antes de instalarlo, y también que el fondo
  de arranque exista en el bundle y que no quede ninguna salida atada al equipo
  de origen;
- recarga Hyprland y comprueba `hyprctl configerrors` si ya hay una sesión
  activa;
- restaura la copia anterior automáticamente si la nueva configuración produce
  errores;
- no cambia la sesión de inicio de GDM y no ejecuta una actualización general
  de Arch.

## Uso en el equipo de destino

1. Copia el directorio `dist/hyprland-look-shortcuts-AAAAMMDD-HHMMSS` o su
   archivo `.tar` al otro equipo.
2. Verifica el hash del archivo:

   ```bash
   sha256sum -c hyprland-look-shortcuts-AAAAMMDD-HHMMSS.tar.sha256
   ```

3. Extrae el archivo:

   ```bash
   tar -xf hyprland-look-shortcuts-AAAAMMDD-HHMMSS.tar
   ```

   Sustituye el nombre por el real y verifica primero que el archivo
   `<archivo>.sha256` contiene el nombre correcto.

4. Entra en el directorio extraído y ejecútalo como usuario normal:

   ```bash
   ./install.sh --dry-run
   ./install.sh
   ```

5. Si Hyprland ya estaba abierto, se recarga automáticamente. Si no, cierra la
   sesión y vuelve a entrar en Hyprland.
6. Aplica a mano lo que viene en `payload/extra` (aspecto de Zen y la línea de
   `fastfetch` para el `.bashrc`). El instalador te recuerda las rutas al
   terminar. Está en [Extras](#extras-lo-que-viaja-pero-no-se-instala).

El instalador necesita `sudo`. Para los dos paquetes de AUR necesita `yay`,
`paru` o `pikaur`.

## Instalación limpia

Por defecto, el programa hace una copia de seguridad y después elimina y
reconstruye estas ubicaciones del destino:

```text
$XDG_CONFIG_HOME/hypr
$XDG_CONFIG_HOME/kitty
$XDG_CONFIG_HOME/rofi
$XDG_CONFIG_HOME/fastfetch
$XDG_DATA_HOME/hyprland/wallpapers
```

Solo se borran las carpetas que el bundle realmente trae. Así una instalación
limpieza nunca elimina una carpeta que el payload no va a reponer.

Así desaparecen las versiones antiguas de esos componentes y los archivos
adicionales que hubiera en ellas. No se eliminan perfiles de Zen, Discord,
Yazi, navegadores ni otras aplicaciones.

La copia de seguridad se conserva y puede revisarse en:

```text
~/.local/share/hyprland-transfer/backups/AAAAMMDD-HHMMSS
```

Para conservar archivos adicionales dentro de esas carpetas, usa:

```bash
./install.sh --keep-config
```

## Paquetes incluidos

### Repositorios oficiales

| Paquete | Motivo |
|---|---|
| `hyprland` | compositor y atajos |
| `hyprpaper` | fondo y autoarranque |
| `kitty` | terminal y apertura de Yazi |
| `rofi` | menú de aplicaciones |
| `yazi` | gestor de archivos abierto desde Kitty |
| `fastfetch` | configuración de fastfetch que se instala y logo del kitty |
| `discord` | destino del atajo `SUPER+D` |
| `hyprshot` | captura del atajo `SUPER+PRINT` |
| `hyprshutdown` | diálogo de apagado de `SUPER+M` |
| `wireplumber` | Necesario para el atajo de volumen y mute |
| `brightnessctl` | atajos de brillo |
| `playerctl` | atajos multimedia |
| `xdg-desktop-portal-hyprland` | portal de capturas de Hyprland |
| `ttf-jetbrains-mono-nerd` | fuente de Rofi |

### AUR

| Paquete | Motivo |
|---|---|
| `zen-browser-bin` | destino del atajo `SUPER+W` |
| `otf-departure-mono-nerd` | fuente configurada en Kitty |

Los catorce paquetes oficiales y los dos de AUR están instalados en el equipo
de origen. Aun así van en la lista: el instalador solo instala los que falten,
así que en el destino funcionan igual los dos casos.

## Archivos transferidos

- `~/.config/hypr/hyprland.lua`
- `~/.config/hypr/hyprland-gui.lua`
- `~/.config/hypr/hyprpaper.conf`
- `~/.config/hypr/wallpaper-rotator.sh`, si existe
- `~/.config/kitty/kitty.conf`
- `~/.config/kitty/theme.conf`
- `~/.config/rofi/config.rasi`
- `~/.config/fastfetch/config.jsonc`, si existe
- Los fondos de `~/Imágenes/wallpapers` (o la alternativa detectada, incluida
  `~/.local/share/hyprland/wallpapers`).

En destino, los fondos quedan en:

```text
~/.local/share/hyprland/wallpapers
```

El logo de fastfetch apunta a una de esas imágenes, así que el bundle la
transporta como cualquier otro fondo y el rotador la deja fuera por su lista
`SKIP`.

## Qué se vuelve portable

Dos cosas del equipo de origen no valen igual en el destino, y la exportación
las reescribe en vez de copiarlas tal cual.

**El bloque `hl.monitor`.** Aquí vale para el panel del portátil:

```lua
hl.monitor({
    output   = "eDP-1",
    mode     = "preferred",
    position = "auto",
    scale    = 1,
})
```

En el bundle la salida se deja vacía, que es la forma de aplicarlo a todas:

```lua
hl.monitor({
    -- La salida del equipo de origen era "eDP-1".
    -- "" deja el bloque para todas las salidas del equipo destino.
    output   = "",
    mode     = "preferred",
    position = "auto",
    scale    = 1,
})
```

La escala entera se conserva, y con ella el comentario que explica por qué: con
`scale = "auto"` Hyprland elegía 1.5 en este panel y las apps sin
`fractional-scale-v1` (Zen, Discord, casi todo XWayland) salían borrosas. Si en
el destino hay varios monitores y quieres posiciones o escalas distintas, edita
ese bloque antes de arrancar Hyprland.

**El bloque `wallpaper` de hyprpaper.** hyprpaper 0.8 usa un bloque propio, y
quitándolo (que es lo que hacía la versión 1.2) hyprpaper arrancaba sin ningún
fondo configurado. Ahora se conserva y se normaliza a `monitor = *`:

```text
wallpaper {
    monitor = *
    path = __WALLPAPER_DIR__/grey_lain_wallpaper.jpg
    fit_mode = cover
}
```

`verify_bundle` rechaza el bundle si esa ruta no está entre las imágenes
transportadas, o si queda un nombre de salida dentro de `hl.monitor`.

## Extras: lo que viaja pero no se instala

`payload/extra` no lo aplica el instalador, porque son archivos personales del
equipo destino. El programa solo recuerda al final dónde está cada cosa.

| Ruta | Qué es | Cómo se aplica |
|---|---|---|
| `payload/extra/zen-look/user.js` | fondo transparente, acrylic y modo oscuro de Zen | se copia al perfil de Zen |
| `payload/extra/zen-look/chrome/` | el tema CSS que limpia la barra de direcciones | se copia a `<perfil>/chrome/` |
| `payload/extra/zen-look/zen-themes.json` | el registro del tema | se copia al perfil |
| `payload/extra/fastfetch/snippet.bash` | la línea `fastfetch` para `.bashrc` | se pega a mano |

Las instrucciones de Zen están en `payload/extra/zen-look/APLICAR.txt`. El perfil
se busca con `prefs.js` dentro de `~/.config/zen`, así que no depende del
nombre de la carpeta.

El `user.js` es lo que activa `zen.widget.linux.transparency`, y eso es lo que
hace visible el `decoration.blur` con `ignore_opacity = true` de
`hyprland.lua`. Sin él, Zen sale opaco y el desenfoque no se ve.

El `.bashrc` nunca se sobrescribe: se entrega el fragmento porque un `.bashrc`
ajeno tiene alias, `PATH` y ajustes propios que no se pueden pisar.

`hyprland-gui.lua` lo genera [HyprMod](https://github.com/hyprwm/hyprmod) y se
transfiere tal cual. No hace falta instalar HyprMod en el destino para que
funcione: el archivo es un `require("hyprland-gui")` de Hyprland. Si allí se
quiere seguir tocando ese bloque desde la interfaz, entonces sí, HyprMod.

## Fondos y fastfetch

Los fondos de `~/.local/share/hyprland/wallpapers` no se quedan fijos:
`~/.config/hypr/wallpaper-rotator.sh` va alternando entre ellos cada 20 minutos
(1200 s) y arranca solo con Hyprland.

Una de las imágenes está reservada para el logo de fastfetch, en lugar del de
Arch, así que el rotador la ignora. Son dos archivos, la imagen original y su
recorte:

```text
ALLqk82.png            # original, 1920x1080
ALLqk82-cropped.png    # la que usa fastfetch, 915x1080
```

Para ellas está `~/.config/fastfetch/config.jsonc`, que fija `"logo"` y repite la
lista de módulos de fastfetch. El tipo de logo es `kitty-direct`: el terminal
recibe el archivo por el protocolo de gráficos de kitty y lo escala al bloque de
28x16 celdas. Por eso el recorte tiene que mantener esa proporción; si cambias
`width` o `height`, vuelve a ajustarlo.

Fuera de kitty el texto de fastfetch sigue saliendo, pero la imagen no.

Comandos del rotador:

```bash
~/.config/hypr/wallpaper-rotator.sh list   # qué imágenes entran en la rotación
~/.config/hypr/wallpaper-rotator.sh next   # cambia el fondo ahora y termina
```

El intervalo se cambia en la variable `INTERVAL` del propio script, y las
imágenes reservadas en su lista `SKIP`.

## Opciones

```text
--yes              No pide la confirmación final.
--dry-run          Muestra el plan y no modifica nada.
--skip-packages    No instala paquetes; solo aplica la configuración.
--skip-aur         Omite Zen Browser y la fuente Departure.
--no-activate      No habilita WirePlumber ni recarga Hyprland.
--keep-config      Conserva archivos extra de las carpetas de configuración.
--backup-root DIR  Cambia la ubicación de las copias de seguridad.
```

Ejemplo para instalar los archivos sin tocar la sesión actual:

```bash
./install.sh --skip-packages --no-activate
```

## Diagnóstico

Desde el bundle:

```bash
./install.sh doctor .
```

Desde el proyecto de origen:

```bash
./hyprland-transfer.sh doctor
```

El diagnóstico comprueba versión Lua de Hyprland, paquetes, comandos,
configuraciones, que el fondo de arranque exista, que el `output` de
`hl.monitor` sea una salida conectada, los fondos, el logo de fastfetch, el
rotador, el fragmento de `.bashrc`, el aspecto de Zen, las fuentes y los errores
activos. Con un bundle como argumento, además verifica el bundle entero.

## Regenerar el bundle

Después de cambiar la configuración de este equipo:

```bash
cd ~/archrice/hyprland-transfer
./hyprland-transfer.sh export
```

La exportación no necesita privilegios y no modifica la configuración actual.
Deja el directorio, el `.tar` y el `.sha256` en `dist/`. Si el intervalo del
rotador ya no es `ROTATOR_INTERVAL` (1200 s), avisa y manda el valor real del
script en el manifiesto y el `LEEME`.

## Copias de seguridad

Por defecto:

En una instalación limpia completa:

```text
~/.local/share/hyprland-transfer/backups/AAAAMMDD-HHMMSS/
├── directorios-originales.txt
├── directorios-originales/
│   ├── hypr/               # solo si existía
│   ├── kitty/              # solo si existía
│   ├── rofi/               # solo si existía
│   └── fastfetch/          # solo si existía
└── fondos-originales/      # solo si existía la carpeta gestionada
```

Con `--keep-config`, se usan `archivos-existentes.txt`, `archivos-nuevos.txt` y
`existentes/` en lugar de una copia completa de las carpetas.

El bundle no instala un servicio adicional ni modifica `/etc`. Solo usa `sudo`
para las transacciones de `pacman` y el helper AUR.
