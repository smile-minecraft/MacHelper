MacHelper perfecciona sus superficies y la legibilidad en modo claro y Liquid Glass, unifica las ventanas iniciales en una sola «Guía de bienvenida» y refuerza la fiabilidad del Helper tanto en actualizaciones con Sparkle como manuales mediante DMG. Los agentes de IA suman un informe de diagnóstico anonimizado en una sola llamada (`machelper report`), y se añaden diagnósticos anónimos opcionales (desactivados por defecto) junto con herramientas nativas de perfilado.

### Temas y materiales de superficie
- Unifica **Apariencia** (`Sistema` / `Claro` / `Oscuro`) y **Material** (`Sólido` / `Esmerilado` —nuevo valor predeterminado— / `Liquid Glass`) en **Ajustes → Apariencia**, con respaldo automático de accesibilidad (Reducir transparencia usa Sólido; Liquid Glass cambia a Esmerilado en versiones anteriores de macOS, en estilo Píxel o con Aumentar contraste).
- Corrige la legibilidad de Liquid Glass en modo claro dentro del panel de la barra de menús: las pestañas seleccionadas, el botón Salir, las tarjetas, las etiquetas, los botones de icono, los ejes de las gráficas, los textos tenues (contraste 4,5:1) y el texto sin tinte se mantienen nítidos sobre fondos claros y oscuros sin perder contraste ni mezclar colores de tinta.
- Añade tokens semánticos de contraste en todas las superficies y una red de seguridad de contraste para temas personalizados e importados de VS Code, manteniendo intactos los temas integrados.
- Rediseña **Ajustes → Apariencia** con selectores de Claro/Oscuro/Sistema y Material, notas de respaldo y tarjetas de tema que muestran vista previa clara y oscura, polaridad y el resultado de la auditoría de contraste.

### Guía de bienvenida
- Sustituye las tres hojas independientes del primer inicio (Acceso total al disco, Helper y skill para agentes) por una **Guía de bienvenida** interactiva de 6 pasos que recorre las preferencias, la barra de menús, los permisos opcionales y las skills para agentes de IA.
- Se puede volver a abrir en cualquier momento desde **Ayuda → Guía de bienvenida…**; quienes ya completaron alguno de los pasos anteriores no volverán a verla al actualizar.

### Fiabilidad y recuperación del Helper
- Añade una transición fluida en actualizaciones de Sparkle y detección de actualizaciones manuales por DMG para conservar el estado del Helper tras sustituir la app.
- Reemplaza las comprobaciones limitadas al registro por una monitorización activa real por XPC y recuperación automática no destructiva ante fallos seguros.
- Incorpora un banner claro dentro de la app con botones de un clic para **Reparar el Helper** y **Abrir Ítems de inicio**, un estado preciso en la barra lateral y notificaciones locales sin duplicados cuando el Helper requiere atención.

### CLI para agentes de IA
- Añade `machelper report` (`--json` / `--format markdown`) para generar de una sola vez un informe completo y anonimizado del Mac, censurando automáticamente nombres de usuario, rutas personales, nombres de host, direcciones IP y MAC y nombres de volúmenes externos.
- Incluye `suggestedActions` y `availableTools` estructurados en la salida JSON, incorpora `machelper guide --json` y actualiza la skill integrada para agentes a la v3.

### Privacidad y rendimiento
- Añade estadísticas de uso anónimas opcionales y diagnósticos básicos de rendimiento, **desactivados por defecto** en **Ajustes → General → Privacidad y diagnósticos**, sin datos personales ni rutas de archivos, con vista previa del payload JSON de ejemplo y borrado inmediato del identificador anónimo y la cola pendiente al desactivarlos.
- Añade instrumentación nativa con `OSSignposter` en rutas críticas y el script `scripts/perf/xctrace-profile.sh` para perfilado de rendimiento.

### Documentación y sitio web
- Renueva los README en los seis idiomas, reemplaza las capturas de pantalla con datos sintéticos de demostración mediante `make screenshots` y rediseña la página en GitHub Pages.
