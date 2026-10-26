import java.util.Base64
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Firma di rilascio: android/key.properties (in CI lo scrive il job android di
// app.yml dai secret). Senza il file si usa la chiave di debug, solo per
// provare l'APK sul proprio telefono: un APK firmato con la chiave di debug non
// si aggiorna con quello firmato con la chiave vera (e viceversa) senza
// disinstallare l'app e perderne i dati. Per le build pubblicate (release v*,
// AAB per Google Play) il workflow imposta UNINOTES_FIRMA_OBBLIGATORIA=1 (o
// -Puninotes.firmaObbligatoria=true): senza una chiave valida la build si ferma.
val keyProperties = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
val firmaObbligatoria: Boolean =
    System.getenv("UNINOTES_FIRMA_OBBLIGATORIA") == "1" ||
        project.findProperty("uninotes.firmaObbligatoria")?.toString() == "true"
// key.properties completo e keystore presente (percorso relativo ad android/app)
val chiaveDiRilascio: Boolean =
    listOf("keyAlias", "keyPassword", "storeFile", "storePassword")
        .all { !keyProperties.getProperty(it).isNullOrBlank() } &&
        file(keyProperties.getProperty("storeFile") ?: "").isFile
if (firmaObbligatoria && !chiaveDiRilascio) {
    throw GradleException(
        "Firma di rilascio obbligatoria: manca android/key.properties completo o il keystore " +
            "(secret ANDROID_KEYSTORE_BASE64, ANDROID_KEYSTORE_PASSWORD, ANDROID_KEY_ALIAS, " +
            "ANDROID_KEY_PASSWORD). Una build pubblicata non va firmata con la chiave di debug."
    )
}

// Schema di ritorno dell'accesso a Google Drive: l'ID client Android al
// contrario (com.googleusercontent.apps.<numero>), preso dal
// --dart-define=GOOGLE_ANDROID_CLIENT_ID della build. Senza ID si usa uno
// schema che non riceve nulla (Google Drive resta disattivato nell'app).
val googleAuthScheme: String = run {
    val defines = mutableMapOf<String, String>()
    val raw = project.findProperty("dart-defines") as String? ?: ""
    for (item in raw.split(",")) {
        val text: String = try {
            String(Base64.getDecoder().decode(item), Charsets.UTF_8)
        } catch (e: IllegalArgumentException) {
            continue
        }
        defines[text.substringBefore("=")] = text.substringAfter("=", "")
    }
    val id: String = (defines["GOOGLE_ANDROID_CLIENT_ID"] ?: "").trim()
        .removeSuffix(".apps.googleusercontent.com")
    if (id.isEmpty()) "io.github.simomagnus.universitynotes.senzagoogle"
    else "com.googleusercontent.apps.$id"
}

android {
    namespace = "io.github.simomagnus.universitynotes"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications (notifiche pianificate) usa le API
        // java.time anche sulle versioni di Android che non le hanno.
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = "io.github.simomagnus.universitynotes"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        manifestPlaceholders["googleAuthScheme"] = googleAuthScheme
    }

    signingConfigs {
        if (chiaveDiRilascio) {
            create("release") {
                keyAlias = keyProperties.getProperty("keyAlias")
                keyPassword = keyProperties.getProperty("keyPassword")
                storeFile = file(keyProperties.getProperty("storeFile"))
                storePassword = keyProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            // chiave di debug solo per le prove (vedi firmaObbligatoria sopra)
            signingConfig = if (chiaveDiRilascio) signingConfigs.getByName("release")
                else signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
