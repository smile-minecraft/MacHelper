<p align="center">
  <img src="docs/images/mascot.gif" width="200" alt="El slime de MacHelper respirando, saludando, saltando y celebrando">
</p>

<h1 align="center">MacHelper</h1>

<p align="center">
  <b>Monitor del sistema nativo para macOS, control de ventiladores, limpiador, analizador de disco y CLI lista para IA — local por defecto, código abierto y diseñada para Apple Silicon.</b>
</p>

<p align="center">
  <a href="https://github.com/smile-minecraft/MacHelper/releases/latest"><img src="https://img.shields.io/github/v/release/smile-minecraft/MacHelper?label=Release&color=5b8def" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-1f2430" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Apple%20Silicon-arm64-1f2430" alt="Apple Silicon">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-4cc38a" alt="MIT license"></a>
  <a href="https://smile-minecraft.github.io/MacHelper/"><img src="https://img.shields.io/badge/Website-Docs-5b8def" alt="Sitio web y documentación"></a>
</p>

<p align="center">
  <a href="README.md">English</a> ·
  <a href="README.zh-Hant.md">繁體中文</a> ·
  <a href="README.zh-Hans.md">简体中文</a> ·
  <a href="README.ja.md">日本語</a> ·
  <a href="README.ko.md">한국어</a> ·
  <b>Español</b>
</p>

<p align="center">
  <a href="#por-qué-machelper">Por qué MacHelper</a> ·
  <a href="#instalación">Instalación</a> ·
  <a href="#funciones">Funciones</a> ·
  <a href="#privacidad-y-telemetría">Privacidad</a> ·
  <a href="#primer-inicio">Primer inicio</a> ·
  <a href="#línea-de-comandos">CLI</a> ·
  <a href="#úsalo-con-agentes-de-ia">Agentes de IA</a> ·
  <a href="#preguntas-frecuentes">FAQ</a> ·
  <a href="#compilar-desde-el-código-fuente">Compilar</a>
</p>

<p align="center">
  <img src="docs/images/menubar.png" width="320" alt="MacHelper en la barra de menús: CPU con una línea, memoria y temperatura">
</p>

<p align="center">
  <img src="docs/images/overview.png" width="860" alt="Resumen: puntuación de salud, lecturas en directo y las apps que más recursos usan">
</p>

---

MacHelper es una app de barra de menús y herramienta de línea de comandos gratuita, con licencia MIT y escrita en Swift nativo para Macs con Apple Silicon y macOS 14 o posterior. Reúne en una sola app ligera un **monitor del sistema** (CPU, GPU, memoria, temperaturas, ventiladores, consumo, batería, disco y red), **control de ventiladores**, **limpiador de cachés y basura**, **analizador de espacio en disco** y **desinstalador de apps**.

También incluye la CLI `machelper` con salida `--json`, un informe de diagnóstico anonimizado en una sola llamada (`machelper report --json`) y skills integradas para asistentes de IA como Claude Code, Codex y OpenCode: siempre muestra una vista previa primero y pregunta antes de eliminar nada.

## Por qué MacHelper

En lugar de pagar y mantener cinco utilidades distintas, MacHelper lo reúne todo en una sola app nativa:

| Capacidad | Sustituye a | Enfoque de MacHelper |
|---|---|---|
| **Monitor del sistema y barra de menús** | iStat Menus | Sensores nativos SwiftUI/AppKit, desglose P/E cores, historial 1h/24h/7d, 8 estilos |
| **Control y curvas de ventiladores** | Macs Fan Control | RPM fijas o curvas de temperatura personalizadas, modo «solo subir», perfiles por app/energía |
| **Limpieza y mantenimiento** | CleanMyMac | Reglas declarativas, vista previa por defecto, Papelera en riesgo medio/alto, rutas protegidas |
| **Análisis de espacio en disco** | DaisyDisk | Gráfico solar y mapa de árbol con `getattrlistbulk`, duplicados con clones APFS, control de crecimiento |
| **Desinstalador de apps** | AppCleaner | Detección por ID de paquete, helpers, contenedores, launchd y zap de Homebrew + restos huérfanos |
| **Automatización con agentes de IA** | *Exclusivo de MacHelper* | Diagnóstico anonimizado `machelper report --json`, puerta `--yes` y skills para agentes |

> **Gratis · Código abierto (MIT) · Swift nativo · Apple Silicon · Local por defecto**

## Instalación

```sh
brew install --cask smile-minecraft/tap/machelper
```

También puedes descargar `MacHelper-<versión>.dmg` desde [Releases](https://github.com/smile-minecraft/MacHelper/releases/latest) y arrastrar **MacHelper** a Aplicaciones. Cada versión está firmada con Developer ID y notarizada por Apple, con sumas de verificación en `SHA256SUMS.txt` dentro de cada publicación. Visita también el [sitio web de MacHelper](https://smile-minecraft.github.io/MacHelper/) para ver un resumen y las novedades de la versión.

**Actualizaciones automáticas:** MacHelper busca actualizaciones en segundo plano y muestra el botón **Actualizar a x.y.z** en la barra lateral, el panel de la barra de menús y Ajustes; no instala nada hasta que lo pulsas. Las notas de la versión aparecen en el idioma que hayas elegido para la app.

## Funciones

<table>
  <tr>
    <td width="50%" valign="top">
      <h3>Monitor del sistema</h3>
      <img src="docs/images/monitor.png" alt="Monitor: gráficas de CPU, GPU, memoria, temperatura, ventiladores y consumo con líneas de aviso">
      <p>Gráficas en directo e historial minuto a minuto (1 hora, 24 horas o 7 días) para CPU (núcleos de rendimiento y eficiencia), GPU, presión de memoria, temperaturas, ventiladores, consumo, batería y velocidad de disco y red, con líneas de aviso para memoria y calor. Personaliza cada elemento de la barra de menús como texto, línea, columnas, barra, anillo, bloques, píldora de calor o doble línea.</p>
    </td>
    <td width="50%" valign="top">
      <h3>Revisión de salud</h3>
      <img src="docs/images/health.png" alt="Revisión de salud: puntuación, lecturas de las últimas 24 horas e historial de espacio libre">
      <p>Calcula una puntuación de salud a partir del historial reciente, el espacio libre en disco y los ítems en segundo plano, explicando qué la redujo y qué hacer. Incluye una auditoría de solo lectura de Gatekeeper, FileVault, el firewall, la Protección de la Integridad del Sistema (SIP), las actualizaciones automáticas de seguridad y XProtect.</p>
    </td>
  </tr>
  <tr>
    <td colspan="2" valign="top">
      <h3>Análisis de disco</h3>
      <img src="docs/images/disk.png" alt="Análisis de disco: gráfico solar de la carpeta de inicio junto a sus carpetas más grandes">
      <p>Gráfico solar y mapa de árbol interactivos (haz clic en cualquier carpeta para entrar), archivos más grandes con filtros de tipo y antigüedad, detección de duplicados (comprende clones APFS y enlaces duros), cambios de crecimiento entre análisis y sugerencias de espacio para archivos grandes sin usar y carpetas infladas. Arrastra ítems al recolector y muévelos a la Papelera de una sola vez.</p>
    </td>
  </tr>
</table>

| Área | Lo más destacado |
|---|---|
| **Control de ventiladores** | Automático, velocidad fija o curvas de temperatura (Silencioso, Equilibrado, Rendimiento, Personalizado), modo «solo subir», límites de seguridad estrictos y perfiles que cambian automáticamente según la app activa o la alimentación. |
| **Optimizar con un clic** | Reglas declarativas con vista previa: las cachés de bajo riesgo se eliminan directamente y los ítems de riesgo medio o alto van a la Papelera. Incluye rutas protegidas, lista de exclusiones, registro de operaciones, tareas de mantenimiento, limpieza de artefactos de compilación y limpieza automática programada. |
| **Desinstalador de apps** | Rastrea restos mediante IDs de paquete, helpers incrustados, permisos, metadatos de contenedores, propietarios de `launchd`, listas zap de Homebrew y reglas por app. Las coincidencias solo por nombre se marcan para revisión y también detecta restos de apps ya eliminadas. |
| **Ítems de inicio** | Gestiona tus Launch Agents (desactivar, activar, eliminar) e inspecciona agentes de todos los usuarios y daemons del sistema, marcando las apps propietarias y los elementos rotos. |
| **Actualizaciones de Homebrew** | Revisa y actualiza apps y casks instalados con Homebrew directamente desde MacHelper. |
| **Avisos** | Notificaciones configurables por temperatura alta de la CPU, presión de memoria crítica y poco espacio en disco. |
| **Historial opcional** | El historial de procesos, sensores y núcleos está desactivado por defecto. El de procesos guarda solo nombre, CPU y memoria (sin rutas, argumentos ni nombres de usuario), con retención de 1 a 30 días. |
| **El slime** | La mascota refleja el estado del Mac (azul, amarillo, rojo), reacciona a clics, puntero, arrastre, calor y limpiezas completadas, y respeta Reducir movimiento y VoiceOver. |
| **Idiomas** | Inglés, chino tradicional, chino simplificado, japonés, coreano y español. Configurable de forma independiente a macOS en **Ajustes → General → Idioma**. |

## Privacidad y telemetría

- **Local por defecto.** Todo lo que MacHelper mide, analiza y guarda permanece en tu Mac. No hay cuentas de usuario, sincronización en la nube ni rastreo en segundo plano. Salvo la comprobación de actualizaciones, MacHelper no realiza conexiones de red a menos que tú lo actives expresamente.
- **Telemetría opcional (DESACTIVADA por defecto).** En **Ajustes → General → Privacidad y diagnóstico** puedes activar voluntariamente el envío de contadores de uso estrictamente anónimos y diagnósticos básicos de rendimiento (versión de la app, versión de macOS, familia del chip y contadores anonimizados).
- **Cero datos sensibles.** Nunca se recopilan rutas de archivos, nombres de procesos, contenido del disco, nombres de equipo ni identificadores personales. Puedes previsualizar el payload JSON exacto dentro de Ajustes antes de que se envíe nada y desactivarlo en cualquier momento; al apagarlo se borran de inmediato el identificador anónimo y la cola pendiente.

## Primer inicio

MacHelper te guía paso a paso por dos permisos opcionales. El resto de las funciones trabaja sin ellos:

1. **Acceso total al disco** permite al análisis de disco y la limpieza inspeccionar ubicaciones protegidas como las descargas de Mail y cachés de otras apps. Activa MacHelper en **Ajustes del Sistema → Privacidad y seguridad → Acceso total al disco**; el asistente detecta el cambio automáticamente. Las carpetas protegidas por SIP siguen siendo ilegibles y se muestran aparte.
2. **El Helper** es un ligero daemon con privilegios de root para controlar los ventiladores, limpiar cachés y registros del sistema, leer ítems en segundo plano del sistema y consultar el uso de procesos del sistema. La guía lo instala, abre **Ajustes del Sistema → General → Ítems de inicio y extensiones** para que lo apruebes y verifica su respuesta. Valida la firma de código de cada llamada. Si está apagado, **Configurar Helper…** al pie de la barra lateral vuelve a abrir la guía.

## Línea de comandos

La app incluye la CLI `machelper` (enlazada automáticamente por Homebrew). Todos los comandos muestran una vista previa por defecto y admiten `--json`, lo que resulta ideal para scripts y agentes de IA. Ejecuta `machelper guide` para ver un resumen o `machelper <comando> --help` para las opciones de cada comando.

```sh
machelper report --json                 # informe completo de diagnóstico anonimizado
machelper status --json                 # instantánea en vivo de hardware, térmicas, ventiladores y batería
machelper clean                         # vista previa de lo que se limpiaría
machelper clean --max-risk low --yes    # limpiar solo los ítems de bajo riesgo
```

## Úsalo con agentes de IA

Cuando le pides a un asistente de IA (Claude Code, Codex, OpenCode, etc.) que averigüe por qué tu Mac va lento o caliente, libere espacio en disco, limpie `node_modules` o restos de Xcode, desinstale una app por completo o audite los ítems de inicio, `machelper` ofrece una interfaz segura y estructurada.

- **Diagnóstico anonimizado en una sola llamada (`machelper report`).** Ejecuta `machelper report --json` (o `machelper report --format markdown`) para generar un informe completo del sistema de una sola vez: hardware, métricas en vivo, puntuación de salud, almacenamiento, auditoría de seguridad, vista previa de limpieza e ítems de inicio. Los nombres de usuario, rutas personales, nombres de host, IPs y direcciones MAC se censuran por defecto, y el JSON incluye `suggestedActions` y `availableTools` estructurados para encadenar con seguridad otros comandos `machelper`.
- **Seguro por defecto.** Los comandos que realizan cambios solo previsualizan y no modifican nada hasta que se añade `--yes`. Los elementos eliminados van a la Papelera salvo que se indique `--permanent`, y las rutas protegidas (Llavero, Mail, Fotos, `~/.ssh`, `~/Documents`, …) nunca se pueden borrar.
- **Legible por máquinas.** `--json` funciona en todos los comandos con un campo `schemaVersion`, códigos de salida predecibles y `machelper --experimental-dump-help` para obtener todo el árbol de comandos en JSON.
- **Skill integrada para agentes.** `machelper skill install claude` o `machelper skill install codex` (también disponible en Ajustes) instala un `SKILL.md` que instruye al agente a inspeccionar y previsualizar primero, y pedir confirmación antes de aplicar cambios.

```sh
brew install --cask smile-minecraft/tap/machelper
machelper guide                          # guía que el agente debe leer primero
machelper report --json                  # informe completo anonimizado + suggestedActions
machelper insights ~ --json              # archivos grandes sin usar y carpetas infladas
machelper clean --json                   # vista previa de limpieza; confirmar antes de --yes
```

Hay un índice optimizado para modelos de lenguaje en [llms.txt](llms.txt).

## Preguntas frecuentes

**¿Existe una alternativa gratuita y de código abierto a CleanMyMac o iStat Menus?**
Sí. MacHelper tiene licencia MIT y combina limpieza, monitor del sistema en la barra de menús, control de ventiladores, análisis de disco y desinstalación de apps en una sola app nativa, sin cuentas ni suscripciones.

**¿Cómo controlo la velocidad de los ventiladores de un Mac con Apple Silicon?**
Instala MacHelper y configura su Helper (con guía en el primer inicio). Podrás gestionar los ventiladores en automático, a RPM fijas o con curvas de temperatura personalizadas, límites de seguridad estrictos y perfiles automáticos por app o alimentación.

**¿Cómo obtengo un informe seguro del sistema para una IA sin filtrar datos personales?**
Ejecuta `machelper report --json` (o `--format markdown`). Recopila hardware, métricas, puntuación de salud, almacenamiento, comprobaciones de seguridad, vista previa de limpieza e ítems de inicio en una sola llamada, censurando automáticamente nombres de usuario, rutas, hostnames, IPs y direcciones MAC.

**¿Cómo libero espacio en disco en un Mac desde la terminal?**
Instala con `brew install --cask smile-minecraft/tap/machelper`, ejecuta `machelper clean` para previsualizar y `machelper clean --max-risk low --yes` para limpiar cachés de bajo riesgo. Usa `machelper insights ~` para localizar archivos grandes sin usar o carpetas infladas, y `machelper purge --path ~/Developer` para borrar carpetas de compilación como `node_modules`, `target` y `.build`.

**¿Cómo desinstalo por completo una app de Mac y sus archivos residuales?**
Ejecuta `machelper uninstall "Nombre de la app"` para previsualizar preferencias, cachés, contenedores, agentes de inicio y coincidencias zap de Homebrew; añade `--yes` para moverlos a la Papelera. Con `machelper uninstall --orphans` encontrarás restos de apps ya eliminadas.

**¿Funciona en Macs Intel o en macOS más antiguo?**
No. MacHelper requiere un Mac con Apple Silicon y macOS 14 o posterior.

**¿Qué datos recopila MacHelper?**
Por defecto no sale nada de tu Mac salvo las comprobaciones de actualización. Si activas explícitamente la telemetría en **Ajustes → General → Privacidad y diagnóstico**, MacHelper envía únicamente contadores de uso anónimos y diagnósticos básicos de rendimiento (versión de la app, versión de macOS, familia de chip) sin rutas de archivos, nombres de procesos ni identificadores personales. Puedes revisar el JSON exacto y desactivarlo en cualquier momento.

## Compilar desde el código fuente

Requisitos: Mac con Apple Silicon, Xcode 26 o posterior y [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). Ejecuta `make` para listar todos los objetivos disponibles.

```sh
make setup      # comprueba herramientas, descarga Sparkle y genera MacHelper.xcodeproj
make open       # abre el proyecto en Xcode para compilar y ejecutar con ⌘R
make run        # o compila una copia Debug en build/ y la abre
make test       # ejecuta las pruebas unitarias de los paquetes Swift
make install    # compilación Release → /Applications/MacHelper.app y reinicio
```

Las compilaciones diarias apuntan a `build/` sin tocar `/Applications`. Cierra cualquier copia instalada de MacHelper antes de ejecutar desde `build/`, ya que ambas comparten ajustes y datos. Para probar cambios en el Helper root (ventiladores, limpieza del sistema), usa `make install`. Ejecuta `make project` tras añadir o quitar archivos fuente, o `make run ARGS=--demo-battery` para simular lecturas de batería en Macs de escritorio.

**Perfilado de rendimiento:** MacHelper incluye instrumentación nativa de Apple con `OSSignposter` en escaneo, muestreo y rutas críticas de interfaz. Usa `scripts/perf/xctrace-profile.sh` para capturar trazas de Instruments directamente desde la línea de comandos durante el desarrollo.

<details>
<summary><b>Referencia para desarrolladores: firma local, estructura del repositorio, capturas, publicación y traducciones</b></summary>

Consulta el [README en inglés](README.md#building) para ver las anulaciones locales de Xcode y firma (`Config/Local.env`, `Config/Local.xcconfig`), la estructura de carpetas, los flags de exportación de capturas y GIF, la guía de publicación y la traducción mediante String Catalogs.

</details>

## Licencia

MIT — consulta [LICENSE](LICENSE).
