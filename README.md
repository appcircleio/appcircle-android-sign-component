# Appcircle Android Sign

Signs your APK or App Bundle with the given Android keystore and export a binary file compatible with Android devices.

Required Input Variables
- `$AC_APK_PATH`: APK file path 
- `$AC_AAB_PATH`: App Bundle path
- `$AC_ANDROID_KEYSTORE_PATH`: Keystore file can be selected in the build configuration. This value will be auto-generated depending on your keystore file selection in [signing configuration on Appcircle](https://docs.appcircle.io/build/building-android-applications#signing). 
- `$AC_ANDROID_KEYSTORE_PASSWORD`: Keystore password. This value will be auto-generated depending on your keystore file selection
- `$AC_ANDROID_ALIAS`: Alis name. This value will be auto-generated depending on your build configuration
- `$AC_ANDROID_ALIAS_PASSWORD`: Alias password. This value will be auto-generated depending on your build configuration

Output Variables
- `$AC_SIGNED_APK_PATH`: Path for the signed APK file output
- `$AC_SIGNED_AAB_PATH`: Path for the signed App Bundle file output
