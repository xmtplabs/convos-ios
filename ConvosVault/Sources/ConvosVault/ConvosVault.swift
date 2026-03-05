// ConvosVault - Multi-device key sync via hidden XMTP group conversation
//
// This module provides the Vault system for syncing per-conversation
// private keys across devices using XMTP's E2E encrypted MLS protocol.
//
// ## Content Types
//
// - `DeviceKeyBundleCodec`: Full key export when a new device joins
// - `DeviceKeyShareCodec`: Single key share on conversation creation
// - `DeviceRemovedCodec`: Notification when a device is removed
