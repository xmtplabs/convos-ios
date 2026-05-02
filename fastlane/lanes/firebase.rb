platform :ios do
  desc "Build Convos (PR Preview) ad-hoc and upload to Firebase App Distribution"
  lane :firebase_pr do
    setup_ci if is_ci

    match(
      type: "adhoc",
      git_url: MATCH_GIT_URL,
      app_identifier: [PR_BUNDLE_ID, PR_NSE_BUNDLE_ID],
      readonly: true,
    )

    build_app(
      project: PROJECT,
      scheme: PR_SCHEME,
      configuration: PR_CONFIG,
      export_method: "ad-hoc",
      output_directory: OUTPUT_DIR,
      output_name: OUTPUT_NAME,
      clean: true,
      # Override target-level Swift settings that block PR builds. These
      # belong in the project file long-term but live here so non-PR
      # configurations (Dev/Local/Prod) keep their stricter checks.
      xcargs: [
        "SWIFT_TREAT_WARNINGS_AS_ERRORS=NO",
        "GCC_TREAT_WARNINGS_AS_ERRORS=NO",
        "-allowProvisioningUpdates",
      ].join(" "),
      export_options: {
        provisioningProfiles: {
          PR_BUNDLE_ID => "match AdHoc #{PR_BUNDLE_ID}",
          PR_NSE_BUNDLE_ID => "match AdHoc #{PR_NSE_BUNDLE_ID}",
        },
      },
    )

    firebase_app_distribution(
      app: ENV.fetch("FIREBASE_APP_ID_PR"),
      # Prefer the JSON content env var (kept in process memory only). Fall
      # back to a file path so local runs with a downloaded key still work.
      service_credentials_json_data: ENV["FIREBASE_SERVICE_ACCOUNT_JSON_CONTENT"],
      service_credentials_file: ENV["FIREBASE_SERVICE_ACCOUNT_JSON"],
      groups: ENV.fetch("FIREBASE_TESTER_GROUPS", "internal-testers"),
      release_notes: firebase_release_notes,
      ipa_path: File.join(OUTPUT_DIR, OUTPUT_NAME),
    )
  end

  # Compose release notes from PR metadata when running in CI, otherwise
  # fall back to the latest commit subject.
  def firebase_release_notes
    # Empty strings are truthy in Ruby, so we have to check for actual content;
    # GitHub Actions sets these to "" on workflow_dispatch (non-PR triggers).
    pr_number = first_non_empty(ENV["GITHUB_PR_NUMBER"], ENV["PR_NUMBER"])
    pr_title  = first_non_empty(ENV["GITHUB_PR_TITLE"],  ENV["PR_TITLE"])
    sha       = ENV["GITHUB_SHA"]&.slice(0, 7)

    if pr_number && pr_title
      "PR ##{pr_number}: #{pr_title}#{sha ? " (#{sha})" : ""}"
    else
      `git log -1 --pretty=%s`.strip
    end
  end

  def first_non_empty(*values)
    values.compact.map(&:to_s).map(&:strip).find { |v| !v.empty? }
  end
end
