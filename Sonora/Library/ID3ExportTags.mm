#import "ID3ExportTags.h"
#include <taglib/aifffile.h>
#include <taglib/id3v2tag.h>
#include <taglib/mpegfile.h>
#include <taglib/textidentificationframe.h>
#include <taglib/tfilestream.h>
#include <taglib/wavfile.h>
#include <exception>

static void ExportTagsError(NSError **error, NSString *message) {
    if (error) {
        *error = [NSError errorWithDomain:@"Sonora.Metadata" code:2
                                userInfo:@{NSLocalizedDescriptionKey: message}];
    }
}

static void SetExportValues(TagLib::ID3v2::Tag *tag, NSDictionary<NSString *, NSArray<NSString *> *> *values) {
    for (NSString *key in values) {
        const TagLib::String description(key.UTF8String, TagLib::String::UTF8);
        auto *existing = TagLib::ID3v2::UserTextIdentificationFrame::find(tag, description);
        while (existing) {
            tag->removeFrame(existing);
            existing = TagLib::ID3v2::UserTextIdentificationFrame::find(tag, description);
        }
        auto *frame = new TagLib::ID3v2::UserTextIdentificationFrame(TagLib::String::UTF8);
        frame->setDescription(description);
        TagLib::StringList fields;
        for (NSString *text in values[key]) {
            fields.append(TagLib::String(text.UTF8String, TagLib::String::UTF8));
        }
        // The setter prepends the description, so pass only the text values.
        frame->setText(fields);
        tag->addFrame(frame);
    }
}

static NSDictionary<NSString *, NSArray<NSString *> *> *ExportValues(const TagLib::ID3v2::Tag *tag) {
    NSMutableDictionary<NSString *, NSArray<NSString *> *> *values = [NSMutableDictionary dictionary];
    if (!tag) return values;
    for (const auto *entry : tag->frameList("TXXX")) {
        const auto *frame = dynamic_cast<const TagLib::ID3v2::UserTextIdentificationFrame *>(entry);
        if (!frame) continue;
        NSString *key = [NSString stringWithUTF8String:frame->description().toCString(true)];
        NSMutableArray<NSString *> *fields = [NSMutableArray array];
        bool first = true;
        for (const auto &field : frame->fieldList()) {
            // TagLib includes the description as the first field, not as text.
            if (first) { first = false; continue; }
            NSString *text = [NSString stringWithUTF8String:field.toCString(true)];
            if (text) [fields addObject:text];
        }
        if (key) {
            NSArray<NSString *> *existing = values[key] ?: @[];
            values[key] = [existing arrayByAddingObjectsFromArray:fields];
        }
    }
    return values;
}

@implementation ID3ExportTags
+ (BOOL)writeValues:(NSDictionary<NSString *, NSArray<NSString *> *> *)values toURL:(NSURL *)url error:(NSError **)error {
    bool saved = false;
    try {
        TagLib::FileStream stream(url.fileSystemRepresentation);
        if (stream.isOpen()) {
            NSString *extension = url.pathExtension.lowercaseString;
            if ([extension isEqualToString:@"mp3"]) {
                TagLib::MPEG::File file(&stream, false);
                if (file.isValid()) { SetExportValues(file.ID3v2Tag(true), values); saved = file.save(); }
            } else if ([@[@"wav", @"wave"] containsObject:extension]) {
                TagLib::RIFF::WAV::File file(&stream, false);
                if (file.isValid()) { SetExportValues(file.ID3v2Tag(), values); saved = file.save(); }
            } else if ([@[@"aif", @"aiff"] containsObject:extension]) {
                TagLib::RIFF::AIFF::File file(&stream, false);
                if (file.isValid()) { SetExportValues(file.tag(), values); saved = file.save(); }
            }
        }
    } catch (const std::exception &) { saved = false; }
      catch (...) { saved = false; }
    if (!saved) ExportTagsError(error, @"No se pudieron guardar las etiquetas adicionales de la copia exportada.");
    return saved;
}

+ (NSDictionary<NSString *, NSArray<NSString *> *> *)readFromURL:(NSURL *)url error:(NSError **)error {
    NSDictionary<NSString *, NSArray<NSString *> *> *values = nil;
    try {
        TagLib::FileStream stream(url.fileSystemRepresentation, true);
        if (stream.isOpen()) {
            NSString *extension = url.pathExtension.lowercaseString;
            if ([extension isEqualToString:@"mp3"]) {
                TagLib::MPEG::File file(&stream, false);
                if (file.isValid()) values = ExportValues(file.ID3v2Tag());
            } else if ([@[@"wav", @"wave"] containsObject:extension]) {
                TagLib::RIFF::WAV::File file(&stream, false);
                if (file.isValid()) values = ExportValues(file.ID3v2Tag());
            } else if ([@[@"aif", @"aiff"] containsObject:extension]) {
                TagLib::RIFF::AIFF::File file(&stream, false);
                if (file.isValid()) values = ExportValues(file.tag());
            }
        }
    } catch (const std::exception &) { values = nil; }
      catch (...) { values = nil; }
    if (!values) ExportTagsError(error, @"No se pudieron comprobar las etiquetas adicionales de la copia exportada.");
    return values;
}
@end
