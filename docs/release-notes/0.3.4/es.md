La pestaña SSD de la barra de menús permite cambiar entre discos locales, la página Red muestra solo las interfaces principales del sistema y los túneles activos, y Homebrew enseña la primera lista sin esperar a que se actualice el índice.

### Almacenamiento
- La pestaña SSD tiene un menú de discos: el disco del sistema, su volumen de datos y cualquier otro volumen local montado en /Volumes. Cada disco muestra su propia capacidad y su propia gráfica de espacio libre de los últimos siete días. Si un disco se desconecta o no se puede identificar, la página lo dice en lugar de cambiar en silencio a otro.
- Cada disco con una identidad estable recibe un punto de espacio libre por hora. Las horas que faltan quedan como huecos: la gráfica no rellena con ceros ni une dos tramos separados. Cuando un disco comparte el espacio libre con otros volúmenes APFS del mismo contenedor, lo indica; las velocidades de lectura y escritura de debajo de la gráfica se etiquetan como el total de todos los discos del Mac.
- La grabación en segundo plano sigue el ajuste «Seguir registrando después de cerrar MacHelper»: si está activado, los puntos por hora continúan con MacHelper cerrado; si está desactivado, se detienen al cerrarlo.
- El aviso de borrado del historial de monitorización ahora nombra también el historial de espacio libre de cada disco, y la página SSD retira su gráfica antigua en cuanto el borrado termina.

### Red
- Las velocidades de descarga y subida en directo vuelven a mostrarse. El lector de la lista de interfaces se detenía en los registros de direcciones que macOS intercala entre las interfaces; ahora los salta y sigue leyendo el resto, y las nuevas tarjetas de interfaz también reciben su velocidad de enlace.
- La página Red de la barra de menús es compacta: solo lista las interfaces principales del sistema y los túneles que están activos y en funcionamiento. Cada tarjeta muestra el nombre, el estado, una dirección IPv4 y la velocidad de enlace; las direcciones IPv6 y el MTU no aparecen en las tarjetas.
- Una nota bajo las tarjetas aclara que una interfaz principal no demuestra acceso a internet; cuando se muestra un túnel, otra nota indica que no es necesariamente una VPN. Las velocidades de arriba se etiquetan «Todas las interfaces · bytes por segundo», separadas de la velocidad de enlace de cada tarjeta.

### Monitor
- Volver de 7 días a «En directo» ya no congela la ventana; con una semana de datos por minuto podía bloquearse unos 35 segundos. Las gráficas principales en directo se dibujan al instante desde la memoria, y un rango histórico conserva la gráfica anterior hasta que termina su propia consulta, así que una respuesta tardía no reemplaza a un rango más nuevo.
- 24 horas y 7 días se promedian en intervalos de 5 y 30 minutos, así que una semana de un solo sensor dibuja unos 320 puntos en lugar de unas 9.500 muestras. Un hueco sigue siendo un hueco, y un rango con un solo intervalo muestra un punto visible en vez de una gráfica vacía.

### Homebrew
- La página muestra primero la lista del índice existente de Homebrew y lee los detalles de las apps en segundo plano. Cuando el índice es más antiguo que la ventana de 24 horas de Homebrew, lo actualiza después de esa primera lista y la sustituye al terminar.
- «Comprobar de nuevo» ejecuta antes brew update y mantiene la lista anterior en pantalla mientras trabaja. Las filas se marcan como no confirmadas y no se pueden actualizar desde la app hasta que se hayan vuelto a leer sus detalles.
- La hora de actualización del índice y la antigüedad de la lista se muestran por separado: una lista leída de un índice antiguo no se presenta como reciente, y «todo está al día» solo se afirma cuando esta comprobación ha actualizado el índice correctamente y no ha habido avisos.

### Optimizar
- La pantalla de inicio de Optimizar incluye una tarjeta de Limpieza automática con su estado y lo que hace la programación. Solo abre los ajustes de programación existentes; nunca activa la programación ni inicia una limpieza por su cuenta.

### Idiomas
- Los textos nuevos y modificados están traducidos a los seis idiomas.
