platform :ios do
  desc "Sync match profiles for all bundle IDs (run after Matchfile changes)"
  lane :sync_match do |options|
    type = options[:type] || UI.user_error!("Pass type: bundle exec fastlane sync_match type:development")

    setup_app_store_connect_api_key

    match(
      type: type,
      readonly: false,
      skip_certificate_matching: true,
      force_for_new_devices: true,
    )
  end
end
