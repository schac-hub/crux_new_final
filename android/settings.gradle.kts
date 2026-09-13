pluginManagement {
    val flutterSdkPath = {
        val properties = java.util.Properties()
        val propertiesFile = settingsDir.resolve("local.properties")
        if (propertiesFile.exists()) {
            propertiesFile.inputStream().use { properties.load(it) }
        }
        val sdkPath = properties.getProperty("flutter.sdk")
            ?: System.getenv("FLUTTER_ROOT")
            ?: System.getenv("FLUTTER_SDK")
        if (sdkPath == null) {
            throw GradleException("Flutter SDK not found. Set flutter.sdk in local.properties or FLUTTER_ROOT environment variable.")
        }
        sdkPath
    }()

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("dev.flutter.flutter-gradle-plugin") apply false
    // AGP 8.11.1 : minimum exigé par le plugin Gradle de Flutter 3.47.2
    // (8.9.1 était refusé : "lower than Flutter's minimum supported version").
    id("com.android.application") version "8.11.1" apply false
    // Kotlin 2.2.20 : minimum exigé par Flutter 3.47.2 (1.9.22 refusé).
    id("org.jetbrains.kotlin.android") version "2.2.20" apply false
    id("com.google.gms.google-services") version "4.4.2" apply false
}

dependencyResolutionManagement {
    // PREFER_PROJECT : le plugin Gradle Flutter ajoute un dépôt maven au
    // projet ; FAIL_ON_PROJECT_REPOS faisait échouer l'application du plugin.
    repositoriesMode.set(RepositoriesMode.PREFER_PROJECT)
    repositories {
        google()
        mavenCentral()
    }
}

include(":app")
