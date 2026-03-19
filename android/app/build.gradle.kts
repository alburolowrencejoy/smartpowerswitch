plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
}
 
dependencies {
    implementation(platform("com.google.firebase:firebase-bom:34.10.0"))
    implementation("com.google.firebase:firebase-auth")
    implementation("com.google.firebase:firebase-database")
}
 
android {
    namespace = "com.dnsc.edu.smartpowerswitch"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "27.0.12077973"
 
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }
 
    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }
 
    defaultConfig {
        applicationId = "com.dnsc.edu.smartpowerswitch"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }
 
    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}
 
flutter {
    source = "../.."
}
