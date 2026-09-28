#!/usr/bin/env bash
# Compila el APK de release con la URL y el secret del presigner incluidos como
# configuración por defecto (--dart-define). Los valores se leen de los outputs de
# Terraform en ../bird-classification/terraform y NUNCA se escriben en el repo.
#
# Uso:
#   scripts/build_apk.sh            # compila
#   scripts/build_apk.sh --install  # compila e instala en el teléfono conectado (adb)
#
# Variables opcionales:
#   AWS_PROFILE  perfil de AWS para leer el estado de Terraform (por defecto: brumaire)
#   TF_DIR       carpeta de Terraform (por defecto: ../bird-classification/terraform)
#   ADB          ruta de adb (por defecto: ~/Android/Sdk/platform-tools/adb)
#
# Ojo: el secret queda dentro del APK. No compartas el .apk; si se filtra, rota el
# secret en Terraform y vuelve a compilar.
set -euo pipefail

cd "$(dirname "$0")/.."
export AWS_PROFILE="${AWS_PROFILE:-brumaire}"
TF_DIR="${TF_DIR:-../bird-classification/terraform}"
ADB="${ADB:-$HOME/Android/Sdk/platform-tools/adb}"
export PATH="$HOME/development/flutter/bin:$PATH"

echo "Leyendo configuración del presigner desde Terraform ($TF_DIR, perfil $AWS_PROFILE)..."
URL="$(terraform -chdir="$TF_DIR" output -raw presigner_url)"
SECRET="$(terraform -chdir="$TF_DIR" output -raw presigner_secret)"
if [[ -z "$URL" || -z "$SECRET" ]]; then
  echo "No se pudo leer presigner_url / presigner_secret de Terraform." >&2
  exit 1
fi

# Archivo temporal (solo lectura del usuario) para no exponer el secret en la línea
# de comandos; se borra al salir pase lo que pase.
DEFINES="$(mktemp)"
chmod 600 "$DEFINES"
trap 'rm -f "$DEFINES"' EXIT
printf '{"PRESIGNER_URL": "%s", "PRESIGNER_SECRET": "%s"}\n' "$URL" "$SECRET" > "$DEFINES"

flutter build apk --release --dart-define-from-file="$DEFINES"

APK=build/app/outputs/flutter-apk/app-release.apk
echo "APK: $APK"

if [[ "${1:-}" == "--install" ]]; then
  "$ADB" install -r "$APK"
fi
