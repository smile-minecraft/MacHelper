<p align="center">
  <img src="docs/images/mascot.gif" width="240" alt="El slime de MacHelper respirando, saludando, saltando y celebrando">
</p>

<h1 align="center">MacHelper</h1>

<p align="center">
  <b>Una utilidad para Mac que funciona por completo en local: monitor del sistema, control de ventiladores, limpieza y análisis de disco en una sola app de la barra de menús.</b>
</p>

<p align="center">
  <a href="https://github.com/smile-minecraft/MacHelper/releases/latest"><img src="https://img.shields.io/github/v/release/smile-minecraft/MacHelper?label=release&color=5b8def" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-1f2430" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Apple%20Silicon-arm64-1f2430" alt="Apple Silicon">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-4cc38a" alt="MIT"></a>
</p>

<p align="center">
  <a href="README.md">English</a> · <a href="README.zh-Hant.md">繁體中文</a> · <a href="README.zh-Hans.md">简体中文</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · Español
</p>

<p align="center">
  <img src="docs/images/menubar.png" width="320" alt="MacHelper en la barra de menús: CPU con una línea, memoria y temperatura">
</p>

<p align="center">
  <img src="docs/images/overview.png" width="860" alt="Resumen: puntuación de salud, lecturas en directo y las apps que más recursos usan">
</p>

<p align="center">
  <a href="#instalación"><b>Instalación</b></a> ·
  <a href="#funciones"><b>Funciones</b></a> ·
  <a href="#primer-inicio"><b>Primer inicio</b></a> ·
  <a href="#línea-de-comandos"><b>Línea de comandos</b></a> ·
  <a href="#compilar-desde-el-código-fuente"><b>Compilar</b></a>
</p>

---

Todo lo que MacHelper mide y guarda se queda en tu Mac: sin cuentas, sin analíticas y sin conexiones de red salvo la comprobación de actualizaciones. Necesita macOS 14 o posterior en un Mac con Apple Silicon y es código abierto con licencia MIT.

## Instalación

```sh
brew install --cask smile-minecraft/tap/machelper
```

También puedes descargar `MacHelper-<versión>.dmg` desde [Releases](https://github.com/smile-minecraft/MacHelper/releases/latest) y arrastrar MacHelper a Aplicaciones. Cada versión está firmada con un Developer ID y notarizada por Apple, así que se abre como cualquier otra app. Las sumas de verificación están en `SHA256SUMS.txt`, en la página de cada versión.

MacHelper se mantiene al día solo: cuando la comprobación en segundo plano encuentra una versión nueva, aparece el botón **Actualizar a x.y.z** en la barra lateral, el panel de la barra de menús y Ajustes, y solo se instala al pulsarlo. La ventana de actualización muestra las novedades en el idioma de la app.

## Funciones

<table>
  <tr>
    <td width="50%" valign="top">
      <h3>Monitor</h3>
      <img src="docs/images/monitor.png" alt="Monitor: gráficas de CPU, GPU, memoria, temperatura, ventiladores y consumo con líneas de aviso">
      <p>CPU (núcleos de rendimiento y de eficiencia), GPU, presión de memoria, temperaturas, ventiladores, consumo, batería y velocidad de disco y red. Gráficas en directo e historial por minuto de 1 hora, 24 horas o 7 días, con líneas de aviso para la memoria y el calor. Cada elemento de la barra de menús puede mostrarse como texto, línea, columnas, barra, anillo, bloques, píldora de calor o doble línea.</p>
    </td>
    <td width="50%" valign="top">
      <h3>Revisión de salud</h3>
      <img src="docs/images/health.png" alt="Revisión de salud: puntuación, lecturas de las últimas 24 horas e historial de espacio libre">
      <p>Una puntuación de salud a partir de las últimas horas de historial, el espacio libre y los ítems en segundo plano, con lo que la baja y qué hacer. También revisa en modo de solo lectura Gatekeeper, FileVault, el firewall, la protección de la integridad del sistema, las actualizaciones de seguridad automáticas y XProtect.</p>
    </td>
  </tr>
  <tr>
    <td colspan="2" valign="top">
      <h3>Análisis de disco</h3>
      <img src="docs/images/disk.png" alt="Análisis de disco: gráfico solar de la carpeta de inicio junto a sus carpetas más grandes">
      <p>Gráfico solar y mapa de árbol (haz clic en cualquier carpeta para entrar directamente), los archivos más grandes con filtros por tipo y antigüedad, duplicados (reconoce clones APFS y enlaces duros), qué cambió desde el último análisis y sugerencias de espacio para archivos grandes sin usar y carpetas infladas. Arrastra ítems al recolector y muévelos a la Papelera de una vez.</p>
    </td>
  </tr>
</table>

| | |
|---|---|
| **Control de ventiladores** | Automático, velocidad fija o curvas de temperatura (silencioso, equilibrado, rendimiento, personalizado), modo “solo subir”, límites de seguridad y perfiles que cambian según la app en uso o la fuente de alimentación. |
| **Optimizar con un clic** | Reglas de limpieza con vista previa: las cachés de bajo riesgo se eliminan y las de riesgo medio o alto van a la Papelera. Rutas protegidas, lista de exclusiones, registro de operaciones, tareas de mantenimiento, limpieza de artefactos de compilación y limpieza automática programada. |
| **Desinstalador** | Encuentra lo que deja una app a partir de los ID de paquete, helpers incrustados, permisos, metadatos de contenedores, propietarios de launchd, listas zap de Homebrew y reglas por app. Las coincidencias solo por nombre se marcan para revisar, y también encuentra restos de apps ya eliminadas. |
| **Ítems de inicio** | Tus agentes de inicio (desactivar, activar, eliminar), los agentes de todos los usuarios y los daemons del sistema, con la app propietaria y los ítems rotos marcados. |
| **Actualizaciones de Homebrew** | Actualiza las apps que instalaste con Homebrew. |
| **Skill para agentes de IA** | Instala una skill para Claude Code y Codex para que usen MacHelper con seguridad: siempre previsualizan primero y preguntan antes de eliminar nada. |
| **Avisos** | Notificaciones por temperatura alta de la CPU, presión de memoria crítica y poco espacio en disco. |
| **Historial opcional** | El historial de procesos, sensores y núcleos está desactivado por defecto. El de procesos guarda solo el nombre, la CPU y la memoria (sin rutas, argumentos ni nombres de usuario) y se conserva de 1 a 30 días. |
| **El slime** | La mascota cambia de color según el estado del Mac (azul, amarillo, rojo), reacciona a clics, al puntero y al arrastre, y a eventos como el calor o una limpieza terminada. Respeta Reducir movimiento y VoiceOver. |
| **Idiomas** | Inglés, chino tradicional, chino simplificado, japonés, coreano y español. En Ajustes → General → Idioma puedes elegir uno distinto al del sistema. |

## Primer inicio

MacHelper te guía por dos permisos, de uno en uno. Los dos son opcionales; todo lo demás funciona sin ellos.

1. **Acceso total al disco** permite que el análisis de disco y la limpieza vean lugares protegidos, como las descargas de Mail y las cachés de otras apps. Activa MacHelper en **Ajustes del Sistema → Privacidad y seguridad → Acceso total al disco**; la ventana lo detecta sola. Las carpetas bajo la protección de la integridad del sistema siguen sin poder leerse, y el análisis de disco las muestra aparte.
2. **El Helper** es un pequeño daemon con privilegios de root para el control de ventiladores, la limpieza de cachés y registros del sistema, los ítems en segundo plano del sistema y el uso de los procesos del sistema. La guía lo instala, abre **Ajustes del Sistema → General → Ítems de inicio y extensiones** para que lo permitas y comprueba que responde. Verifica la firma de código de cada llamada. Mientras esté desactivado, **Configurar Helper…** al pie de la barra lateral vuelve a abrir la guía.

## Línea de comandos

La app incluye el comando `machelper` (Homebrew crea el enlace). Todos los comandos muestran una vista previa por defecto y admiten `--json`, así que funcionan bien en scripts y con agentes de IA. Ejecuta `machelper guide` para ver un resumen y `machelper <comando> --help` para cada comando.

```sh
machelper status --json                 # todas las lecturas actuales
machelper clean                         # vista previa de lo que se limpiaría
machelper clean --max-risk low --yes    # limpiar solo lo de bajo riesgo
```

## Compilar desde el código fuente

Necesitas Xcode 16 o posterior y [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen generate
scripts/install.sh          # compilación Release → /Applications/MacHelper.app y reinicio
swift test                  # pruebas unitarias de los paquetes Swift
```

Para la firma, la estructura del proyecto, cómo se hacen las capturas, el proceso de publicación (con las notas de cada idioma) y cómo traducir, consulta el [README en inglés](README.md).

## Licencia

MIT; consulta [LICENSE](LICENSE).
