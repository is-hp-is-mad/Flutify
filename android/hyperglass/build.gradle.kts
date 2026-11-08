@file:Suppress("DEPRECATION")

plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

configure<com.android.build.api.dsl.LibraryExtension> {
    namespace = "com.hyperos.glass"
    compileSdk = 35

    defaultConfig {
        minSdk = 21
        consumerProguardFiles("consumer-rules.pro")
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // Zero Xiaomi ROM dependencies; pure Android SDK APIs only.
}
