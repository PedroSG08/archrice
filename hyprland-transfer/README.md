# Hyprland Transfer

Programa portable para copiar **el aspecto y los atajos** de la configuración
Hyprland de este equipo a otro equipo **Arch Linux**.

El bundle generado:

- instala únicamente los paquetes que falten y estén relacionados con la
  configuración, el aspecto o los comandos registrados en sus atajos;
- no copia perfiles de Zen, Discord, Yazi, navegadores ni otras aplicaciones
  personales;
- respalda cada archivo que va a sobrescribir;
- convierte las rutas absolutas del equipo de origen a rutas portables;
- omite el monitor `HDMI-A-1` del equipo origen y aplica el fondo a todos los
  monitores del destino;
- comprueba los SHA-256 del payload antes de instalarlo;
- recarga Hyprland y comprueba `hyprctl configerrors` si ya hay una sesión
  activa;
- restaura la copia anterior automáticamente si la nueva configuración produce
  errores;
- no cambia la sesión de inicio de GDM y no ejecuta una actualización general
  de Arch.

## Uso en el equipo de destino

1. Copia el directorio `dist/hyprland-look-shortcuts-AAAAMMDD-HHMMSS` o su
   archivo `.tar.zst` al otro equipo.
2. Verifica el hash del archivo si lo transportaste como archivo comprimido:

   ```bash
   sha256sum -c hyprland-look-shortcuts-AAAAMMDD-HHMMSS.tar.zst.sha256
   ```

3. Extrae el archivo:

   ```bash
   tar --zstd -xf hyprland-look-shortcuts-AAAAMMDD-HHMMSS.tar.zst
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

El instalador necesita `sudo`. Para los dos paquetes de AUR necesita `yay`,
`paru` o `pikaur`.

## Paquetes incluidos

### Repositorios oficiales

| Paquete | Motivo |
|---|---|
| `hyprland` | compositor y atajos |
| `hyprpaper` | fondo y autoarranque |
| `kitty` | terminal y apertura de Yazi |
| `rofi` | menú de aplicaciones |
| `yazi` | gestor de archivos abierto desde Kitty |
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

`brightnessctl`, `playerctl`, `hyprshutdown` y las fuentes no estaban
instalados en el equipo de origen, aunque sus comandos o fuentes aparecen en la
configuración. El instalador los incluye para que la copia en el destino sea
funcional.

## Archivos transferidos

- `~/.config/hypr/hyprland.lua`
- `~/.config/hypr/hyprland-gui.lua`
- `~/.config/hypr/hyprpaper.conf`
- `~/.config/hypr/hyprpaper-cambios.conf`, si existe
- `~/.config/kitty/kitty.conf`
- `~/.config/kitty/theme.conf`
- `~/.config/rofi/config.rasi`
- Los fondos de `~/Imágenes/wallpapers` (o la alternativa detectada).

En destino, los fondos quedan en:

```text
~/.local/share/hyprland/wallpapers
```

El script existente `hyprpaper-cambios.conf` se conserva, pero no se inicia
automáticamente porque tampoco lo estaba en el equipo origen.

## Opciones

```text
--yes              No pide la confirmación final.
--dry-run          Muestra el plan y no modifica nada.
--skip-packages    No instala paquetes; solo aplica la configuración.
--skip-aur         Omite Zen Browser y la fuente Departure.
--no-activate      No habilita WirePlumber ni recarga Hyprland.
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
configuraciones, fondos, fuentes y errores activos.

## Regenerar el bundle

Después de cambiar la configuración de este equipo:

```bash
cd ~/Proyectos/hyprland-transfer
./hyprland-transfer.sh export
```

La exportación no necesita privilegios y no modifica la configuración actual.

## Copias de seguridad

Por defecto:

```text
~/.local/share/hyprland-transfer/backups/AAAAMMDD-HHMMSS/
├── archivos-Existentes.txt
├── archivos-nuevos.txt
├── existentes/
│   ├── hypr/
│   ├── kitty/
│   └── rofi/
└── fondos-originales/       # solo si ya existía la carpeta gestionada
```

El bundle no instala un servicio adicional ni modifica `/etc`. Solo usa `sudo`
para las transacciones de `pacman` y el helper AUR.
