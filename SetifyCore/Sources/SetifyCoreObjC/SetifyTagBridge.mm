#import "SetifyTagBridge.h"

#include <fileref.h>
#include <tag.h>
#include <tpropertymap.h>
#include <tstringlist.h>
#include <audioproperties.h>

@implementation SetifyRawTags
@end


/// Liest den ersten Eintrag der Property-Map zu einem Schlüssel als NSString.
/// Gibt nil zurück, wenn der Schlüssel fehlt oder leer ist.
static NSString * _Nullable firstProperty(const TagLib::PropertyMap &props,
                                          const char *key) {
    auto it = props.find(key);
    if (it == props.end() || it->second.isEmpty()) {
        return nil;
    }
    TagLib::String value = it->second.front();
    if (value.isEmpty()) {
        return nil;
    }
    return [NSString stringWithUTF8String:value.toCString(true)];
}

static NSString * _Nullable nonEmptyString(const TagLib::String &s) {
    if (s.isEmpty()) {
        return nil;
    }
    return [NSString stringWithUTF8String:s.toCString(true)];
}


@implementation SetifyTagBridge

+ (nullable SetifyRawTags *)readTagsAtPath:(NSString *)path
                                     error:(NSError * _Nullable * _Nullable)error {
    TagLib::FileRef fileRef([path fileSystemRepresentation], true);
    if (fileRef.isNull() || !fileRef.tag()) {
        if (error) {
            *error = [NSError errorWithDomain:@"SetifyTagBridge"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Datei konnte nicht gelesen werden"}];
        }
        return nil;
    }

    TagLib::Tag *tag = fileRef.tag();
    SetifyRawTags *result = [SetifyRawTags new];

    result.title       = nonEmptyString(tag->title());
    result.artist      = nonEmptyString(tag->artist());
    result.album       = nonEmptyString(tag->album());
    result.genre       = nonEmptyString(tag->genre());
    result.comment     = nonEmptyString(tag->comment());
    result.year        = (NSInteger)tag->year();
    result.trackNumber = (NSInteger)tag->track();

    // BPM und Key über die Property-Map (formatübergreifend).
    TagLib::PropertyMap props = fileRef.file()->properties();
    result.bpm        = firstProperty(props, "BPM");
    result.initialKey = firstProperty(props, "INITIALKEY");

    // POPM-Rating wird erst beim Schreiben relevant; Lesen kommt in einer
    // späteren Iteration. Für jetzt: 0 = nicht gelesen.
    result.popmRating = 0;

    TagLib::AudioProperties *audio = fileRef.audioProperties();
    if (audio) {
        result.durationSeconds = audio->lengthInMilliseconds() / 1000.0;
        result.sampleRate      = audio->sampleRate();
        result.bitrate         = audio->bitrate();
    }

    return result;
}

@end
