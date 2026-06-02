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
                                     userInfo:@{NSLocalizedDescriptionKey: @"File could not be read"}];
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
    // Label: ID3 TPUB ↔ PropertyMap "LABEL" (Format-übergreifend); manche
    // Dateien hinterlegen den Wert stattdessen unter "PUBLISHER".
    NSString *labelValue = firstProperty(props, "LABEL");
    if (labelValue == nil) {
        labelValue = firstProperty(props, "PUBLISHER");
    }
    result.label      = labelValue;

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

// MARK: - Write

static TagLib::String tagString(NSString *s) {
    if (s.length == 0) {
        return TagLib::String();
    }
    return TagLib::String([s UTF8String], TagLib::String::UTF8);
}

/// Setzt oder entfernt einen Eintrag in einer PropertyMap.
/// Leerer String → Eintrag wird entfernt.
static void setOrErase(TagLib::PropertyMap &props, const char *key, NSString *value) {
    if (value.length == 0) {
        props.erase(key);
    } else {
        props.replace(key, TagLib::StringList(tagString(value)));
    }
}

+ (BOOL)writeTagsAtPath:(NSString *)path
                  title:(NSString *)title
                 artist:(NSString *)artist
                  album:(NSString *)album
                  genre:(NSString *)genre
                comment:(NSString *)comment
                    bpm:(NSString *)bpm
             initialKey:(NSString *)initialKey
                  label:(NSString *)label
                  error:(NSError * _Nullable * _Nullable)error {

    TagLib::FileRef fileRef([path fileSystemRepresentation], false);
    if (fileRef.isNull() || !fileRef.tag()) {
        if (error) {
            *error = [NSError errorWithDomain:@"SetifyTagBridge"
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey: @"File is not writable"}];
        }
        return NO;
    }

    TagLib::Tag *tag = fileRef.tag();
    tag->setTitle(tagString(title));
    tag->setArtist(tagString(artist));
    tag->setAlbum(tagString(album));
    tag->setGenre(tagString(genre));
    tag->setComment(tagString(comment));

    // BPM und Key über PropertyMap → wird je Format in das passende
    // Frame/Atom übersetzt (TBPM/BPM/tmpo bzw. TKEY/INITIALKEY/Freeform).
    TagLib::PropertyMap props = fileRef.file()->properties();
    setOrErase(props, "BPM", bpm);
    setOrErase(props, "INITIALKEY", initialKey);
    setOrErase(props, "LABEL", label);
    fileRef.file()->setProperties(props);

    if (!fileRef.save()) {
        if (error) {
            *error = [NSError errorWithDomain:@"SetifyTagBridge"
                                         code:3
                                     userInfo:@{NSLocalizedDescriptionKey: @"TagLib could not save the file"}];
        }
        return NO;
    }

    return YES;
}

@end
