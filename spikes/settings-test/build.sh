#!/bin/sh
# Builds the settings spike APK without Gradle: aapt2 -> javac -> d8 -> zipalign -> apksigner.
# Output: build/settings-spike.apk
set -eu
cd "$(dirname "$0")"

SDK=${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}
JAVA_HOME=${JAVA_HOME_21:-/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home}
export JAVA_HOME PATH="$JAVA_HOME/bin:$PATH"
BT=$SDK/build-tools/35.0.0
JAR=$SDK/platforms/android-27/android.jar
OUT=build
KS=../wifi-toggle/spike.keystore

rm -rf "$OUT"
mkdir -p "$OUT/classes" "$OUT/dex"

"$BT/aapt2" link -o "$OUT/unsigned.apk" --manifest AndroidManifest.xml -I "$JAR" \
    --min-sdk-version 27 --target-sdk-version 27 --version-code 1 --version-name 0.1

javac -source 8 -target 8 -bootclasspath "$JAR" -Xlint:-options -d "$OUT/classes" \
    $(find src -name '*.java')

"$BT/d8" --min-api 27 --lib "$JAR" --output "$OUT/dex" $(find "$OUT/classes" -name '*.class')
(cd "$OUT/dex" && zip -q ../unsigned.apk classes.dex)

"$BT/zipalign" -f 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"

# Throwaway signing key for the spike only; not used for the real helper.
if [ ! -f "$KS" ]; then
    keytool -genkeypair -keystore "$KS" -storepass android -keypass android -alias spike \
        -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=Wi-Fi Spike" >/dev/null
fi
"$BT/apksigner" sign --ks "$KS" --ks-pass pass:android --out "$OUT/settings-spike.apk" "$OUT/aligned.apk"
"$BT/apksigner" verify "$OUT/settings-spike.apk"
echo "Built $OUT/settings-spike.apk"
