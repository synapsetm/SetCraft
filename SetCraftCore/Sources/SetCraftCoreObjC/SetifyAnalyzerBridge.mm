#import "SetifyAnalyzerBridge.h"

#include <aubio.h>
#include <keyfinder.h>

#include <vector>
#include <string>

// MARK: - Key-Mapping (KeyFinder enum → Camelot-Notation)

static NSString *_Nullable camelotForKey(KeyFinder::key_t key) {
    switch (key) {
        case KeyFinder::A_MAJOR:        return @"11B";
        case KeyFinder::A_MINOR:        return @"8A";
        case KeyFinder::B_FLAT_MAJOR:   return @"6B";
        case KeyFinder::B_FLAT_MINOR:   return @"3A";
        case KeyFinder::B_MAJOR:        return @"1B";
        case KeyFinder::B_MINOR:        return @"10A";
        case KeyFinder::C_MAJOR:        return @"8B";
        case KeyFinder::C_MINOR:        return @"5A";
        case KeyFinder::D_FLAT_MAJOR:   return @"3B";
        case KeyFinder::D_FLAT_MINOR:   return @"12A";
        case KeyFinder::D_MAJOR:        return @"10B";
        case KeyFinder::D_MINOR:        return @"7A";
        case KeyFinder::E_FLAT_MAJOR:   return @"5B";
        case KeyFinder::E_FLAT_MINOR:   return @"2A";
        case KeyFinder::E_MAJOR:        return @"12B";
        case KeyFinder::E_MINOR:        return @"9A";
        case KeyFinder::F_MAJOR:        return @"7B";
        case KeyFinder::F_MINOR:        return @"4A";
        case KeyFinder::G_FLAT_MAJOR:   return @"2B";
        case KeyFinder::G_FLAT_MINOR:   return @"11A";
        case KeyFinder::G_MAJOR:        return @"9B";
        case KeyFinder::G_MINOR:        return @"6A";
        case KeyFinder::A_FLAT_MAJOR:   return @"4B";
        case KeyFinder::A_FLAT_MINOR:   return @"1A";
        case KeyFinder::SILENCE:        return nil;
    }
    return nil;
}

@implementation SetifyAnalyzerBridge

// MARK: - BPM

+ (double)analyzeBPMFromFloat32Samples:(NSData *)samples
                             sampleRate:(double)sampleRate {
    const uint_t winSize = 1024;
    const uint_t hopSize = 512;

    if (samples.length < sizeof(float) * winSize || sampleRate <= 0) {
        return 0.0;
    }

    aubio_tempo_t *tempo = new_aubio_tempo("default", winSize, hopSize, (uint_t)sampleRate);
    if (tempo == nullptr) {
        return 0.0;
    }

    fvec_t *in  = new_fvec(hopSize);
    fvec_t *out = new_fvec(2);
    if (in == nullptr || out == nullptr) {
        if (in)  del_fvec(in);
        if (out) del_fvec(out);
        del_aubio_tempo(tempo);
        return 0.0;
    }

    const float *src = (const float *)samples.bytes;
    NSUInteger sampleCount = samples.length / sizeof(float);
    NSUInteger frames = sampleCount / hopSize;

    for (NSUInteger frame = 0; frame < frames; ++frame) {
        for (uint_t i = 0; i < hopSize; ++i) {
            in->data[i] = src[frame * hopSize + i];
        }
        aubio_tempo_do(tempo, in, out);
    }

    smpl_t bpm = aubio_tempo_get_bpm(tempo);

    del_fvec(in);
    del_fvec(out);
    del_aubio_tempo(tempo);
    aubio_cleanup();

    if (!std::isfinite(bpm) || bpm <= 0) {
        return 0.0;
    }
    return (double)bpm;
}

// MARK: - Key

+ (NSString *)analyzeKeyFromFloat32Samples:(NSData *)samples
                                 sampleRate:(double)sampleRate {
    if (samples.length == 0 || sampleRate <= 0) {
        return nil;
    }

    KeyFinder::KeyFinder kf;
    KeyFinder::AudioData audio;
    audio.setFrameRate((unsigned int)sampleRate);
    audio.setChannels(1);

    NSUInteger sampleCount = samples.length / sizeof(float);
    audio.addToSampleCount((unsigned int)sampleCount);

    const float *src = (const float *)samples.bytes;
    for (NSUInteger i = 0; i < sampleCount; ++i) {
        audio.setSample((unsigned int)i, (double)src[i]);
    }

    KeyFinder::key_t result;
    try {
        result = kf.keyOfAudio(audio);
    } catch (const std::exception &) {
        return nil;
    }

    return camelotForKey(result);
}

@end
