Las páginas muestran primero el último resultado, los perfiles de ventilador son curvas escalonadas y Homebrew ya no ofrece MacHelper.

### Velocidad
- La comprobación de salud muestra su informe anterior al instante y se actualiza en segundo plano. La primera carga baja de unos 718 ms a 60 ms; cambiar entre 1 hora, 24 horas y 7 días tarda 1–2 ms a partir de la segunda vez.
- Análisis de disco vuelve a una ubicación ya abierta en unos 0,2 ms en lugar de 818 ms; Desinstalar reaparece con su lista en 114 ms en lugar de 683 ms, y Elementos de inicio tarda 27 ms en lugar de 199 ms.
- Las cachés tienen límites: informes de salud (3 períodos, 60 s), seguridad (5 min), árboles de disco (2, uno al salir de la página), volúmenes (8, 60 s), listas de apps (2 min), elementos de inicio (1 min) e historial de sensores y procesos (6 y 4 selecciones, 1 min).
- La memoria se mantiene en el mismo nivel tras el arranque y tras visitar seis páginas; la página de disco usa unos 245 MB en el mismo punto donde antes usaba 654 MB.

### Ventiladores
- Quiet, Balanced y Performance son curvas escalonadas: los ventiladores mantienen una velocidad durante unos grados y luego suben. Quiet nunca supera a Balanced, que nunca supera a Performance.
- Las curvas personalizadas existentes no se tocan; un perfil antiguo se muestra como Personalizado hasta que vuelvas a elegir un perfil.
- El cambio automático reintenta tras un fallo temporal del Helper o cuando el Helper vuelve a estar disponible.

### Homebrew
- MacHelper ya no aparece en su propia lista de actualizaciones de Homebrew, ni siquiera con «Incluir apps que se actualizan solas». La comprobación reconoce el cask que instaló la app en ejecución, así que una versión antigua del cask no puede ofrecer una degradación.
- Al volver a abrir la página se muestra la lista anterior al instante y se actualiza en segundo plano.

### Interfaz y correcciones
- La barra de filtros de Optimizar pasa a dos filas en una ventana estrecha; la hoja Never Clean crece con su contenido; los totales se alinean a la derecha; una selección vacía ya no dice «0 maintenance tasks».
- Los valores de velocidad del ventilador ya no se cortan con texto grande; los mensajes de error completos están disponibles al pasar el cursor o seleccionar el texto; los ventiladores no compatibles ya no muestran una cadena interna de estrategia.
- Las casillas y los botones de icono tienen etiquetas de VoiceOver; la nota de CPU de la página de salud se queda bajo la lista de CPU y sus columnas ya no se cortan con texto grande.
- El texto nuevo está traducido al chino tradicional.
