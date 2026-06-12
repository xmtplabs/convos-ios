import ConvosComposer
import SwiftUI

// Module-scope aliases for types moved into the ConvosComposer package, so
// existing app call sites keep compiling without per-file imports. Extension
// members (e.g. View.readHeight, EnvironmentValues keys) still need an
// explicit import at the use site.
typealias VoiceMemoWaveformView = ConvosComposer.VoiceMemoWaveformView
typealias ExplosionCountdownBadge = ConvosComposer.ExplosionCountdownBadge
typealias VideoFile = ConvosComposer.VideoFile
typealias HeightReader = ConvosComposer.HeightReader
typealias HeightPreferenceKey = ConvosComposer.HeightPreferenceKey
typealias CameraPickerView = ConvosComposer.CameraPickerView
typealias AvatarView = ConvosComposer.AvatarView
typealias ProfileAvatarView = ConvosComposer.ProfileAvatarView
typealias MonogramView = ConvosComposer.MonogramView
typealias EmojiAvatarView = ConvosComposer.EmojiAvatarView
typealias ConversationAvatarView = ConvosComposer.ConversationAvatarView
typealias PendingAgentAvatarView = ConvosComposer.PendingAgentAvatarView
typealias MessageAvatarView = ConvosComposer.MessageAvatarView
typealias ClusteredAvatarView = ConvosComposer.ClusteredAvatarView
typealias PendingAgentPresentation = ConvosComposer.PendingAgentPresentation
typealias PendingAgentAvatarIdentity = ConvosComposer.PendingAgentAvatarIdentity
typealias ConversationToolbarButton = ConvosComposer.ConversationToolbarButton
typealias IndicatorToastStyle = ConvosComposer.IndicatorToastStyle
typealias ExplodeState = ConvosComposer.ExplodeState
typealias ExplodeButton = ConvosComposer.ExplodeButton
typealias HoldToConfirmStyleConfig = ConvosComposer.HoldToConfirmStyleConfig
typealias HoldToConfirmPrimitiveStyle = ConvosComposer.HoldToConfirmPrimitiveStyle
typealias ShatteringText = ConvosComposer.ShatteringText
typealias ShatteringTextAnimationConfig = ConvosComposer.ShatteringTextAnimationConfig
typealias ConversationIndicator<InfoView: View, QuickEdit: View> = ConvosComposer.ConversationIndicator<InfoView, QuickEdit>
typealias PulsingCircleView = ConvosComposer.PulsingCircleView
typealias QRCodeView = ConvosComposer.QRCodeView
typealias LinkDetectingTextView = ConvosComposer.LinkDetectingTextView
typealias LinkHitTestable = ConvosComposer.LinkHitTestable
typealias LinkTextView = ConvosComposer.LinkTextView
typealias InAppBrowser = ConvosComposer.InAppBrowser
typealias InlineVideoPlayerView = ConvosComposer.InlineVideoPlayerView
typealias AgentContactCardStyle = ConvosComposer.AgentContactCardStyle
typealias AgentContactCardView = ConvosComposer.AgentContactCardView
typealias AgentLostPowerStatus = ConvosComposer.AgentLostPowerStatus
typealias CloudConnectionServiceInfo = ConvosComposer.CloudConnectionServiceInfo
typealias CloudConnectionServiceCatalog = ConvosComposer.CloudConnectionServiceCatalog
typealias AttachmentShareLink = ConvosComposer.AttachmentShareLink
