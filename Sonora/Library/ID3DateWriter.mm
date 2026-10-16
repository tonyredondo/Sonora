#import "ID3DateWriter.h"
#include <taglib/aifffile.h>
#include <taglib/id3v2tag.h>
#include <taglib/mpegfile.h>
#include <taglib/textidentificationframe.h>
#include <taglib/tfilestream.h>
#include <taglib/wavfile.h>
#include <exception>

static void SetDate(TagLib::ID3v2::Tag *tag, NSString *date) {
    tag->removeFrames("TDRC");
    tag->removeFrames("TYER");
    if (date.length) {
        auto frame = new TagLib::ID3v2::TextIdentificationFrame("TDRC", TagLib::String::UTF8);
        frame->setText(TagLib::String(date.UTF8String, TagLib::String::UTF8));
        tag->addFrame(frame);
    }
}

@implementation ID3DateWriter
+ (BOOL)writeDate:(NSString *)date toURL:(NSURL *)url error:(NSError **)error {
    bool saved = false;
    try {
        TagLib::FileStream stream(url.fileSystemRepresentation);
        if (stream.isOpen()) {
            NSString *extension = url.pathExtension.lowercaseString;
            if ([extension isEqualToString:@"mp3"]) {
                TagLib::MPEG::File file(&stream, false);
                if (file.isValid()) { SetDate(file.ID3v2Tag(true), date); saved = file.save(); }
            } else if ([@[@"wav", @"wave"] containsObject:extension]) {
                TagLib::RIFF::WAV::File file(&stream, false);
                if (file.isValid()) { SetDate(file.ID3v2Tag(), date); saved = file.save(); }
            } else if ([@[@"aif", @"aiff"] containsObject:extension]) {
                TagLib::RIFF::AIFF::File file(&stream, false);
                if (file.isValid()) { SetDate(file.tag(), date); saved = file.save(); }
            }
        }
    } catch (const std::exception &) { saved = false; }
    if (!saved && error) {
        *error = [NSError errorWithDomain:@"Sonora.Metadata" code:1 userInfo:@{NSLocalizedDescriptionKey: @"No se pudo guardar la fecha. El original no se ha sustituido."}];
    }
    return saved;
}
@end
