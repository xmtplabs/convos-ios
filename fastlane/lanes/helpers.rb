platform :ios do
# Configure App Store Connect API key once per lane invocation.
  # Subsequent actions (match, pilot, etc.) pick this up automatically
  # via Fastlane's lane context.
  def setup_app_store_connect_api_key
    app_store_connect_api_key(
      key_id:        ENV.fetch("APP_STORE_CONNECT_API_KEY_ID"),
      issuer_id:     ENV.fetch("APP_STORE_CONNECT_ISSUER_ID"),
      key_filepath:  ENV["APP_STORE_CONNECT_API_KEY_FILEPATH"],
      key_content:   ENV["APP_STORE_CONNECT_API_PRIVATE_KEY"],
      is_key_content_base64: false,
      in_house:      false,
    )
  end

  desc "Sanity check API Key"
  lane :verify_api_key do
    setup_app_store_connect_api_key
    UI.success "API key OK"
  end
end
