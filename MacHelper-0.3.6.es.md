La página de Batería de la barra de menús muestra ahora la carga de los accesorios conectados junto a la batería interna, y las páginas del panel se pueden reordenar y ocultar. El análisis de disco combina filtros en su lista de archivos más grandes, explica cómo se relaciona el total del análisis con el espacio usado del volumen y enumera las instantáneas locales. La página SSD muestra qué apps leen y escriben el disco, y Limpiar añade reglas para Claude Code, Codex y OpenCode. Limpieza automática puede ejecutarse cada 30 minutos y limpiar archivos temporales caducados.

### Batería
- Los accesorios conectados aparecen bajo la batería interna: dispositivos Bluetooth (Magic Keyboard, ratón, trackpad, AirPods…), dispositivos que informan su carga por USB y dispositivos Logitech conectados mediante su receptor inalámbrico. Cada fila muestra la carga con una barra y una marca de carga; los AirPods añaden el auricular izquierdo, el derecho y el estuche; el accesorio con menos carga va primero.
- Los dispositivos con cable y de receptor se consultan en segundo plano con los protocolos de batería que ya admiten: no se empareja nada, no se instala nada y no se intercepta ninguna entrada.

### Barra de menús
- Ajustes → Barra de menús enumera cada página del panel con su interruptor y botones para subir y bajar: tú decides qué páginas aparecen y en qué orden. La última página visible no se puede apagar, y las páginas sin su hardware permanecen ocultas automáticamente.

### Análisis del disco
- La lista de archivos más grandes combina filtros: una búsqueda sobre el nombre o la ruta completa, un tamaño mínimo, un tipo (vídeo, imagen, audio, archivo comprimido, imagen de disco, aplicación, documento, desarrollo, otros) y una antigüedad como «sin cambios 90 días». Deben cumplirse todas las condiciones activas; «Borrar filtros» devuelve la lista completa.
- Tras analizar el volumen entero, el resultado desglosa cuánto del espacio usado pudo medir el análisis, y que el resto son datos del sistema o espacio compartido con otros volúmenes APFS, no espacio que puedas liberar. Si el análisis contó más de lo que informa el volumen, dice que los archivos cambiaron mientras se analizaba; el análisis de una sola carpeta dice que su total no se puede comparar con el del volumen entero.
- Las instantáneas locales de APFS y Time Machine se enumeran con sus fechas. Comparten espacio con el volumen y las gestiona macOS, así que solo se listan: no se inventa un tamaño ni se ofrece eliminarlas.

### SSD
- Una nueva sección «I/O de disco por app» ordena las apps por la lectura y la escritura que el núcleo atribuye a sus procesos, con sus velocidades y su porcentaje; las seis primeras filas van delante y el resto se suma en una. Las cifras son contadores de proceso, no el rendimiento físico del disco, y la sección lo dice. Los procesos que el usuario actual no puede inspeccionar no se muestran como cero: se excluyen y se cuentan en una nota al pie. El muestreo solo ocurre mientras la página SSD está abierta.

### Limpiar
- Nuevas reglas para Claude Code, Codex y OpenCode. Sus archivos de bajo riesgo (cachés, registros con más de una semana y archivos temporales) se limpian por defecto. El historial de sesiones de cada agente (transcripciones de Claude Code, sesiones de Codex, salida de herramientas de OpenCode) solo se ofrece, nunca viene marcado, y pasa a la Papelera tras un mes. Las reglas no tocan el programa del agente, sus plugins instalados, sus ajustes ni sus credenciales. Cada regla se detiene mientras el agente está en ejecución, comprobado de nuevo antes de cada eliminación, y un archivo que cambió tras la vista previa (por una sesión reanudada, por ejemplo) se deja en su sitio.

### Limpieza automática
- Nuevas frecuencias: cada 30 minutos, cada hora y cada 3 horas, junto a diaria y semanal. El agente en segundo plano comprueba ahora cada 30 minutos y solo ejecuta cuando toca según tu frecuencia. Las programaciones existentes migran solas; una migración interrumpida o fallida se reintenta en la siguiente actualización, y un fallo se informa con un botón de reintentar.
- «Limpiar archivos temporales caducados» está apagada por defecto. Al encenderla, las entradas de tu carpeta temporal con al menos 7 días, sin cambios y sin uso se eliminan tras cada limpieza programada, ya sea a la Papelera o de inmediato, según tu ajuste «Mover a la Papelera en lugar de eliminar». Las entradas que gestiona el propio sistema, y todo lo que esté en uso o aún escribiéndose, se saltan.

### Documentación
- Cada README abre ahora con una descripción clara y añade una sección para agentes de IA y unas preguntas frecuentes; el repositorio añade llms.txt y CITATION.cff.

### Idiomas
- El texto nuevo está traducido a los seis idiomas.
