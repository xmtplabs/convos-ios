platform :ios do
  desc "One-time local dev setup: install team certs and profiles into the keychain"
  lane :bootstrap do
    UI.message "🔧 Bootstrapping local dev signing assets…"

    # Development cert + profiles let Xcode "Run on device" work without
    # creating personal signing assets. Read-only because we don't want
    # devs accidentally re-issuing team-shared resources.
    match(type: "development", readonly: true)

    UI.success "✅ Signing assets installed."
    UI.message ""
    UI.message "Next steps:"
    UI.message "  1. Open Convos.xcodeproj in Xcode"
    UI.message "  2. Make sure your Apple ID is signed in: Xcode → Settings → Accounts"
    UI.message "  3. Confirm team is 'XMTP, Inc. (FY4NZR34Z3)' in Signing & Capabilities"
    UI.message "  4. Hit Run — Xcode will pick the right development profile automatically"
    UI.message ""
    UI.message "Heads up: this lane needs MATCH_PASSWORD. Grab it from the team 1Password"
    UI.message "vault. Export it in your shell rc to skip the prompt next time."
    UI.message ""
    UI.message "If Xcode prompts to 'create signing assets' or asks for credentials,"
    UI.message "your Apple ID likely isn't a member of the XMTP team yet — ping an admin."
  end
end
