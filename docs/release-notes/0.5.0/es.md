MacHelper incorpora **Optimización profunda** con autorización de administrador para carpetas del sistema, añade interruptores independientes por herramienta en **Ajustes → Funciones**, estrena el estilo **Neumórfico** (`Suave`) y el tema **Arcilla suave**, y suaviza las transiciones en Ajustes manteniendo bajo el uso de CPU en la barra de menús.

### Optimización profunda
- Añade **Optimización profunda…** debajo de **Iniciar escaneo** en **Optimizar** para analizar y limpiar cachés del sistema, registros rotados o comprimidos, informes de diagnóstico, cachés de simuladores y archivos temporales de más de una semana que requieren privilegios de root.
- Todas las rutas y reglas de coincidencia están fijadas en el Helper (la app solo envía los identificadores). Escanear y previsualizar nunca piden contraseña, mientras que al eliminar se solicita contraseña de administrador o Touch ID cada vez; los elementos de riesgo medio vienen desmarcados por defecto.
- Omite enlaces simbólicos, enlaces duros, cachés del sistema propias de Apple y elementos con marcas de protección, inmutabilidad, solo anexión, bóveda de datos o SIP; nunca toca instantáneas de APFS o Time Machine, archivos protegidos por SIP ni el registro unificado.
- Requiere el Helper actualizado (protocolo v7); si falta o está desactualizado, **Optimización profunda…** permanece desactivado y muestra el enlace **Configurar o reparar el Helper…**.

### Módulos de funciones
- Añade la pestaña **Ajustes → Funciones** con un interruptor para cada una de las ocho herramientas (**Monitor**, **Revisión de estado**, **Ventiladores**, **Optimizar**, **Análisis del disco**, **Desinstalar**, **Actualizaciones de Homebrew** e **Ítems de arranque**). **Resumen** sigue visible siempre y todos los módulos vienen activados por defecto, de modo que nada cambia tras actualizar.
- Al desactivar una herramienta desaparece de la barra lateral, de los atajos de menú `⌘1`–`⌘9` (el resto conserva su numeración), de la barra rápida de la barra de menús y de los accesos en **Resumen**; si la página estaba abierta, vuelve a **Resumen**.
- Pausa el trabajo en segundo plano sin borrar los ajustes guardados: **Monitor** cancela el agente de registro en segundo plano, **Optimizar** pausa la limpieza programada, **Ventiladores** detiene el sondeo y devuelve los ventiladores al control automático del sistema, y **Actualizaciones de Homebrew** detiene la comprobación de actualizaciones. Al reactivar **Monitor** u **Optimizar** se recuperan sus programaciones guardadas; **Ventiladores** permanece en modo automático hasta que vuelvas a cambiarlo.
- Pide confirmación antes de desactivar **Ventiladores** (si hay una política manual o reglas activas) u **Optimizar** (si la limpieza programada está activada). El modo sencillo sigue funcionando junto con estos interruptores, las copias de seguridad de ajustes los incluyen (y siguen importando copias anteriores) y las acciones de **Atajos** para **Optimizar** y **Revisión de estado** informan cuando la función está desactivada.

### Tema Neumórfico
- Añade la forma **Suave**, el tema integrado claro y oscuro **Arcilla suave** (`builtin.soft`) y el ajuste preestablecido **Neumórfico** en **Ajustes → Apariencia**.
- Las tarjetas y controles se elevan sobre el fondo, las pistas y huecos se hunden en él y los botones pasan de elevados a hundidos al pulsarlos con una iluminación sutil desde arriba a la izquierda; con la forma **Suave**, el **Material** se fija en **Sólido** para mantener nítidas las luces y sombras.

### Movimiento y animaciones
- Corrige los cortes bruscos de un solo fotograma en las notas y filas condicionales de **Ajustes** manteniendo una identidad de vista estable con fundido cruzado y transiciones compartidas; con **Reducir movimiento** activado, se limita a un fundido simple.
- Revisa todos los puntos de animación de la app para asegurar el respeto a **Reducir movimiento** y elimina las transiciones numéricas por segundo en las lecturas del panel de la barra de menús para evitar carga adicional de CPU.
