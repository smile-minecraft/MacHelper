MacHelper se mueve con más fluidez: las páginas y sus estados aparecen con un fundido en lugar de cambiar de golpe, y en macOS 26 los controles que flotan sobre el contenido usan Liquid Glass. Cada sección del panel de la barra de menús va en su propia tarjeta de cristal, la página Batería tiene un diseño nuevo y, con la página CPU abierta, el panel usa una quinta parte de la CPU que usaba antes. Los ajustes explican el Helper con palabras claras y compilar desde el código empieza con `make setup`.

### Interfaz
- Al cambiar de página, y al pasar entre los estados de una página (inicio, análisis, resultados), el contenido nuevo aparece con un fundido en lugar de cambiar de golpe. El resaltado de pestañas y filtros se desliza hasta la nueva opción, y el panel de la barra de menús se abre y se cierra con un fundido. Con «Reducir movimiento» no se mueve nada; solo quedan los fundidos.
- En macOS 26 y posteriores, el estilo suave usa Liquid Glass en los controles que flotan sobre el contenido: las barras de acciones bajo las listas, el resaltado de las pestañas, los botones de la cabecera y el botón principal. En el panel de la barra de menús, cada sección (indicadores, historial, núcleos, detalles, procesos) va en su propia tarjeta de cristal. El estilo píxel y los sistemas anteriores conservan su aspecto.
- La página Batería de la barra de menús tiene un diseño nuevo: una batería dibujada con la carga en letra grande y el estado de la alimentación, recuadros para salud, ciclos, temperatura y potencia, el historial de carga y filas de accesorios con su propio icono; los AirPods muestran por separado el auricular izquierdo, el derecho y el estuche.

### Rendimiento
- Los indicadores del panel de la barra de menús ya no se animan entre lecturas que llegan cada segundo. Con la página CPU o GPU abierta, MacHelper usaba cerca del 40 % de un núcleo y ahora usa cerca del 8 %; la página Memoria bajó de cerca del 23 % al 8 % (compilación Release, media de 30 segundos).
- El estado del Helper se consulta a macOS como mucho una vez por segundo, no en cada redibujado.

### Ajustes
- La pestaña Helper explica para qué sirve el Helper, muestra su estado con palabras claras y ofrece solo el siguiente paso (configurarlo, abrir Ítems de inicio o desactivarlo). Las herramientas para desarrolladores pasan a Diagnóstico.
- En Alertas, cada condición tiene su interruptor en una fila y su umbral en la fila de abajo.
- En General, Buscar actualizaciones está junto a la versión, y las explicaciones del registro en segundo plano y la gestión de datos son más cortas.
- La página Ventiladores muestra el estado del Helper en el idioma de la interfaz.

### Compilación
- `make setup`, `make open`, `make run` y `make test` cubren el trabajo diario sin tocar la app instalada; solo `make install` la sustituye. Compilar requiere Xcode 26 o posterior.
- En un Mac sin batería, `make run ARGS=--demo-battery` muestra la página Batería con lecturas simuladas (solo en compilaciones Debug; no se guarda nada en el historial).
