#import "VolumeLoudnessMeter.h"
#import <AudioToolbox/AudioToolbox.h>
// These unmodified declarations match the implementation already linked from
// SFBAudioEngine 0.14.0. See LoudnessHeaders/provenance.json before upgrading it.
#include "LoudnessHeaders/ebur128_analyzer.h"
#include <memory>

static void MeterError(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"Sonora.VolumeAnalysis" code:1
                                      userInfo:@{NSLocalizedDescriptionKey: message}];
}

static std::vector<float> ChannelWeights(AVAudioFormat *format) {
    const auto count = format.channelCount;
    if (count <= 2) return std::vector<float>(count, 1.f);
    const AudioChannelLayout *layout = format.channelLayout.layout;
    if (!layout) return {};
    std::vector<uint8_t> expanded;
    if (layout->mChannelLayoutTag != kAudioChannelLayoutTag_UseChannelDescriptions) {
        const bool bitmap = layout->mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelBitmap;
        const auto property = bitmap ? kAudioFormatProperty_ChannelLayoutForBitmap : kAudioFormatProperty_ChannelLayoutForTag;
        const void *specifier = bitmap ? (const void *)&layout->mChannelBitmap : (const void *)&layout->mChannelLayoutTag;
        UInt32 size = 0;
        if (AudioFormatGetPropertyInfo(property, sizeof(UInt32), specifier, &size)) return {};
        expanded.resize(size);
        if (AudioFormatGetProperty(property, sizeof(UInt32), specifier, &size, expanded.data())) return {};
        layout = reinterpret_cast<const AudioChannelLayout *>(expanded.data());
    }
    if (layout->mNumberChannelDescriptions != count) return {};
    std::vector<float> weights;
    for (UInt32 i = 0; i < count; ++i) {
        switch (layout->mChannelDescriptions[i].mChannelLabel) {
            case kAudioChannelLabel_Left: case kAudioChannelLabel_Right: case kAudioChannelLabel_Center:
                weights.push_back(1.f); break;
            case kAudioChannelLabel_LFEScreen: weights.push_back(0.f); break;
            case kAudioChannelLabel_LeftSurround: case kAudioChannelLabel_RightSurround:
            case kAudioChannelLabel_RearSurroundLeft: case kAudioChannelLabel_RearSurroundRight:
            case kAudioChannelLabel_LeftSurroundDirect: case kAudioChannelLabel_RightSurroundDirect:
                weights.push_back(1.41f); break;
            default: return {}; // An unknown layout must not silently produce incorrect gains.
        }
    }
    return weights;
}

@implementation VolumeLoudnessMeter {
    std::unique_ptr<loudness::EbuR128Analyzer> _meter;
    AVAudioFormat *_format;
}
- (instancetype)initWithFormat:(AVAudioFormat *)format error:(NSError **)error {
    self = [super init];
    if (!self) return nil;
    try {
        auto weights = ChannelWeights(format);
        if (format.commonFormat != AVAudioPCMFormatFloat32 || format.interleaved || weights.empty() ||
            format.channelCount > 32 || format.sampleRate < 8000 || format.sampleRate > 384000) {
            MeterError(error, @"No se puede analizar esta frecuencia o distribución de canales."); return nil;
        }
        _format = format;
        _meter = std::make_unique<loudness::EbuR128Analyzer>(format.channelCount, weights, format.sampleRate, false);
    } catch (const std::exception &) {
        MeterError(error, @"No se pudo preparar el medidor de sonoridad."); return nil;
    }
    return self;
}
- (BOOL)appendBuffer:(AVAudioPCMBuffer *)buffer error:(NSError **)error {
    if (![buffer.format isEqual:_format] || !buffer.floatChannelData) {
        MeterError(error, @"El lector entregó un formato de audio inesperado."); return NO;
    }
    try {
        _meter->Process(buffer.floatChannelData, buffer.frameLength, loudness::EbuR128Analyzer::FLOAT,
                        loudness::EbuR128Analyzer::PLANAR_NON_CONTIGUOUS);
        return YES;
    } catch (const std::exception &) {
        MeterError(error, @"No se pudo medir el audio de este archivo."); return NO;
    }
}
- (NSNumber *)gainWithError:(NSError **)error {
    const auto value = _meter->GetRelativeGatedIntegratedLoudness();
    if (!value || !std::isfinite(*value) || *value <= loudness::kAbsoluteThresholdLKFS) {
        MeterError(error, @"El archivo contiene silencio o no tiene suficiente audio para medirlo."); return nil;
    }
    return @(-18.f - *value);
}
- (double)peak { return _meter->digital_peak(); }
+ (NSNumber *)albumGainForMeters:(NSArray<VolumeLoudnessMeter *> *)meters error:(NSError **)error {
    try {
        std::vector<loudness::EbuR128Analyzer *> values;
        for (VolumeLoudnessMeter *meter in meters) values.push_back(meter->_meter.get());
        const auto value = loudness::EbuR128Analyzer::GetRelativeGatedIntegratedLoudness(values);
        if (value && std::isfinite(*value)) return @(-18.f - *value);
    } catch (const std::exception &) { }
    MeterError(error, @"No se pudo medir la sonoridad del álbum."); return nil;
}
@end
