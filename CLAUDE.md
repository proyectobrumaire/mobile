# Brumaire — app móvil (mobile)

Estación Brumaire: condensador atmosférico que alimenta un bebedero para aves y fotografía a las aves. Un solo sistema en 3 repos:

- **microprocessors**: firmware Arduino Mega + ESP32-CAM (protocolo y formato del log en su `PROTOCOL.md`).
- **mobile** (este): app Flutter que hace de puente entre el ESP32 y la nube.
- **bird-classification**: AWS (Terraform) — presigner, clasificación y galería.

Código, comentarios y commits en español.

## Flujo

1. **"Descargar SD"** (pantalla principal → diálogo con "Descarga continua", recordada en SharedPreferences; `Esp32SyncService`, teléfono en la misma red que el ESP32, `esp32cam.local`): sincroniza la hora (`/set_time`); **primero** descarga `log.txt` directo (no depende de `/list`; 404 = sin log), lo parsea (`LogParser`, formatos V1 y V2), guarda en SQLite solo las líneas con `seq` mayor al high-water mark (tabla `meta`, clave `max_seq_importado`; no depende de las filas porque se borran tras subir) y hace `/reset_log`; si el log falla, las fotos se descargan igual y el log se reintenta la próxima vez. Después lista (`/list`, máx. 20 archivos + `truncated`), descarga y borra cada foto (guardado atómico `.part` → rename). En modo continuo repite listar→descargar mientras `truncated` sea `true`; se detiene si un lote no saca ninguna foto de la SD (anti-bucle) y no reintenta en la misma corrida una foto que ya falló. Cancelación cooperativa entre fotos: si se cancela durante las fotos el log ya quedó procesado; si se cancela antes de empezar no se procesa el log ni se hace `/reset_log`.
2. **"Subir al servidor"** (Galería → pestaña Local; `BackendSyncService`): pide URLs firmadas al presigner (`x-api-key`) y hace PUT directo a S3 (`images/raw/...`, `logs/app/...` como JSON). Cada foto subida se borra del teléfono (archivo y fila). Las lecturas subidas se borran también, salvo las del mismo timestamp que una foto que sigue en el teléfono (`purgeUploadedLogEntries`).
- Sensores: etiquetas en `sensorLabels`, orden en `sensorOrder` y formato con unidades en `formatSensorValue` (`lib/models/log_entry.dart`). `L1_K` (Lluvia) es booleano: se muestra "Sí"/"No" (≥ 0.5 = Sí) con ícono de gota.
- Progreso: los servicios emiten `SyncProgress` estructurado (paso, estado, progreso del lote, contador acumulado, incidencias, resumen); `SyncRunController.instance` ejecuta una sincronización a la vez y la UI la dibuja con `SyncProgressView`. Mensajes de error en lenguaje simple en `ErrorMessages`, con el detalle técnico expandible.
- Galería (`GalleryScreen`, pestañas): **Local** = fotos del teléfono (pendientes de subir) por día y evento, visor con zoom/deslizar y sensores con unidades, borrado manual (foto, evento o selección múltiple con confirmación). **Cloud** = fuentes `CloudGallerySource` registradas en `cloudGallerySources()` (la primera es la de por defecto): "Todas" (`POST /photos`, por día; muestra `image_url` o, si falta, `raw_url`, más detecciones y sensores) y "Aves" (`POST /gallery`, por especie).
- Eventos (`EventsScreen`, ícono de línea de tiempo en la pantalla principal): línea de tiempo por día con filtro por tipo (chips) y detalle con sensores. **Local** = líneas `type=event` pendientes de subir (`pendingEventEntries`), incluido BIRD ("Ave detectada"), con las lecturas del mismo timestamp; tocar un BIRD abre el visor de la galería local con las fotos `image_<mismo ts>_0/1/2` (`photosForEvent`, timestamp exacto) o avisa si ya no están en el teléfono; **Cloud** = `POST /events` pidiendo `types` explícitos (sin BIRD, para no gastar el límite de 500; "Otros" = `INVALID_EV`). Las líneas de evento se suben con el resto del log y luego se purgan del teléfono.
- ESP32 (contrato `~/Brumaire/.claude/contracts/esp32-http.md`): `Esp32Service.checkStatus()` clasifica GET /list en `Esp32Status` (conectado / `sdNoResponde` = 500 "Failed to open Dir" / `sdOcupada` = 500 "SD Busy", transitorio / `modoAp` = 403 / `noEncontrado`); los no-200 se lanzan como `Esp32HttpException` (código + cuerpo). El banner de la pantalla principal muestra en rojo "ESP32 conectado, pero la tarjeta SD no responde" y reintenta "SD Busy" sin alarmar. "Descargar SD" con la SD caída falla con mensaje claro y no procesa el log; /list se reintenta ante "SD Busy". Botón "Reiniciar ESP32" (↻ en el AppBar; no disponible durante una sincronización): `POST /reboot` (200 o conexión cerrada = éxito), luego `rebootAndWait` consulta cada 2 s hasta 30 s. `Esp32Service` acepta un `http.Client` para tests.
- API de consulta de la nube: contrato en `~/Brumaire/.claude/contracts/api-fotos-eventos.md` (no cambiarlo desde aquí). Cliente en `CloudGalleryService` (`fetch`, `fetchPhotos`, `fetchEvents`; acepta un `http.Client` para tests). Respuestas con `truncated` muestran un aviso (máx. 500 elementos).

## Configuración

- URL y secret del presigner: se leen solo a través de `PresignerConfig` (`lib/services/presigner_config.dart`). Prioridad por campo: lo guardado en SharedPreferences (`presigner_url` / `presigner_secret`, si no está vacío) y, si no, el valor compilado en el APK (`String.fromEnvironment('PRESIGNER_URL')` / `('PRESIGNER_SECRET')`, vacíos por defecto). Sin ninguno de los dos, la app pide configurarlo.
- Los valores compilados los pasa `scripts/build_apk.sh` con `--dart-define` (a cargo del orquestador); se obtienen con `terraform output presigner_url` / `terraform output -raw presigner_secret` en `bird-classification/terraform`. **Nunca escribirlos en el repo ni commitearlos.** Un `flutter build apk` sin ese script produce un APK sin configuración incluida.
- Diálogo "Configuración S3" (ícono "Presigner S3"): indica si se usa la configuración incluida en la app, no muestra el secret compilado (ni siquiera con "mostrar": solo prellena lo guardado) y "Restablecer" borra lo guardado para volver a la incluida.

## Compilar

- Flutter stable 3.47+ (Dart ^3.11.5). `flutter analyze`, `flutter test`, `flutter build apk --release`.
- Gradle 8.14 no soporta Java 25 (el JBR de Android Studio): usar JDK 21 (`flutter config --jdk-dir=<jdk21>`).
- Un APK compilado en otra máquina tiene otra firma: instalar encima falla y hay que desinstalar, lo que **borra los datos locales** (fotos/log pendientes y config). Subir pendientes antes de reinstalar.

## Pendientes conocidos

- No se conoce el total de archivos de la SD (el firmware no lo reporta; decisión del usuario): la barra de progreso es por lote y el total es un contador.
- ESP32: queda una ventana entre descargar `log.txt` y `/reset_log` en la que una línea nueva escrita por el Arduino se borraría sin haberse descargado (pendiente del firmware: p. ej. rotar el archivo o un reset hasta un `seq`).
- `POST /photos` y `POST /events` se probaron solo con respuestas simuladas hasta que la nube los despliegue (un 404 se muestra como "falta desplegar la nube").
