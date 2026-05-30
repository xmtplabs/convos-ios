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
          PROD_BUNDLE_ID     => "match AppStore #{PROD_BUNDLE_ID}",
          # NSE AppStore profile carries a numeric suffix on the portal (a
          # name collision when match first created it), so pin the exact
          # profile name. Drop the suffix here + in the target's
          # PROVISIONING_PROFILE_SPECIFIER if the profile is ever regenerated
          # clean. See PR that introduced this.
          PROD_NSE_BUNDLE_ID => "match AppStore #{PROD_NSE_BUNDLE_ID} 1777583017",
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
