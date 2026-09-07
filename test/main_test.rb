require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"
require "yaml"

class MainTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  MAIN_RB = File.join(ROOT, "main.rb")
  STUB = File.join(__dir__, "support", "stub_tool.sh")
  ENV_KEYS = %w[
    AC_APK_PATH AC_AAB_PATH AC_ANDROID_KEYSTORE_PATH AC_ANDROID_KEYSTORE_PASSWORD
    AC_ANDROID_ALIAS AC_ANDROID_ALIAS_PASSWORD AC_V2_SIGN AC_OUTPUT_DIR
    ANDROID_HOME AC_TEMP_DIR AC_ENV_FILE_PATH
  ].freeze
  UNSIGNED_META = "META-INF/MANIFEST.MF\\n".freeze
  SIGNED_META = "META-INF/MANIFEST.MF\\nMETA-INF/CERT.SF\\nMETA-INF/CERT.RSA\\nMETA-INF/com/android/build/gradle/app-metadata.properties\\n".freeze

  Result = Struct.new(:stdout, :stderr, :status, :calls, :env_file)

  def setup
    @tmp = Dir.mktmpdir("ac-sign-test")
    @android_home = File.join(@tmp, "android-sdk")
    @output_dir = File.join(@tmp, "output")
    @temp_dir = File.join(@tmp, "temp")
    @input_dir = File.join(@tmp, "input")
    @bin_dir = File.join(@tmp, "bin")
    @env_file = File.join(@tmp, "ac.env")
    @stub_log = File.join(@tmp, "stub.log")
    @keystore = File.join(@tmp, "release.keystore")
    [@output_dir, @temp_dir, @input_dir, @bin_dir].each { |d| FileUtils.mkdir_p(d) }
    FileUtils.touch(@keystore)
    install_build_tools("29.0.3", "34.0.0")
    install_stub(File.join(@bin_dir, "jarsigner"))
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def test_component_yaml_declares_inputs_and_outputs_used_by_main
    component = YAML.safe_load(File.read(File.join(ROOT, "component.yaml")))
    main_source = File.read(MAIN_RB)
    input_keys = component["inputs"].map { |i| i["key"] }
    output_keys = component["outputs"].map { |o| o["key"] }

    assert_equal %w[AC_APK_PATH AC_AAB_PATH AC_ANDROID_KEYSTORE_PATH AC_ANDROID_KEYSTORE_PASSWORD AC_ANDROID_ALIAS AC_ANDROID_ALIAS_PASSWORD AC_V2_SIGN], input_keys
    assert_equal %w[AC_SIGNED_APK_PATH AC_SIGNED_AAB_PATH], output_keys
    input_keys.each { |key| assert_includes main_source, "\"#{key}\"" }
    output_keys.each { |key| assert_includes main_source, "#{key}=" }
    assert_equal ["main.rb"], component["files"]
  end

  def test_skips_when_keystore_path_is_missing
    result = run_main(base_env.merge("AC_ANDROID_KEYSTORE_PATH" => nil))

    assert_equal 0, result.status.exitstatus
    assert_includes result.stdout, "AC_ANDROID_KEYSTORE_PATH is not provided. Skipping step."
    assert_empty result.calls
  end

  def test_skips_when_keystore_path_is_empty
    result = run_main(base_env.merge("AC_ANDROID_KEYSTORE_PATH" => ""))

    assert_equal 0, result.status.exitstatus
    assert_includes result.stdout, "Skipping step."
  end

  def test_aborts_when_keystore_password_is_missing
    assert_aborts_with("AC_ANDROID_KEYSTORE_PASSWORD", "Missing keystore password.")
  end

  def test_aborts_when_alias_is_missing
    assert_aborts_with("AC_ANDROID_ALIAS", "Missing alias.")
  end

  def test_aborts_when_alias_password_is_missing
    assert_aborts_with("AC_ANDROID_ALIAS_PASSWORD", "Missing alias password.")
  end

  def test_aborts_when_output_dir_is_missing
    assert_aborts_with("AC_OUTPUT_DIR", "Missing AC_OUTPUT_DIR variable.")
  end

  def test_aborts_when_android_home_is_missing
    assert_aborts_with("ANDROID_HOME", "Missing ANDROID_HOME variable.")
  end

  def test_aborts_when_temp_dir_is_missing
    assert_aborts_with("AC_TEMP_DIR", "Missing AC_TEMP_DIR variable.")
  end

  def test_aborts_when_apk_and_aab_paths_are_missing
    result = run_main(base_env.merge("AC_APK_PATH" => nil, "AC_AAB_PATH" => nil))

    refute_equal 0, result.status.exitstatus
    assert_includes result.stderr, "Missing APK/AAB path."
    assert_empty result.calls
  end

  def test_signs_apk_with_apksigner_when_v2_sign_is_enabled
    apk = create_artifact("app-release-unsigned.apk")
    result = run_main(base_env.merge("AC_APK_PATH" => apk, "AC_V2_SIGN" => "true"))
    signed = File.join(@output_dir, "app-release-ac-signed.apk")

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_equal %w[aapt zipalign apksigner], result.calls.map(&:first)
    assert_equal ["zipalign", "-f", "4", File.join(@temp_dir, "app-release-unsigned.apk"), signed], result.calls[1]
    assert_equal apksigner_call(signed), result.calls[2]
    assert File.exist?(signed)
    assert_equal({ "AC_SIGNED_APK_PATH" => signed, "AC_SIGNED_AAB_PATH" => "" }, result.env_file)
  end

  def test_signs_apk_with_jarsigner_when_v2_sign_is_disabled
    apk = create_artifact("app-release-unsigned.apk")
    result = run_main(base_env.merge("AC_APK_PATH" => apk, "AC_V2_SIGN" => "false"))
    temp_apk = File.join(@temp_dir, "app-release-unsigned.apk")
    signed = File.join(@output_dir, "app-release-ac-signed.apk")

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_equal %w[aapt jarsigner zipalign], result.calls.map(&:first)
    assert_equal jarsigner_call(temp_apk), result.calls[1]
    assert_equal ["zipalign", "-f", "4", temp_apk, signed], result.calls[2]
    assert File.exist?(signed)
    assert_equal({ "AC_SIGNED_APK_PATH" => signed, "AC_SIGNED_AAB_PATH" => "" }, result.env_file)
  end

  def test_defaults_to_jarsigner_when_v2_sign_is_not_provided
    apk = create_artifact("app.apk")
    result = run_main(base_env.merge("AC_APK_PATH" => apk, "AC_V2_SIGN" => nil))

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_includes result.stdout, "is_v2_sign false"
    assert_equal %w[aapt jarsigner zipalign], result.calls.map(&:first)
  end

  def test_signs_aab_with_jarsigner_even_when_v2_sign_is_enabled
    aab = create_artifact("app-release.aab")
    result = run_main(base_env.merge("AC_APK_PATH" => nil, "AC_AAB_PATH" => aab, "AC_V2_SIGN" => "true"))
    signed = File.join(@output_dir, "app-release-ac-signed.aab")

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_includes result.stdout, "WARNING: AAB files cannot be signed with v2 signing (apksigner). Using jarsigner instead."
    assert_equal %w[aapt zipalign jarsigner], result.calls.map(&:first)
    assert_equal jarsigner_call(signed), result.calls[2]
    assert_equal({ "AC_SIGNED_APK_PATH" => "", "AC_SIGNED_AAB_PATH" => signed }, result.env_file)
  end

  def test_signs_aab_with_jarsigner_when_v2_sign_is_disabled
    aab = create_artifact("app-release.aab")
    result = run_main(base_env.merge("AC_APK_PATH" => nil, "AC_AAB_PATH" => aab, "AC_V2_SIGN" => "false"))
    signed = File.join(@output_dir, "app-release-ac-signed.aab")

    assert_equal 0, result.status.exitstatus, result.stderr
    refute_includes result.stdout, "WARNING"
    assert_equal %w[aapt jarsigner zipalign], result.calls.map(&:first)
    assert_equal({ "AC_SIGNED_APK_PATH" => "", "AC_SIGNED_AAB_PATH" => signed }, result.env_file)
  end

  def test_signs_multiple_apks_and_aabs_joined_with_pipe
    apks = [create_artifact("app-debug.apk"), create_artifact("app-release-unsigned.apk")]
    aabs = [create_artifact("bundle-release.aab")]
    result = run_main(base_env.merge("AC_APK_PATH" => apks.join("|"), "AC_AAB_PATH" => aabs.join("|"), "AC_V2_SIGN" => "true"))

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_equal 3, result.calls.count { |c| c.first == "zipalign" }
    assert_equal 2, result.calls.count { |c| c.first == "apksigner" }
    assert_equal 1, result.calls.count { |c| c.first == "jarsigner" }
    expected_apks = ["app-debug-ac-signed.apk", "app-release-ac-signed.apk"].map { |n| File.join(@output_dir, n) }
    assert_equal expected_apks.sort, result.env_file["AC_SIGNED_APK_PATH"].split("|").sort
    assert_equal File.join(@output_dir, "bundle-release-ac-signed.aab"), result.env_file["AC_SIGNED_AAB_PATH"]
  end

  def test_unsigns_artifact_when_signature_files_exist_in_meta_inf
    apk = create_artifact("app.apk")
    result = run_main(base_env.merge("AC_APK_PATH" => apk, "AC_V2_SIGN" => "true"), aapt_ls: SIGNED_META)
    temp_apk = File.join(@temp_dir, "app.apk")

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_includes result.stdout, "Signature file (DSA or RSA) found in META-INF, unsigning the build artifact..."
    assert_equal %w[aapt aapt zipalign apksigner], result.calls.map(&:first)
    assert_equal ["aapt", "remove", temp_apk, "META-INF/MANIFEST.MF", "META-INF/CERT.SF", "META-INF/CERT.RSA"], result.calls[1]
  end

  def test_does_not_unsign_artifact_without_signature_files
    apk = create_artifact("app.apk")
    result = run_main(base_env.merge("AC_APK_PATH" => apk, "AC_V2_SIGN" => "true"), aapt_ls: UNSIGNED_META)

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_includes result.stdout, "No signature file (DSA or RSA) found in META-INF, no need artifact unsign."
    assert_equal ["aapt", "ls", File.join(@temp_dir, "app.apk")], result.calls[0]
    assert_empty result.calls.select { |c| c[0] == "aapt" && c[1] == "remove" }
  end

  def test_uses_latest_build_tools_version
    apk = create_artifact("app.apk")
    result = run_main(base_env.merge("AC_APK_PATH" => apk, "AC_V2_SIGN" => "true"))
    expected = File.join(@android_home, "build-tools", "34.0.0")

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_includes result.stdout, "@@[command] #{expected}/aapt ls"
    assert_includes result.stdout, "@@[command] #{expected}/zipalign"
    assert_includes result.stdout, "@@[command] #{expected}/apksigner"
  end

  def test_copies_input_artifact_to_temp_dir_before_processing
    apk = create_artifact("app.apk", "original-bytes")
    result = run_main(base_env.merge("AC_APK_PATH" => apk, "AC_V2_SIGN" => "true"))

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_equal "original-bytes", File.read(File.join(@temp_dir, "app.apk"))
    assert_equal "original-bytes", File.read(apk)
  end

  def test_passes_paths_with_spaces_and_special_characters
    dir = File.join(@input_dir, "my app (1)")
    FileUtils.mkdir_p(dir)
    apk = create_artifact(File.join("my app (1)", "app release.apk"))
    result = run_main(base_env.merge("AC_APK_PATH" => apk, "AC_V2_SIGN" => "true"))
    temp_apk = File.join(@temp_dir, "app release.apk")
    signed = File.join(@output_dir, "app release-ac-signed.apk")

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_equal ["aapt", "ls", temp_apk], result.calls[0]
    assert_equal ["zipalign", "-f", "4", temp_apk, signed], result.calls[1]
    assert_equal apksigner_call(signed), result.calls[2]
  end

  def test_passes_passwords_with_shell_special_characters
    apk = create_artifact("app.apk")
    env = base_env.merge(
      "AC_APK_PATH" => apk,
      "AC_V2_SIGN" => "false",
      "AC_ANDROID_KEYSTORE_PASSWORD" => 'st$re "pa$s" `x` \\y',
      "AC_ANDROID_ALIAS_PASSWORD" => 'al!as&pass;*?'
    )
    result = run_main(env)
    jarsigner = result.calls.find { |c| c.first == "jarsigner" }

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_equal 'st$re "pa$s" `x` \\y', jarsigner[jarsigner.index("-storepass") + 1]
    assert_equal 'al!as&pass;*?', jarsigner[jarsigner.index("-keypass") + 1]
  end

  def test_passes_passwords_with_shell_special_characters_to_apksigner
    apk = create_artifact("app.apk")
    env = base_env.merge(
      "AC_APK_PATH" => apk,
      "AC_V2_SIGN" => "true",
      "AC_ANDROID_KEYSTORE_PASSWORD" => 'st$re "pa$s" `x`',
      "AC_ANDROID_ALIAS_PASSWORD" => 'al!as&pass;*?'
    )
    result = run_main(env)
    apksigner = result.calls.find { |c| c.first == "apksigner" }

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_equal 'pass:st$re "pa$s" `x`', apksigner[apksigner.index("--ks-pass") + 1]
    assert_equal 'pass:al!as&pass;*?', apksigner[apksigner.index("--key-pass") + 1]
  end

  def test_fails_when_signing_tool_fails
    apk = create_artifact("app.apk")
    result = run_main(base_env.merge("AC_APK_PATH" => apk, "AC_V2_SIGN" => "true"), fail_tool: "apksigner")

    refute_equal 0, result.status.exitstatus
    assert_includes result.stdout, "apksigner failed"
    refute File.exist?(@env_file)
  end

  def test_fails_when_zipalign_fails
    apk = create_artifact("app.apk")
    result = run_main(base_env.merge("AC_APK_PATH" => apk, "AC_V2_SIGN" => "false"), fail_tool: "zipalign")

    refute_equal 0, result.status.exitstatus
    assert_includes result.stdout, "zipalign failed"
    assert_empty result.calls.select { |c| c.first == "apksigner" }
  end

  def test_appends_outputs_to_existing_env_file
    File.write(@env_file, "EXISTING=1\n")
    apk = create_artifact("app.apk")
    result = run_main(base_env.merge("AC_APK_PATH" => apk, "AC_V2_SIGN" => "true"))
    signed = File.join(@output_dir, "app-ac-signed.apk")

    assert_equal 0, result.status.exitstatus, result.stderr
    assert_equal ["EXISTING=1", "AC_SIGNED_APK_PATH=#{signed}", "AC_SIGNED_AAB_PATH="], File.readlines(@env_file, chomp: true)
    assert_includes result.stdout, "Exporting AC_SIGNED_APK_PATH=#{signed}"
    assert_includes result.stdout, "Exporting AC_SIGNED_AAB_PATH="
  end

  private

  def base_env
    {
      "AC_ANDROID_KEYSTORE_PATH" => @keystore,
      "AC_ANDROID_KEYSTORE_PASSWORD" => "store-pass",
      "AC_ANDROID_ALIAS" => "release-alias",
      "AC_ANDROID_ALIAS_PASSWORD" => "alias-pass",
      "AC_OUTPUT_DIR" => @output_dir,
      "ANDROID_HOME" => @android_home,
      "AC_TEMP_DIR" => @temp_dir,
      "AC_ENV_FILE_PATH" => @env_file,
      "AC_APK_PATH" => create_artifact("default.apk"),
      "AC_AAB_PATH" => nil,
      "AC_V2_SIGN" => "true"
    }
  end

  def run_main(env, aapt_ls: UNSIGNED_META, fail_tool: nil)
    full_env = ENV_KEYS.to_h { |k| [k, nil] }.merge(env).merge(
      "PATH" => "#{@bin_dir}:#{ENV['PATH']}",
      "AC_TEST_STUB_LOG" => @stub_log,
      "AC_TEST_AAPT_LS" => aapt_ls,
      "AC_TEST_FAIL_TOOL" => fail_tool
    )
    stdout, stderr, status = Open3.capture3(full_env, RbConfig.ruby, MAIN_RB, chdir: @tmp)
    Result.new(stdout, stderr, status, read_calls, read_env_file)
  end

  def read_calls
    return [] unless File.exist?(@stub_log)
    File.readlines(@stub_log, chomp: true).map { |line| line.split("\x1f", -1) }
  end

  def read_env_file
    return nil unless File.exist?(@env_file)
    File.readlines(@env_file, chomp: true).to_h { |line| line.split("=", 2) }
  end

  def assert_aborts_with(key, message)
    result = run_main(base_env.merge(key => nil))

    refute_equal 0, result.status.exitstatus
    assert_includes result.stderr, message
    assert_empty result.calls
  end

  def create_artifact(name, content = "artifact")
    path = File.join(@input_dir, name)
    File.write(path, content)
    path
  end

  def install_build_tools(*versions)
    versions.each do |version|
      dir = File.join(@android_home, "build-tools", version)
      FileUtils.mkdir_p(dir)
      %w[aapt zipalign apksigner].each { |tool| install_stub(File.join(dir, tool)) }
    end
  end

  def install_stub(path)
    FileUtils.cp(STUB, path)
    FileUtils.chmod(0o755, path)
  end

  def jarsigner_call(path)
    ["jarsigner", "-verbose", "-sigalg", "SHA1withRSA", "-digestalg", "SHA1",
     "-keystore", @keystore, "-storepass", "store-pass", "-keypass", "alias-pass",
     path, "release-alias"]
  end

  def apksigner_call(path)
    ["apksigner", "sign", "--in", path, "--out", path, "--debuggable-apk-permitted", "true",
     "--ks", @keystore, "--ks-pass", "pass:store-pass", "--ks-key-alias", "release-alias",
     "--key-pass", "pass:alias-pass"]
  end
end
