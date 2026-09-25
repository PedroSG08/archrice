// ┌──────────────────────────────────────────────────────────────────────────┐
// │ Zen Browser — fondo transparente + blur (acrylic) sobre Hyprland          │
// │ Editado a mano: user.js se aplica en CADA arranque y pisa prefs.js.       │
// │ Para desactivarlo, comenta la línea con //                               │
// └──────────────────────────────────────────────────────────────────────────┘

// Zen: pone transparente el fondo de la ventana en Linux.
// Es lo que activa el bloque `@media (-moz-platform: linux) and
// -moz-pref("zen.widget.linux.transparency")` de zen-theme.css
// (background: transparent + --zen-themed-toolbar-bg-transparent: transparent).
user_pref("zen.widget.linux.transparency", true);

// Zen: barra lateral y toolbar translúcidos (0.6 de alfa) en vez de opacas.
user_pref("zen.theme.acrylic-elements", true);

// ───────────────────────────────────────────────────────────────────────────
// Modo oscuro en TODO el navegador (el SO está en claro, así que hay que
// forzar las tres capas: apariencia, tema nativo y Zen).
// ───────────────────────────────────────────────────────────────────────────

// 1) Apariencia oscura: es lo que enciende light-dark()/color-scheme en la
//    barra de pestañas, la barra de direcciones y los menús.
user_pref("ui.systemUsesDarkTheme", 1);

// 2) Tema integrado oscuro (por defecto estaba el claro default-theme@mozilla.org).
user_pref("extensions.activeThemeID", "firefox-compact-dark@mozilla.org");

// 3) Zen siempre en oscuro, en vez de "automático" (que seguiría al SO claro).
user_pref("zen.view.window.scheme", 0);

// Websites que respetan prefers-color-scheme: dark.
user_pref("layout.css.prefers-color-scheme.content-override", 0);
