import ConvosComposer

// Module-scope aliases for types moved into the ConvosComposer package, so
// existing app call sites keep compiling without per-file imports. Extension
// members (e.g. View.readHeight) still need an explicit import at the use site.
typealias VoiceMemoWaveformView = ConvosComposer.VoiceMemoWaveformView
typealias ExplosionCountdownBadge = ConvosComposer.ExplosionCountdownBadge
typealias VideoFile = ConvosComposer.VideoFile
typealias HeightReader = ConvosComposer.HeightReader
typealias HeightPreferenceKey = ConvosComposer.HeightPreferenceKey
typealias CameraPickerView = ConvosComposer.CameraPickerView
