#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"   # скрипт лежит в корне репо

# =============================================================================
# Mac App Store build + sign + package для Murmur.
#
# Сертификаты и Team ID НЕ хардкодятся — скрипт сам находит их в Keychain
# (`security find-identity`). Так не бывает рассинхрона с реальными именами
# сертификатов (они должны совпадать посимвольно, иначе codesign падает с
# "no identity found"). Если чего-то нет — скрипт падает РАНО с понятным
# объяснением что именно создать, а не с криптической ошибкой codesign на
# середине.
#
# Предусловия (создаются один раз в developer-портале Apple):
#   1. Сертификаты "3rd Party Mac Developer Application" + "...Installer"
#      установлены в Keychain (Xcode → Settings → Accounts → Manage
#      Certificates, или импорт .cer из developer.apple.com).
#   2. App ID com.deagle.murmur зарегистрирован.
#   3. Mac App Distribution provisioning profile сгенерирован, скачан и
#      положен по пути $PROVISION_PROFILE (см. ниже).
# =============================================================================

BUNDLE_ID="com.deagle.murmur"
ENTITLEMENTS="Murmur.entitlements"
APP="Murmur.app"
PKG="Murmur.pkg"
SHORT_VERSION="3.25"
BUILD_VERSION="3.25.0"

# Профиль можно переопределить переменной окружения:
#   PROVISION_PROFILE=/path/to/profile.provisionprofile ./build-mas.sh
# Расширение .provisionprofile (для Mac), НЕ .mobileprovision (для iOS).
PROVISION_PROFILE="${PROVISION_PROFILE:-$HOME/Library/MobileDevice/Provisioning Profiles/Murmur_MAS.provisionprofile}"

die() { echo "ERROR: $*" >&2; exit 1; }

# === 0. Предполётная проверка окружения =====================================
echo "==> Preflight checks"

# 0a. Находим сертификаты MAS-дистрибуции в Keychain по их каноническому
#     префиксу. Берём ПЕРВУЮ найденную identity целиком (вместе с Team ID в
#     скобках), чтобы имя совпадало с Keychain посимвольно.
APP_CERT="$(security find-identity -v -p codesigning \
    | grep -o '"3rd Party Mac Developer Application: [^"]*"' \
    | head -n1 | sed 's/^"//; s/"$//' || true)"

# Installer-сертификат codesign/productbuild ищет в basic-keychain, не в
# codesigning-policy, поэтому отдельный вызов без -p codesigning.
INSTALLER_CERT="$(security find-identity -v \
    | grep -o '"3rd Party Mac Developer Installer: [^"]*"' \
    | head -n1 | sed 's/^"//; s/"$//' || true)"

if [ -z "$APP_CERT" ]; then
    die "не найден сертификат '3rd Party Mac Developer Application' в Keychain.
       Создай его: developer.apple.com → Certificates → '+' → 'Mac App Distribution',
       либо Xcode → Settings → Accounts → Manage Certificates → '+'.
       Затем проверь: security find-identity -v -p codesigning"
fi
if [ -z "$INSTALLER_CERT" ]; then
    die "не найден сертификат '3rd Party Mac Developer Installer' в Keychain.
       Создай его: developer.apple.com → Certificates → '+' → 'Mac Installer Distribution'.
       Затем проверь: security find-identity -v | grep Installer"
fi
echo "    App cert:       $APP_CERT"
echo "    Installer cert: $INSTALLER_CERT"

# 0b. Provisioning profile должен существовать ДО сборки — иначе cp на шаге 3
#     упал бы под set -e уже после долгой сборки.
[ -f "$PROVISION_PROFILE" ] || die "provisioning profile не найден:
       $PROVISION_PROFILE
       Сгенерируй Mac App Distribution profile в App Store Connect / Xcode
       (Signing & Capabilities → Mac App Store distribution) для App ID
       $BUNDLE_ID, скачай и положи по этому пути.
       Или укажи свой: PROVISION_PROFILE=/path/to.provisionprofile ./build-mas.sh"
echo "    Profile:        $PROVISION_PROFILE"

# 0c. Нужные исходные файлы на месте.
[ -f "$ENTITLEMENTS" ]                || die "нет $ENTITLEMENTS"
[ -f "Info.plist" ]                   || die "нет Info.plist"
[ -f "Assets/AppIcon.icns" ]          || die "нет Assets/AppIcon.icns"
[ -f "Resources/PrivacyInfo.xcprivacy" ] || die "нет Resources/PrivacyInfo.xcprivacy"

# 0d. Bundle ID в Info.plist должен совпадать с $BUNDLE_ID (иначе профиль и
#     App ID не совпадут с подписью → reject).
PLIST_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Info.plist 2>/dev/null || true)"
[ "$PLIST_ID" = "$BUNDLE_ID" ] || die "CFBundleIdentifier в Info.plist ('$PLIST_ID')
       не совпадает с BUNDLE_ID ('$BUNDLE_ID'). Подпись/профиль не сойдутся."

# === 1. Сборка ===============================================================
echo "==> Build (release)"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    swift build -c release -Xswiftc -O

# === 2. Bundle assembly ======================================================
echo "==> Assemble bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Murmur     "$APP/Contents/MacOS/"
cp Info.plist                "$APP/Contents/"
cp Assets/AppIcon.icns       "$APP/Contents/Resources/"
cp Resources/PrivacyInfo.xcprivacy "$APP/Contents/Resources/"
# License + third-party attribution (whisper.cpp / ggml are MIT — their
# notices must ship with the binary that statically links them).
cp LICENSE                   "$APP/Contents/Resources/"
cp THIRD-PARTY-LICENSES.md   "$APP/Contents/Resources/"

# Glow shader (v3.23): compile GlowField.metal → default.metallib BEFORE the
# bundle is signed in step 4, so the metallib is covered by the signature
# (codesign --sign on the bundle seals Contents/Resources). `swift build`
# never invokes the Metal compiler, so this explicit step is the ONLY way
# the App Store build ships the shader — without it MAS users would silently
# get the FlowingGradient fallback. Unlike build-app.sh we fail HARD here:
# a store build must not quietly ship the degraded visual.
echo "==> Compile glow shader -> default.metallib"
METAL_SRC="Sources/Murmur/Shaders/GlowField.metal"
METALLIB_OUT="$APP/Contents/Resources/default.metallib"
xcrun -sdk macosx metal -std=metal3.0 -c "$METAL_SRC" -o /tmp/glowfield.air \
    || die "metal compile failed for $METAL_SRC"
xcrun -sdk macosx metallib /tmp/glowfield.air -o "$METALLIB_OUT" \
    || die "metallib link failed"
echo "    metallib OK ($(du -h "$METALLIB_OUT" | cut -f1))"

# === 3. Embed provisioning profile ==========================================
echo "==> Embed provisioning profile"
cp "$PROVISION_PROFILE" "$APP/Contents/embedded.provisionprofile"

# === 4. Code signing с entitlements + hardened runtime =======================
# Подписываем изнутри наружу: сначала исполняемый бинарь, затем бандл.
# Статические .a линкуются в бинарь (нет вложенных dylib/framework), поэтому
# отдельных вложенных артефактов для подписи нет — --deep не нужен (и
# депрекейтнут Apple).
echo "==> Sign"
codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$APP_CERT" \
    "$APP/Contents/MacOS/Murmur"

codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$APP_CERT" \
    "$APP"

# === 5. Проверка =============================================================
echo "==> Verify signature"
codesign --verify --deep --strict --verbose=4 "$APP"
codesign -d --entitlements - "$APP"
plutil -lint "$APP/Contents/Resources/PrivacyInfo.xcprivacy"

# === 6. productbuild → .pkg ==================================================
echo "==> Build installer package"
productbuild --component "$APP" /Applications \
    --sign "$INSTALLER_CERT" \
    "$PKG"

echo "==> Validate package"
pkgutil --check-signature "$PKG"

echo "==> Готово: $PKG"
echo "Загрузить: Transporter.app (drag $PKG) или"
echo "  xcrun altool --upload-package $PKG --type osx \\"
echo "    --apple-id <APPLE_ID> --bundle-id $BUNDLE_ID \\"
echo "    --bundle-version $BUILD_VERSION --bundle-short-version-string $SHORT_VERSION \\"
echo "    --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>"
