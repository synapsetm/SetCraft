#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Schmale Objective-C++-Brücke zu aubio (Tempo) und libKeyFinder (Key).
/// Beide Methoden erwarten **mono Float32-PCM-Samples**. Der Aufrufer
/// dekodiert die Datei (z. B. via `AVAudioFile`) und mischt auf Mono,
/// damit die Brücke C++-Detail nicht nach Swift leakt.
@interface SetifyAnalyzerBridge : NSObject

/// Schätzt die BPM aus den übergebenen Samples. Liefert 0, falls keine
/// belastbare Schätzung möglich war. Oktavkorrektur erfolgt in Swift.
+ (double)analyzeBPMFromFloat32Samples:(NSData *)samples
                             sampleRate:(double)sampleRate;

/// Liefert die Camelot-Notation (z. B. „8A") oder `nil`, wenn das Stück
/// als Silence klassifiziert wurde.
+ (nullable NSString *)analyzeKeyFromFloat32Samples:(NSData *)samples
                                          sampleRate:(double)sampleRate;

@end

NS_ASSUME_NONNULL_END
