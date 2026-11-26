MacHelper corrige el aviso de permisos de **Automatización del Finder** bajo Hardened Runtime para que pulsar **Continuar** muestre el diálogo de macOS o abra Ajustes del Sistema, repara varias funciones rotas en **Ajustes** (Finder, Mission Control, botones de ventana y listas de apps), elimina los tirones en las transiciones y al volver a **Optimizar**, y corrige las cifras de tamaño durante el escaneo.

### Permisos y ajustes
- Añade el entitlement `com.apple.security.automation.apple-events` a la app y lo conserva al volver a firmar tras Sparkle en las compilaciones de publicación, corrigiendo que pulsar **Continuar** en la hoja de **Automatización del Finder** no hiciera nada y desbloqueando el atajo **Nuevo archivo en el Finder**.
- Mejora el flujo de solicitud de Automatización del Finder: inicia el Finder en segundo plano si no está abierto, abre **Privacidad y seguridad → Automatización** si ya se denegó antes o si macOS no muestra la alerta, y respeta la elección cuando pulsas **No permitir**.
- Corrige **Nuevo archivo** al hacer clic secundario sobre un archivo en el Finder para crear el archivo en la carpeta que muestra la ventana en lugar de fallar con la ruta del archivo seleccionado.
- Registra el manejador de URLs del menú del Finder durante el arranque y encola las peticiones hasta que arranca el motor de ajustes, evitando que se pierda el primer clic cuando el menú del Finder lanza MacHelper.
- Corrige que los botones superpuestos de **Mission Control** ignoraran el primer clic mientras MacHelper no está activa, y amplía de `30 pt` a `56 pt` la franja superior de detección de los botones semáforo para ventanas con barras de herramientas más altas.
- Corrige los campos de lista de apps excluidas en **Ajustes** que borraban las comas en cada pulsación, guardando ahora al terminar la edición y compartiendo el análisis con la CLI.
- Añade botones directos de **Permitir control del Finder** y **Activar extensión del Finder** junto a los ajustes que los requieren, y actualiza el estado de Automatización del Finder cada vez que MacHelper pasa a primer plano.

### Interfaz y escaneo
- Cambia las transiciones de estado a pantalla completa en **Optimizar**, **Análisis del disco** y **Desinstalar** para retirar de inmediato el estado anterior sin escalado fraccionario, eliminando los tirones y el parpadeo de texto al volver al inicio de **Optimizar** o cambiar de estado.
- Calcula el ancho del contenido durante el propio pase de diseño en lugar de una actualización después, eliminando el salto de ancho al cambiar de página en la barra lateral, y retira una animación duplicada al restaurar escaneos en **Análisis del disco**.
- Sustituye `"Zero KB"` y los formatos inconsistentes por un formateador unificado que muestra `"0 bytes"`, acota valores negativos o fuera de rango, sigue el separador decimal del sistema y gestiona con seguridad tasas no finitas.
- Corrige que los reescaneos de **Análisis del disco** mantuvieran los totales anteriores o saltaran hacia atrás por sondeos solapados, manteniendo un único sondeo por escaneo y contadores estrictamente crecientes.
- Corrige que **Desinstalar** mostrara brevemente los restos y el tamaño seleccionado de la app anterior al cambiar de selección, y evita que cargas atrasadas dejen el indicador de progreso girando indefinidamente.
