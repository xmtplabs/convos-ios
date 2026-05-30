platform :ios do
  desc "Build Convos (Prod) and upload to TestFlight internal groups"
  lane :testflight_prod do
    setup_ci if is_ci
    setup_app_store_connect_api_key

    # Self-healing CFBundleVersion: prefer git's monotonic commit count, but
    # always overshoot the highest build currently in TestFlight so re-runs
    # and out-of-order pushes never collide with ASC's "must be greater" rule.
    git_count = `git rev-list --count HEAD`.strip.to_i
    latest_tf = latest_testflight_build_number(
      app_identifier: PROD_BUNDLE_ID,
      initial_build_number: 0,
    )
    build_number = [git_count, latest_tf + 1].max
    UI.message("Build number: git=#{git_count}, latest_tf=#{latest_tf}, using=#{build_number}")

    increment_build_number(
      build_number: build_number,
      xcodeproj: PROJECT,
    )

    match(
      type: "appstore",
      git_url: MATCH_GIT_URL,
      app_identifier: [PROD_BUNDLE_ID, PROD_NSE_BUNDLE_ID],
      readonly: is_ci,
    )

    # Do not hardcode the profile names. The portal name can carry a numeric
    # suffix (e.g. "match AppStore org.convos.ios.ConvosNSE 1777583017") when
    # a name collides on the developer portal, and that suffix changes if the
    # profile is regenerated. match publishes the real installed name per
    # bundle id in sigh_<id>_appstore_profile-name; read those and write them
    # into the Manual-signing build settings just before archiving.
    app_profile = match_profile_name(PROD_BUNDLE_ID)
    nse_profile = match_profile_name(PROD_NSE_BUNDLE_ID)

    apply_prod_signing("Convos", app_profile)
    apply_prod_signing("NotificationService", nse_profile)

    build_app(
      project: PROJECT,
      scheme: PROD_SCHEME,
      configuration: PROD_CONFIG,
      export_method: "app-store",
      output_directory: OUTPUT_DIR,
      output_name: "Convos-Prod-TestFlight.ipa",
      clean: true,
      export_options: {
        provisioningProfiles: {
          PROD_BUNDLE_ID     => app_profile,
          PROD_NSE_BUNDLE_ID => nse_profile,
        },
      },
    )

    upload_to_testflight(
      ipa: File.join(OUTPUT_DIR, "Convos-Prod-TestFlight.ipa"),
      app_identifier: PROD_BUNDLE_ID,
      groups: ["Convos iOS Team", "Convos Team", "Friends and Family", "XMTP Labs Team"],
      changelog: testflight_release_notes,
      distribute_external: false,
      skip_waiting_for_build_processing: false,
      notify_external_testers: false,
    )
  end

  # The provisioning profile name match installed for a bundle id, as published
  # in the sigh_<id>_appstore_profile-name environment variable. Falls back to
  # the conventional name if the variable is missing (e.g. a readonly run that
  # found the profile already installed).
  def match_profile_name(bundle_id)
    env_key = "sigh_#{bundle_id}_appstore_profile-name"
    name = ENV[env_key]
    if name.to_s.empty?
      UI.important("#{env_key} not set; falling back to \"match AppStore #{bundle_id}\"")
      return "match AppStore #{bundle_id}"
    end
    name
  end

  # Pin Manual AppStore signing on a target's Release configuration using the
  # exact profile name match resolved. Keeps the profile name out of the Xcode
  # project so a regenerated (possibly re-suffixed) profile never desyncs it.
  # Bundle id and team are left to the Prod xcconfig; only the profile name and
  # signing style need to be set here.
  def apply_prod_signing(target, profile_name)
    update_code_signing_settings(
      path: PROJECT,
      targets: [target],
      build_configurations: [PROD_CONFIG],
      use_automatic_signing: false,
      code_sign_identity: "Apple Distribution",
      profile_name: profile_name,
    )
  end

  # Release notes shown to internal testers in TestFlight. Includes commit
  # subject + short SHA + branch so a tester can map a build back to the
  # exact commit that produced it.
  def testflight_release_notes
    sha     = (ENV["GITHUB_SHA"] || `git rev-parse HEAD`.strip).slice(0, 7)
    subject = `git log -1 --pretty=%s`.strip
    branch  = ENV["GITHUB_REF_NAME"] || `git rev-parse --abbrev-ref HEAD`.strip
    "#{subject}\nBranch: #{branch}\nCommit: #{sha}"
  end
end
