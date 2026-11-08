# MacHelper

[English](README.md) · [繁體中文](README.zh-Hant.md) · [简体中文](README.zh-Hans.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · Español

Una utilidad todo en uno para Mac con macOS 14 o posterior, en la que todos los datos se quedan en tu Mac: control de ventiladores, monitor del sistema en la barra de menús, limpieza con un clic, análisis del disco, desinstalador de apps y gestión de ítems de arranque. Código abierto con licencia MIT.

## Funciones

- **Monitor en la barra de menús**: CPU (núcleos de rendimiento y de eficiencia), GPU, presión de memoria, velocidad del disco y de la red, temperaturas, ventiladores, consumo y batería, cada uno como texto, línea, barra o anillo. También muestra los procesos que más CPU y memoria usan.
- **Historial**: un promedio por minuto, conservado 7 días de forma predeterminada; elige 1, 3, 7, 14 o 30 días en Ajustes → General → Gestión de datos. Se puede consultar la última hora, las últimas 24 horas y los últimos 7 días.
- **Historial opcional de procesos, sensores y núcleos**: desactivado de forma predeterminada; actívalo por separado en Ajustes → General → Gestión de datos. El historial de procesos solo guarda el nombre del proceso y su uso de CPU y memoria (nunca rutas, argumentos de línea de comandos ni nombres de usuario), y solo los 10 primeros por CPU y por memoria de cada minuto.
- **Alertas**: avisos cuando la temperatura de la CPU es alta, la presión de memoria es crítica o queda poco espacio en disco.
- **Control de ventiladores**: automático, velocidad fija o curvas de temperatura (silencioso, equilibrado, rendimiento, personalizado), modo «solo aumentar», límites de seguridad y cambio automático de perfil según la app abierta o la fuente de alimentación. Funciona mediante un Helper con privilegios de root que verifica la firma de quien lo llama.
- **Optimizar con un clic**: primero una vista previa, luego la limpieza. Las cachés y los registros de riesgo bajo se eliminan directamente; los elementos de riesgo medio y alto van a la Papelera. Incluye rutas protegidas, una lista de exclusiones, registro de operaciones, tareas de mantenimiento, purga de artefactos de compilación de proyectos y limpieza automática programada de elementos de riesgo bajo.
- **Análisis del disco**: gráfico sunburst y mapa de árbol, archivos más grandes con filtros por tipo y antigüedad, archivos duplicados (distingue clones de APFS y enlaces duros), cambios desde el último escaneo y un recolector para mover elementos a la Papelera de una vez.
- **Sugerencias de espacio**: archivos grandes sin usar desde hace medio año y carpetas que parecen infladas, marcados en los gráficos.
- **Desinstalador de apps**: encuentra lo que deja una app mediante IDs de paquete, asistentes integrados, entitlements, metadatos de contenedores, propietarios de launchd, listas zap de Homebrew y reglas por app; las coincidencias solo por nombre se marcan para que las revises. También encuentra restos de apps ya eliminadas.
- **Ítems de arranque**: tus Launch Agents (desactivar, activar, eliminar), los agentes de todos los usuarios y los daemons del sistema, con la app propietaria y los ítems rotos señalados.
- **Actualizaciones de apps**: actualiza las apps instaladas con Homebrew.
- **Revisión de seguridad**: lee el estado de Gatekeeper, FileVault, el firewall, la protección de la integridad del sistema, las actualizaciones de seguridad automáticas y XProtect (solo lectura; nunca los cambia).
- **Línea de comandos**: todo se puede automatizar o usar desde agentes de IA. Por defecto solo muestra una vista previa, y todos los comandos admiten `--json`. Ejecuta `machelper guide` para ver un resumen y `machelper <comando> --help` para cada comando.
- **Skill para agentes de IA**: puedes añadir una skill a Claude Code y Codex para que usen MacHelper con seguridad: siempre previsualizan primero y preguntan antes de eliminar nada.
- **Idiomas**: inglés, chino tradicional, chino simplificado, japonés, coreano y español. En Ajustes → General → Idioma puedes elegir uno distinto al del sistema.

## Instalación

Descarga `MacHelper-<versión>.dmg` desde [Releases](https://github.com/smile-minecraft/MacHelper/releases) y arrastra MacHelper a Aplicaciones. O con Homebrew:

```sh
brew install --cask smile-minecraft/tap/machelper
```

MacHelper está firmado con un Developer ID y notarizado por Apple, así que se abre como cualquier otra app. El control de ventiladores y la limpieza del sistema necesitan el Helper: permítelo en **Ajustes del Sistema → General → Ítems de inicio** cuando MacHelper lo pida.

Para ver todo el disco, activa MacHelper en **Ajustes del Sistema → Privacidad y seguridad → Acceso total al disco**. Aun así, las carpetas protegidas por la protección de la integridad del sistema o que pertenecen a otros usuarios no se pueden leer: es una protección de macOS y es normal.

Las sumas de verificación de cada descarga están en `SHA256SUMS.txt`, en la página de la versión.

## Compilar desde el código fuente

Necesitas Xcode 16 o posterior y [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen generate
scripts/install.sh          # compilación Release → /Applications/MacHelper.app y reinicio
swift test                  # pruebas unitarias de los paquetes Swift
```

Para la firma, la estructura del proyecto, el proceso de publicación y cómo traducir, consulta el [README en inglés](README.md).

## Licencia

MIT; consulta [LICENSE](LICENSE).
