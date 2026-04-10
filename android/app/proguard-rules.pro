# Flutter
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-dontwarn io.flutter.embedding.**

# Keep Flutter Secure Storage
-keep class com.it_nomads.fluttersecurestorage.** { *; }

# Keep WebView (webview_windows not applicable on Android, but keep for safety)
-keep class io.pichfly.webview_windows.** { *; }

# Gson (usado por alguns plugins Flutter)
-keepattributes Signature
-keepattributes *Annotation*

# Preserva nomes de arquivo e número de linha nos stack traces
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile

# Não avisa sobre dependências opcionais ausentes
-dontwarn org.bouncycastle.**
-dontwarn org.conscrypt.**
-dontwarn org.openjsse.**
