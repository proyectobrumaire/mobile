# Brumaire — app móvil (mobile)

Estación Brumaire: condensador atmosférico que alimenta un bebedero para aves y fotografía a las aves. Un solo sistema en 3 repos:

- **microprocessors**: firmware Arduino Mega + ESP32-CAM (protocolo y formato del log en su `PROTOCOL.md`).
- **mobile** (este): app Flutter que hace de puente entre el ESP32 y la nube.
- **bird-classification**: AWS (Terraform) — presigner, clasificación y galería.

Código, comentarios y commits en español.

## Flujo

1. **"Descargar SD"** (`Esp32SyncService`, teléfono en la misma red que el ESP32, `esp32cam.local`): sincroniza la hora (`/set_time`), lista (`/list`, máx. 20 archivos), descarga y borra cada foto, descarga `log.txt` directo (no depende de `/list`), lo parsea (`LogParser`, formatos V1 y V2), guarda en SQLite solo las líneas con `seq` mayor al máximo guardado y hace `/reset_log`.
2. **"Subir al servidor"** (`BackendSyncService`): pide URLs firmadas al presigner (`x-api-key`) y hace PUT directo a S3 (`images/raw/...`, `logs/app/...` como JSON).
- Galería local: fotos agrupadas por timestamp con los sensores del mismo instante. Galería cloud: `POST /gallery` a la Lambda.
- `sync_service.dart` es el flujo antiguo de un solo paso: código muerto.

## Configuración

- URL y secret del presigner se ingresan en la app (ícono "Presigner S3") y se guardan en SharedPreferences. Se obtienen con `terraform output presigner_url` / `terraform output -raw presigner_secret` en `bird-classification/terraform`. **Nunca commitearlos.**

## Compilar

- Flutter stable 3.47+ (Dart ^3.11.5). `flutter analyze`, `flutter test`, `flutter build apk --release`.
- Gradle 8.14 no soporta Java 25 (el JBR de Android Studio): usar JDK 21 (`flutter config --jdk-dir=<jdk21>`).
- Un APK compilado en otra máquina tiene otra firma: instalar encima falla y hay que desinstalar, lo que **borra los datos locales** (fotos/log pendientes y config). Subir pendientes antes de reinstalar.

## Pendientes conocidos

- "Descargar SD" procesa solo lo que devuelve `/list` (máx. 20); no repite mientras `truncated` sea `true`.
- Las fotos no se borran del teléfono tras subirlas (solo se marcan `uploaded = 1`).
- Los eventos sin foto (PERIODIC, PELTIER, VOLCADO) no se muestran en ninguna pantalla.
