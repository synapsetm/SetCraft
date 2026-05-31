#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Roh-Metadaten einer Audiodatei, gelesen via TagLib.
/// Eigenschaften, die in der Datei fehlen, sind `nil` bzw. 0.
/// Der Kommentar ist roh (inkl. eines eventuellen Sterne-Präfixes); das
/// Parsen übernimmt der Swift-Layer.
@interface SetifyRawTags : NSObject

@property (nonatomic, copy, nullable) NSString *title;
@property (nonatomic, copy, nullable) NSString *artist;
@property (nonatomic, copy, nullable) NSString *album;
@property (nonatomic, copy, nullable) NSString *genre;
@property (nonatomic, copy, nullable) NSString *comment;
@property (nonatomic, assign) NSInteger year;
@property (nonatomic, assign) NSInteger trackNumber;

/// BPM als String, falls in den Datei-Tags hinterlegt (z. B. "174").
@property (nonatomic, copy, nullable) NSString *bpm;

/// Initialer Key (Camelot oder roh), z. B. "8A".
@property (nonatomic, copy, nullable) NSString *initialKey;

/// POPM-Wert (0–255). 0 = nicht gesetzt. Nur ID3 (MP3/AIFF).
@property (nonatomic, assign) NSInteger popmRating;

@property (nonatomic, assign) double durationSeconds;
@property (nonatomic, assign) NSInteger sampleRate;
@property (nonatomic, assign) NSInteger bitrate;

@end


/// Dünne Objective-C++-Brücke über TagLib.
/// Liest und schreibt Metadaten auf Dateipfaden. Der Aufrufer (Swift) ist
/// für Sandbox-Zugriff, atomares Schreiben (Temp + Rename) und das
/// Serialisieren von Schreibzugriffen verantwortlich.
@interface SetifyTagBridge : NSObject

/// Liest alle für die App relevanten Tag-Felder. Gibt `nil` zurück, wenn die
/// Datei nicht geöffnet werden kann.
+ (nullable SetifyRawTags *)readTagsAtPath:(NSString *)path
                                     error:(NSError * _Nullable * _Nullable)error;

/// Schreibt den vollständigen gewünschten Tag-Zustand zurück in die Datei.
/// Leere Strings entfernen das jeweilige Feld; der Aufrufer hat den Sterne-
/// Präfix bereits in den Kommentar eingebaut.
/// Diese Methode arbeitet **direkt** auf `path` — Atomarität (Temp +
/// Rename) muss der Swift-Layer sicherstellen.
+ (BOOL)writeTagsAtPath:(NSString *)path
                  title:(NSString *)title
                 artist:(NSString *)artist
                  album:(NSString *)album
                  genre:(NSString *)genre
                comment:(NSString *)comment
                    bpm:(NSString *)bpm
             initialKey:(NSString *)initialKey
                  error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
