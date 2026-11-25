MacHelper añade compatibilidad universal para Macs con Intel (`x86_64`) además de Apple Silicon, pule el tema **Suave** (neomórfico) y la navegación de **Optimizar** con animaciones más fluidas, corrige las potencias recomendadas de adaptador intercambiadas en **Cable** para los M1 Pro y M1 Max, y detecta los permisos de Accesibilidad concedidos mientras la app está abierta.

### Soporte universal para Mac
- MacHelper ahora se compila como app universal nativa tanto en Macs con Intel (`x86_64`) como con Apple Silicon en macOS 14 o posterior, y el cask de Homebrew ya no exige `arm64`.
- En Macs Intel, las lecturas de temperatura y el control de ventiladores usan SMC y el consumo total del sistema se lee desde SMC (el desglose de energía exclusivo de Apple Silicon no está disponible). `machelper status` y `machelper report` incluyen temperaturas SMC, los equipos con doble GPU muestran la GPU activa con más carga, el control de ventiladores aplica límites de seguridad más conservadores (95 °C / 88 °C) y **Cable** incorpora las potencias recomendadas de adaptador para modelos MacBook Pro y MacBook Air con Intel.
- La compatibilidad con Intel aún no se ha probado en un Mac Intel físico; si encuentras problemas propios del hardware en Intel, por favor repórtalos.

### Interfaz y Optimizar
- En el tema **Suave** (neomórfico), se añadió margen superior en el panel de la barra de menús para que el brillo superior izquierdo de la primera tarjeta no quede recortado bajo la barra de pestañas, se suavizaron los brillos y sombras en modo oscuro y se amplió la separación entre las tarjetas estrechas de ventiladores y energía.
- En la pantalla inicial de **Optimizar**, **Iniciar escaneo** y **Optimización profunda…** ahora aparecen lado a lado con la misma altura; un nuevo botón **Volver al menú** en la barra de herramientas de **Optimizar** y en las barras de vista previa y resultados permite cambiar entre la optimización estándar y la profunda sin tener que volver a escanear antes.
- Los análisis arrancan más rápido y la animación de escaneo se mantiene fluida durante las actualizaciones de progreso al sacar las comprobaciones previas del hilo principal y ejecutar la vista previa de limpieza del sistema en paralelo con el análisis de reglas.

### Cable
- Corrige las potencias de adaptador recomendadas que estaban intercambiadas entre los MacBook Pro M1 Pro y M1 Max de 14 y 16 pulgadas (ahora 140 W para el de 16 pulgadas y 67 W para el de 14), de modo que los adaptadores de serie de 67 W ya no muestran avisos falsos de potencia insuficiente.

### Ajustes
- Ahora se detecta si concedes el permiso de Accesibilidad con MacHelper abierto comprobándolo tras la notificación del sistema, al activar la app y cada 10 segundos. Cuando macOS requiere reiniciar para aplicar el permiso, **Ajustes** muestra **Reinicio necesario** junto al botón **Reiniciar MacHelper**, y `machelper tweaks status` informa `accessibilityRestartRequired`.
- En macOS 27 y posteriores, el botón de permiso y los mensajes de la CLI muestran el nuevo nombre de la lista en Ajustes del Sistema (**Control de dispositivos y acceso a datos**) en lugar de **Accesibilidad**.
- Los reinicios tras cambiar **Idioma** o usar **Importar ajustes** ahora esperan a que MacHelper se cierre antes de volver a abrirse.
