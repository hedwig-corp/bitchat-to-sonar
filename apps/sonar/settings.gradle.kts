pluginManagement {
    repositories {
        google {
            content {
                includeGroupByRegex("com\\.android.*")
                includeGroupByRegex("com\\.google.*")
                includeGroupByRegex("androidx.*")
            }
        }
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositories {
        google {
            content {
                includeGroupByRegex("com\\.android.*")
                includeGroupByRegex("com\\.google.*")
                includeGroupByRegex("androidx.*")
            }
        }
        mavenCentral()
        // Breez SDK Liquid (on-device Lightning wallet for ⚡PAY).
        maven("https://mvn.breez.technology/releases")
    }
}

rootProject.name = "Sonar"
include(":composeApp")
include(":baselineprofile")
include(":transcript-engine-policy")
include(":transcript-engine-compose")
include(":transcript-engine-sample")

project(":transcript-engine-policy").projectDir = file("../../packages/transcript-engine-policy")
project(":transcript-engine-compose").projectDir = file("../../packages/transcript-engine-compose")
project(":transcript-engine-sample").projectDir = file("../../packages/transcript-engine-sample")
