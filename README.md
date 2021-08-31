# Appcircle Android Sign

Signs your APK or App Bundle with the given Android keystore and export a binary file compatible with Android devices.

This step follows the Android Build step to sign the unsigned build output if the project doesn't include a keystore.
If your project includes a keystore, the Build Application step will generate a signed artifact. If you do not disable this step, your artifact will be unsigned and re-signed using the keystore selected in the build configuration or in this step.

Required Input Variables
- `$AC_APK_PATH`: APK file path 
- `$AC_AAB_PATH`: App Bundle path
- `$AC_ANDROID_KEYSTORE_PATH`: Keystore file can be selected in the build configuration. This value will be auto-generated depending on your keystore file selection in [signing configuration on Appcircle](https://docs.appcircle.io/build/building-android-applications#signing). 
- `$AC_ANDROID_KEYSTORE_PASSWORD`: Keystore password. This value will be auto-generated depending on your keystore file selection
- `$AC_ANDROID_ALIAS`: Alis name. This value will be auto-generated depending on your build configuration
- `$AC_ANDROID_ALIAS_PASSWORD`: Alias password. This value will be auto-generated depending on your build configuration
- `$AC_V2_SIGN`: Defaults to false. Set true if the signature should be done using apksigner instead of jarsigner. [Apps targeting Android 11 require APK Signature Scheme v2](https://developer.android.com/about/versions/11/behavior-changes-11#minimum-signature-scheme)

Output Variables
- `$AC_SIGNED_APK_PATH`: Path for the signed APK file output
- `$AC_SIGNED_AAB_PATH`: Path for the signed App Bundle file output
