#include <aifffile.h>
#include <algorithm>
#include <cerrno>
#include <cmath>
#include <cstdio>
#include <fileref.h>
#include <id3v2tag.h>
#include <jni.h>
#include <lame.h>
#include <map>
#include <memory>
#include <mpegfile.h>
#include <mutex>
#include <stdexcept>
#include <string>
#include <sys/stat.h>
#include <textidentificationframe.h>
#include <tiostream.h>
#include <tpropertymap.h>
#include <tvariant.h>
#include <unistd.h>
#include <vector>
#include <wavfile.h>
using namespace TagLib;
namespace {
void fail(JNIEnv *e, const std::exception &x) {
  if (!e->ExceptionCheck())
    e->ThrowNew(e->FindClass("java/io/IOException"), x.what());
}
std::string utf8(JNIEnv *e, jstring s) {
  if (!s)
    throw std::runtime_error("Missing text");
  auto cls = e->FindClass("java/lang/String");
  auto encoding = e->NewStringUTF("UTF-8");
  auto bytes = (jbyteArray)e->CallObjectMethod(
      s, e->GetMethodID(cls, "getBytes", "(Ljava/lang/String;)[B"), encoding);
  if (e->ExceptionCheck() || !bytes)
    throw std::runtime_error("Invalid UTF-8 text");
  const auto n = e->GetArrayLength(bytes);
  if (n > 1024 * 1024)
    throw std::runtime_error("Metadata field too large");
  std::string out(n, '\0');
  e->GetByteArrayRegion(bytes, 0, n, reinterpret_cast<jbyte *>(out.data()));
  e->DeleteLocalRef(bytes);
  e->DeleteLocalRef(encoding);
  e->DeleteLocalRef(cls);
  return out;
}
jstring javaString(JNIEnv *e, const std::string &s) {
  auto bytes = e->NewByteArray(s.size());
  e->SetByteArrayRegion(bytes, 0, s.size(),
                        reinterpret_cast<const jbyte *>(s.data()));
  auto cls = e->FindClass("java/lang/String");
  auto enc = e->NewStringUTF("UTF-8");
  auto out = (jstring)e->NewObject(
      cls, e->GetMethodID(cls, "<init>", "([BLjava/lang/String;)V"), bytes,
      enc);
  e->DeleteLocalRef(bytes);
  e->DeleteLocalRef(cls);
  e->DeleteLocalRef(enc);
  return out;
}
std::string quote(const std::string &s) {
  std::string out = "\"";
  const char *hex = "0123456789abcdef";
  for (unsigned char c : s) {
    if (c == '"' || c == '\\') {
      out += '\\';
      out += c;
    } else if (c < 32) {
      out += "\\u00";
      out += hex[c >> 4];
      out += hex[c & 15];
    } else
      out += c;
  }
  return out + '"';
}
class DescriptorStream final : public IOStream {
  int fd_;
  offset_t base_, size_, position_ = 0;
  std::string name_;

public:
  DescriptorStream(int fd, offset_t base, offset_t length, std::string ext)
      : fd_(dup(fd)), base_(base), name_("audio." + ext) {
    struct stat st{};
    if (fd_ < 0 || fstat(fd_, &st) || !S_ISREG(st.st_mode) || base < 0 ||
        base > st.st_size) {
      if (fd_ >= 0)
        close(fd_);
      fd_ = -1;
      throw std::runtime_error("Audio descriptor is not seekable");
    }
    size_ = length < 0 ? st.st_size - base
                       : std::min<offset_t>(length, st.st_size - base);
    if (size_ < 0)
      throw std::runtime_error("Invalid audio range");
  }
  ~DescriptorStream() override {
    if (fd_ >= 0)
      close(fd_);
  }
  FileName name() const override { return name_.c_str(); }
  ByteVector readBlock(size_t count) override {
    if (position_ < 0 || position_ >= size_)
      return {};
    count = std::min<size_t>(count, size_ - position_);
    if (count > 32 * 1024 * 1024)
      throw std::runtime_error("Metadata allocation exceeds limit");
    ByteVector bytes(count, 0);
    size_t done = 0;
    while (done < count) {
      auto n = pread(fd_, bytes.data() + done, count - done,
                     base_ + position_ + done);
      if (n < 0 && errno == EINTR)
        continue;
      if (n < 0)
        throw std::runtime_error("Cannot read audio metadata");
      if (n == 0)
        break;
      done += n;
    }
    bytes.resize(done);
    position_ += done;
    return bytes;
  }
  void writeBlock(const ByteVector &) override {
    throw std::runtime_error("Read-only audio descriptor");
  }
  void insert(const ByteVector &, offset_t, size_t) override {
    throw std::runtime_error("Read-only audio descriptor");
  }
  void removeBlock(offset_t, size_t) override {
    throw std::runtime_error("Read-only audio descriptor");
  }
  bool readOnly() const override { return true; }
  bool isOpen() const override { return fd_ >= 0; }
  void seek(offset_t n, Position p) override {
    auto origin = p == Beginning ? 0 : p == Current ? position_ : size_;
    if (n < -origin || n > size_ - origin)
      position_ = size_;
    else
      position_ = origin + n;
  }
  offset_t tell() const override { return position_; }
  offset_t length() override { return size_; }
  void truncate(offset_t) override {
    throw std::runtime_error("Read-only audio descriptor");
  }
};
ID3v2::Tag *id3(FileRef &ref, bool create) {
  if (auto f = dynamic_cast<MPEG::File *>(ref.file()))
    return f->ID3v2Tag(create);
  if (auto f = dynamic_cast<RIFF::WAV::File *>(ref.file()))
    return f->ID3v2Tag();
  if (auto f = dynamic_cast<RIFF::AIFF::File *>(ref.file()))
    return f->tag();
  return nullptr;
}
using Custom = std::map<std::string, StringList>;
Custom custom(FileRef &ref) {
  Custom out;
  if (auto tag = id3(ref, false))
    for (auto frame : tag->frameList("TXXX"))
      if (auto text =
              dynamic_cast<ID3v2::UserTextIdentificationFrame *>(frame)) {
        auto values = text->fieldList();
        if (!values.isEmpty())
          values.erase(values.begin());
        out[text->description().to8Bit(true)] = values;
      }
  return out;
}
std::string listJson(const StringList &values) {
  std::string out = "[";
  bool first = true;
  for (const auto &v : values) {
    if (!first)
      out += ',';
    first = false;
    out += quote(v.to8Bit(true));
  }
  return out + "]";
}
void valid(FileRef &ref) {
  if (ref.isNull() || !ref.file()->isValid())
    throw std::runtime_error("Unsupported or damaged audio file");
}
struct Encoder {
  lame_t lame = nullptr;
  FILE *file = nullptr;
  int channels;
  std::string path;
  ~Encoder() {
    if (lame)
      lame_close(lame);
    if (file)
      fclose(file);
  }
};
std::mutex encMutex;
std::map<jlong, std::unique_ptr<Encoder>> encoders;
jlong nextId = 1;
void encoded(Encoder &e, int count, const unsigned char *bytes) {
  if (count < 0)
    throw std::runtime_error("MP3 encoding failed");
  if (count && fwrite(bytes, 1, count, e.file) != static_cast<size_t>(count))
    throw std::runtime_error("Cannot write MP3 audio");
}
} // namespace
extern "C" JNIEXPORT jstring JNICALL
Java_com_tonyredondo_sonora_NativeAudio_inspect(JNIEnv *e, jobject, jint fd,
                                                jlong offset, jlong length,
                                                jstring extension) {
  try {
    DescriptorStream stream(fd, offset, length, utf8(e, extension));
    FileRef ref(&stream, true, AudioProperties::Fast);
    valid(ref);
    std::string out = "{\"fields\":{";
    bool first = true;
    for (auto p : ref.properties()) {
      if (!first)
        out += ',';
      first = false;
      out += quote(p.first.to8Bit(true)) + ":" + listJson(p.second);
    }
    out += "},\"custom\":{";
    first = true;
    for (auto p : custom(ref)) {
      if (!first)
        out += ',';
      first = false;
      out += quote(p.first) + ":" + listJson(p.second);
    }
    out += '}';
    if (auto p = ref.audioProperties())
      out += ",\"durationMs\":" + std::to_string(p->lengthInMilliseconds()) +
             ",\"sampleRate\":" + std::to_string(p->sampleRate()) +
             ",\"channels\":" + std::to_string(p->channels()) +
             ",\"bitrate\":" + std::to_string(p->bitrate());
    out += '}';
    if (out.size() > 4 * 1024 * 1024)
      throw std::runtime_error("Metadata too large");
    return javaString(e, out);
  } catch (const std::exception &x) {
    fail(e, x);
    return nullptr;
  }
}
extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_tonyredondo_sonora_NativeAudio_artwork(JNIEnv *e, jobject, jint fd,
                                                jlong offset, jlong length,
                                                jstring extension) {
  try {
    DescriptorStream stream(fd, offset, length, utf8(e, extension));
    FileRef ref(&stream, false);
    valid(ref);
    auto pictures = ref.complexProperties("PICTURE");
    ByteVector selected;
    for (const auto &p : pictures) {
      auto bytes = p["data"].toByteVector();
      if (bytes.size() > 10 * 1024 * 1024)
        continue;
      if (selected.isEmpty() || p["pictureType"].toString() == "Front Cover")
        selected = bytes;
      if (p["pictureType"].toString() == "Front Cover")
        break;
    }
    if (selected.isEmpty())
      return nullptr;
    auto out = e->NewByteArray(selected.size());
    e->SetByteArrayRegion(out, 0, selected.size(),
                          reinterpret_cast<const jbyte *>(selected.data()));
    return out;
  } catch (const std::exception &x) {
    fail(e, x);
    return nullptr;
  }
}
extern "C" JNIEXPORT void JNICALL
Java_com_tonyredondo_sonora_NativeAudio_writeTags(JNIEnv *e, jobject,
                                                  jstring path,
                                                  jobjectArray names,
                                                  jobjectArray values,
                                                  jbyteArray artwork) {
  try {
    auto filePath = utf8(e, path);
    FileRef ref(filePath.c_str(), false);
    valid(ref);
    auto props = ref.properties();
    auto extra = custom(ref);
    int n = e->GetArrayLength(names);
    if (n != e->GetArrayLength(values) || n > 256)
      throw std::runtime_error("Invalid metadata patch");
    for (int i = 0; i < n; i++) {
      auto name = (jstring)e->GetObjectArrayElement(names, i);
      auto key = utf8(e, name);
      e->DeleteLocalRef(name);
      auto array = (jobjectArray)e->GetObjectArrayElement(values, i);
      StringList list;
      int count = e->GetArrayLength(array);
      if (count > 100)
        throw std::runtime_error("Too many metadata values");
      for (int j = 0; j < count; j++) {
        auto item = (jstring)e->GetObjectArrayElement(array, j);
        list.append(String(utf8(e, item), String::UTF8));
        e->DeleteLocalRef(item);
      }
      e->DeleteLocalRef(array);
      props.replace(String(key, String::UTF8), list);
      extra[key] = list;
    }
    auto unsupported = ref.setProperties(props);
    if (!unsupported.isEmpty())
      throw std::runtime_error(
          "Audio format cannot store these metadata fields");
    if (auto tag = id3(ref, true)) { // Reapply exact TXXX case and multi-values
                                     // after the generic property mapping.
      for (auto it = extra.begin(); it != extra.end(); ++it) {
        String description(it->first, String::UTF8);
        auto frames = tag->frameList("TXXX");
        for (auto frame : frames)
          if (auto text =
                  dynamic_cast<ID3v2::UserTextIdentificationFrame *>(frame))
            if (text->description() == description ||
                text->description().upper() == description.upper())
              tag->removeFrame(frame, true);
        // Standard property names already have dedicated frames; custom
        // descriptions must retain their case.
        if (it->second.isEmpty() || it->first == "TITLE" ||
            it->first == "ARTIST" || it->first == "ALBUM" ||
            it->first == "GENRE" || it->first == "LYRICS" ||
            it->first == "TRACKNUMBER" || it->first == "DATE" ||
            it->first == "ALBUMARTIST")
          continue;
        auto text = new ID3v2::UserTextIdentificationFrame(String::UTF8);
        text->setDescription(description);
        text->setText(it->second);
        tag->addFrame(text);
      }
    }
    if (artwork) {
      int size = e->GetArrayLength(artwork);
      if (size <= 0 || size > 10 * 1024 * 1024)
        throw std::runtime_error("Invalid artwork size");
      ByteVector data(size, 0);
      e->GetByteArrayRegion(artwork, 0, size,
                            reinterpret_cast<jbyte *>(data.data()));
      VariantMap pic;
      pic.insert("data", Variant(data));
      pic.insert("pictureType", Variant("Front Cover"));
      pic.insert("mimeType",
                 Variant(size >= 8 && data[0] == char(0x89) ? "image/png"
                                                            : "image/jpeg"));
      auto pictures = ref.complexProperties("PICTURE");
      List<VariantMap> keep;
      for (const auto &p : pictures)
        if (p["pictureType"].toString() != "Front Cover")
          keep.append(p);
      keep.append(pic);
      if (!ref.setComplexProperties("PICTURE", keep))
        throw std::runtime_error("Audio format cannot store artwork");
    }
    bool ok;
    if (auto mp3 = dynamic_cast<MPEG::File *>(ref.file()))
      ok = mp3->save(MPEG::File::AllTags, File::StripNone, ID3v2::v4,
                     File::DoNotDuplicate);
    else
      ok = ref.save();
    if (!ok)
      throw std::runtime_error("Cannot save audio metadata");
  } catch (const std::exception &x) {
    fail(e, x);
  }
}
extern "C" JNIEXPORT jint JNICALL
Java_com_tonyredondo_sonora_NativeAudio_copyPictures(JNIEnv *e, jobject,
                                                     jint fd, jlong offset,
                                                     jlong length,
                                                     jstring extension,
                                                     jstring destination) {
  try {
    DescriptorStream stream(fd, offset, length, utf8(e, extension));
    FileRef source(&stream, false);
    if (source.isNull() || !source.file()->isValid())
      return 0;
    auto pictures = source.complexProperties("PICTURE");
    if (pictures.isEmpty())
      return 0;
    size_t total = 0;
    for (const auto &picture : pictures) {
      const auto bytes = picture["data"].toByteVector();
      total += bytes.size();
      if (bytes.size() > 10 * 1024 * 1024 || total > 32 * 1024 * 1024)
        throw std::runtime_error("Embedded artwork exceeds export limit");
    }
    FileRef target(utf8(e, destination).c_str(), false);
    valid(target);
    if (!target.setComplexProperties("PICTURE", pictures) || !target.save())
      throw std::runtime_error("Cannot preserve embedded artwork");
    return pictures.size();
  } catch (const std::exception &x) {
    fail(e, x);
    return 0;
  }
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_tonyredondo_sonora_NativeAudio_encoderOpen(JNIEnv *e, jobject,
                                                    jstring path, jint rate,
                                                    jint channels) {
  try {
    if (channels < 1 || channels > 2 || rate < 8000 || rate > 384000)
      throw std::runtime_error("MP3 export supports mono or stereo audio");
    auto encoder = std::make_unique<Encoder>();
    encoder->channels = channels;
    encoder->path = utf8(e, path);
    encoder->lame = lame_init();
    if (!encoder->lame)
      throw std::runtime_error("Cannot create MP3 encoder");
    lame_set_num_channels(encoder->lame, channels);
    lame_set_in_samplerate(encoder->lame, rate);
    lame_set_out_samplerate(
        encoder->lame,
        rate == 32000 || rate == 44100 || rate == 48000 ? rate : 44100);
    lame_set_brate(encoder->lame, 320);
    lame_set_VBR(encoder->lame, vbr_off);
    lame_set_quality(encoder->lame, 2);
    lame_set_bWriteVbrTag(encoder->lame, 1);
    lame_set_write_id3tag_automatic(encoder->lame, 0);
    if (lame_init_params(encoder->lame) < 0)
      throw std::runtime_error("Cannot configure MP3 encoder");
    encoder->file = fopen(encoder->path.c_str(), "wb+");
    if (!encoder->file)
      throw std::runtime_error("Cannot create MP3 file");
    std::lock_guard<std::mutex> lock(encMutex);
    auto id = nextId++;
    encoders.emplace(id, std::move(encoder));
    return id;
  } catch (const std::exception &x) {
    fail(e, x);
    return 0;
  }
}
extern "C" JNIEXPORT void JNICALL
Java_com_tonyredondo_sonora_NativeAudio_encoderWrite(JNIEnv *e, jobject,
                                                     jlong handle,
                                                     jfloatArray pcm,
                                                     jint frames) {
  try {
    std::lock_guard<std::mutex> lock(encMutex);
    auto it = encoders.find(handle);
    if (it == encoders.end())
      throw std::runtime_error("MP3 encoder closed");
    auto &enc = *it->second;
    if (frames < 0 || frames > 65536 ||
        static_cast<int64_t>(frames) * enc.channels > e->GetArrayLength(pcm))
      throw std::runtime_error("Invalid PCM block");
    std::vector<float> input(frames * enc.channels);
    e->GetFloatArrayRegion(pcm, 0, input.size(), input.data());
    for (float f : input)
      if (!std::isfinite(f) || std::abs(f) > 1.001f)
        throw std::runtime_error("Invalid PCM samples");
    std::vector<unsigned char> out(1.25 * frames + 7200);
    int count;
    if (enc.channels == 2)
      count = lame_encode_buffer_interleaved_ieee_float(
          enc.lame, input.data(), frames, out.data(), out.size());
    else
      count = lame_encode_buffer_ieee_float(
          enc.lame, input.data(), input.data(), frames, out.data(), out.size());
    encoded(enc, count, out.data());
  } catch (const std::exception &x) {
    fail(e, x);
  }
}
extern "C" JNIEXPORT void JNICALL
Java_com_tonyredondo_sonora_NativeAudio_encoderFinish(JNIEnv *e, jobject,
                                                      jlong handle) {
  try {
    std::unique_ptr<Encoder> enc;
    {
      std::lock_guard<std::mutex> lock(encMutex);
      auto it = encoders.find(handle);
      if (it == encoders.end())
        throw std::runtime_error("MP3 encoder closed");
      enc = std::move(it->second);
      encoders.erase(it);
    }
    std::vector<unsigned char> out(16384);
    encoded(*enc, lame_encode_flush(enc->lame, out.data(), out.size()),
            out.data());
    auto n = lame_get_lametag_frame(enc->lame, out.data(), out.size());
    if (n > out.size() || fseek(enc->file, 0, SEEK_SET) ||
        fwrite(out.data(), 1, n, enc->file) != n || fflush(enc->file) ||
        fsync(fileno(enc->file)))
      throw std::runtime_error("Cannot finalize MP3 file");
  } catch (const std::exception &x) {
    fail(e, x);
  }
}
extern "C" JNIEXPORT void JNICALL
Java_com_tonyredondo_sonora_NativeAudio_encoderAbort(JNIEnv *, jobject,
                                                     jlong handle) {
  std::lock_guard<std::mutex> lock(encMutex);
  encoders.erase(handle);
}
