#include "audio_transcoder.h"

#include <flutter/standard_method_codec.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <wrl/client.h>

#include <cstdint>
#include <cstdio>
#include <thread>
#include <variant>

using Microsoft::WRL::ComPtr;

namespace {

constexpr char kChannelName[] = "io.github.simomagnus.universitynotes/audio";

// Conversione in corso: il risultato da restituire a Flutter e l'esito.
struct AudioJob {
  std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result;
  HRESULT hr = S_OK;
};

std::wstring Utf8ToWide(const std::string& s) {
  if (s.empty()) {
    return std::wstring();
  }
  const int n = MultiByteToWideChar(CP_UTF8, 0, s.data(),
                                    static_cast<int>(s.size()), nullptr, 0);
  if (n <= 0) {
    return std::wstring();
  }
  std::wstring w(static_cast<size_t>(n), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), &w[0],
                      n);
  return w;
}

// Intestazione WAV di 44 byte (PCM 16 bit).
void FillWavHeader(BYTE* h, UINT32 rate, UINT32 channels, UINT32 data_bytes) {
  auto put32 = [h](int at, UINT32 v) {
    h[at] = static_cast<BYTE>(v & 0xFF);
    h[at + 1] = static_cast<BYTE>((v >> 8) & 0xFF);
    h[at + 2] = static_cast<BYTE>((v >> 16) & 0xFF);
    h[at + 3] = static_cast<BYTE>((v >> 24) & 0xFF);
  };
  auto put16 = [h](int at, UINT32 v) {
    h[at] = static_cast<BYTE>(v & 0xFF);
    h[at + 1] = static_cast<BYTE>((v >> 8) & 0xFF);
  };
  auto tag = [h](int at, const char* s) {
    for (int i = 0; i < 4; i++) {
      h[at + i] = static_cast<BYTE>(s[i]);
    }
  };
  const UINT32 block = channels * 2;
  tag(0, "RIFF");
  put32(4, 36 + data_bytes);
  tag(8, "WAVE");
  tag(12, "fmt ");
  put32(16, 16);
  put16(20, 1);
  put16(22, channels);
  put32(24, rate);
  put32(28, rate * block);
  put16(32, block);
  put16(34, 16);
  tag(36, "data");
  put32(40, data_bytes);
}

// Uscita PCM 16 bit del lettore (il lettore di Media Foundation decodifica
// e, da Windows 8, ricampiona l'audio). rate o channels a 0 = come
// l'originale.
HRESULT SetPcmOutput(IMFSourceReader* reader, UINT32 rate, UINT32 channels) {
  ComPtr<IMFMediaType> type;
  HRESULT hr = MFCreateMediaType(&type);
  if (SUCCEEDED(hr)) {
    hr = type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
  }
  if (SUCCEEDED(hr)) {
    hr = type->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
  }
  if (SUCCEEDED(hr)) {
    hr = type->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
  }
  if (SUCCEEDED(hr) && rate != 0) {
    hr = type->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, rate);
  }
  if (SUCCEEDED(hr) && channels != 0) {
    hr = type->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, channels);
  }
  if (SUCCEEDED(hr) && rate != 0 && channels != 0) {
    hr = type->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, channels * 2);
    if (SUCCEEDED(hr)) {
      hr = type->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND,
                           rate * channels * 2);
    }
  }
  if (SUCCEEDED(hr)) {
    hr = reader->SetStreamSelection(
        static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS), FALSE);
  }
  if (SUCCEEDED(hr)) {
    hr = reader->SetStreamSelection(
        static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM), TRUE);
  }
  if (SUCCEEDED(hr)) {
    hr = reader->SetCurrentMediaType(
        static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM), nullptr,
        type.Get());
  }
  return hr;
}

// Formato AAC offerto da Windows più vicino a quello chiesto: stessi
// canali, frequenza uguale o subito superiore, bitrate più vicino.
HRESULT PickAacType(UINT32 rate, UINT32 channels, UINT32 bit_rate,
                    IMFMediaType** out) {
  ComPtr<IMFCollection> types;
  HRESULT hr = MFTranscodeGetAudioOutputAvailableTypes(
      MFAudioFormat_AAC, MFT_ENUM_FLAG_ALL & ~MFT_ENUM_FLAG_FIELDOFUSE,
      nullptr, &types);
  if (FAILED(hr)) {
    return hr;
  }
  DWORD count = 0;
  hr = types->GetElementCount(&count);
  if (FAILED(hr)) {
    return hr;
  }
  ComPtr<IMFMediaType> best;
  uint64_t best_cost[3] = {UINT64_MAX, UINT64_MAX, UINT64_MAX};
  for (DWORD i = 0; i < count; i++) {
    ComPtr<IUnknown> unknown;
    if (FAILED(types->GetElement(i, &unknown))) {
      continue;
    }
    ComPtr<IMFMediaType> type;
    if (FAILED(unknown.As(&type))) {
      continue;
    }
    const UINT32 ch = MFGetAttributeUINT32(type.Get(), MF_MT_AUDIO_NUM_CHANNELS, 0);
    const UINT32 sr =
        MFGetAttributeUINT32(type.Get(), MF_MT_AUDIO_SAMPLES_PER_SECOND, 0);
    const UINT32 bps =
        MFGetAttributeUINT32(type.Get(), MF_MT_AUDIO_AVG_BYTES_PER_SECOND, 0);
    const uint64_t cost[3] = {
        ch == channels ? 0u : (ch > channels ? ch - channels : channels - ch) +
                                  1000u,
        sr >= rate ? static_cast<uint64_t>(sr - rate)
                   : 1000000u + static_cast<uint64_t>(rate - sr),
        static_cast<uint64_t>(bps) * 8 >= bit_rate
            ? static_cast<uint64_t>(bps) * 8 - bit_rate
            : static_cast<uint64_t>(bit_rate) - static_cast<uint64_t>(bps) * 8,
    };
    bool better = false;
    for (int k = 0; k < 3; k++) {
      if (cost[k] != best_cost[k]) {
        better = cost[k] < best_cost[k];
        break;
      }
    }
    if (better || !best) {
      best = type;
      for (int k = 0; k < 3; k++) {
        best_cost[k] = cost[k];
      }
    }
  }
  if (!best) {
    return MF_E_TRANSCODE_NO_MATCHING_ENCODER;
  }
  *out = best.Detach();
  return S_OK;
}

}  // namespace

HRESULT DecodeToWav(const std::wstring& input, const std::wstring& output,
                    UINT32 sample_rate, UINT32 channels) {
  ComPtr<IMFSourceReader> reader;
  HRESULT hr = MFCreateSourceReaderFromURL(input.c_str(), nullptr, &reader);
  if (SUCCEEDED(hr)) {
    hr = SetPcmOutput(reader.Get(), sample_rate, channels);
  }
  ComPtr<IMFMediaType> actual;
  if (SUCCEEDED(hr)) {
    hr = reader->GetCurrentMediaType(
        static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM), &actual);
  }
  if (FAILED(hr)) {
    return hr;
  }
  const UINT32 rate = MFGetAttributeUINT32(
      actual.Get(), MF_MT_AUDIO_SAMPLES_PER_SECOND, sample_rate);
  const UINT32 ch =
      MFGetAttributeUINT32(actual.Get(), MF_MT_AUDIO_NUM_CHANNELS, channels);

  HANDLE file = CreateFileW(output.c_str(), GENERIC_WRITE, 0, nullptr,
                            CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return HRESULT_FROM_WIN32(GetLastError());
  }
  BYTE header[44] = {};
  FillWavHeader(header, rate, ch, 0);
  DWORD written = 0;
  if (!WriteFile(file, header, sizeof(header), &written, nullptr)) {
    hr = HRESULT_FROM_WIN32(GetLastError());
  }
  uint64_t total = 0;
  while (SUCCEEDED(hr)) {
    DWORD flags = 0;
    ComPtr<IMFSample> sample;
    hr = reader->ReadSample(
        static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM), 0, nullptr,
        &flags, nullptr, &sample);
    if (FAILED(hr) || (flags & MF_SOURCE_READERF_ENDOFSTREAM)) {
      break;
    }
    if (!sample) {
      continue;
    }
    ComPtr<IMFMediaBuffer> buffer;
    hr = sample->ConvertToContiguousBuffer(&buffer);
    if (FAILED(hr)) {
      break;
    }
    BYTE* data = nullptr;
    DWORD length = 0;
    hr = buffer->Lock(&data, nullptr, &length);
    if (FAILED(hr)) {
      break;
    }
    if (!WriteFile(file, data, length, &written, nullptr)) {
      hr = HRESULT_FROM_WIN32(GetLastError());
    }
    buffer->Unlock();
    total += length;
  }
  if (SUCCEEDED(hr) && total > 0xFFFFFFFFull - 44) {
    hr = E_FAIL;  // oltre i 4 GB del formato WAV
  }
  if (SUCCEEDED(hr)) {
    FillWavHeader(header, rate, ch, static_cast<UINT32>(total));
    SetFilePointer(file, 0, nullptr, FILE_BEGIN);
    if (!WriteFile(file, header, sizeof(header), &written, nullptr)) {
      hr = HRESULT_FROM_WIN32(GetLastError());
    }
  }
  CloseHandle(file);
  if (SUCCEEDED(hr) && total == 0) {
    hr = MF_E_INVALID_STREAM_DATA;
  }
  if (FAILED(hr)) {
    DeleteFileW(output.c_str());
  }
  return hr;
}

HRESULT TranscodeToAac(const std::wstring& input, const std::wstring& output,
                       UINT32 bit_rate) {
  ComPtr<IMFSourceReader> reader;
  HRESULT hr = MFCreateSourceReaderFromURL(input.c_str(), nullptr, &reader);
  ComPtr<IMFMediaType> native;
  if (SUCCEEDED(hr)) {
    hr = reader->GetNativeMediaType(
        static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM), 0, &native);
  }
  if (FAILED(hr)) {
    return hr;
  }
  const UINT32 in_rate =
      MFGetAttributeUINT32(native.Get(), MF_MT_AUDIO_SAMPLES_PER_SECOND, 16000);

  ComPtr<IMFMediaType> aac;
  hr = PickAacType(in_rate, 1, bit_rate, &aac);
  UINT32 out_rate = 44100;
  UINT32 out_channels = 1;
  if (SUCCEEDED(hr)) {
    out_rate =
        MFGetAttributeUINT32(aac.Get(), MF_MT_AUDIO_SAMPLES_PER_SECOND, 44100);
    out_channels = MFGetAttributeUINT32(aac.Get(), MF_MT_AUDIO_NUM_CHANNELS, 1);
    // il lettore ricampiona alla frequenza accettata dal codificatore
    hr = SetPcmOutput(reader.Get(), out_rate, out_channels);
  }
  ComPtr<IMFMediaType> pcm;
  if (SUCCEEDED(hr)) {
    hr = reader->GetCurrentMediaType(
        static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM), &pcm);
  }
  ComPtr<IMFAttributes> attributes;
  if (SUCCEEDED(hr)) {
    hr = MFCreateAttributes(&attributes, 1);
  }
  if (SUCCEEDED(hr)) {
    hr = attributes->SetGUID(MF_TRANSCODE_CONTAINERTYPE,
                             MFTranscodeContainerType_MPEG4);
  }
  ComPtr<IMFSinkWriter> writer;
  if (SUCCEEDED(hr)) {
    hr = MFCreateSinkWriterFromURL(output.c_str(), nullptr, attributes.Get(),
                                   &writer);
  }
  DWORD stream = 0;
  if (SUCCEEDED(hr)) {
    hr = writer->AddStream(aac.Get(), &stream);
  }
  if (SUCCEEDED(hr)) {
    hr = writer->SetInputMediaType(stream, pcm.Get(), nullptr);
  }
  if (SUCCEEDED(hr)) {
    hr = writer->BeginWriting();
  }
  bool any = false;
  while (SUCCEEDED(hr)) {
    DWORD flags = 0;
    LONGLONG time = 0;
    ComPtr<IMFSample> sample;
    hr = reader->ReadSample(
        static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM), 0, nullptr,
        &flags, &time, &sample);
    if (FAILED(hr) || (flags & MF_SOURCE_READERF_ENDOFSTREAM)) {
      break;
    }
    if (!sample) {
      continue;
    }
    hr = writer->WriteSample(stream, sample.Get());
    any = true;
  }
  if (SUCCEEDED(hr) && writer) {
    hr = writer->Finalize();
  }
  writer.Reset();
  if (SUCCEEDED(hr) && !any) {
    hr = MF_E_INVALID_STREAM_DATA;
  }
  if (FAILED(hr)) {
    DeleteFileW(output.c_str());
  }
  return hr;
}

AudioTranscoderChannel::AudioTranscoderChannel(
    flutter::BinaryMessenger* messenger, HWND window)
    : window_(window) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, kChannelName, &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) { HandleMethodCall(call, std::move(result)); });
}

AudioTranscoderChannel::~AudioTranscoderChannel() {
  if (channel_) {
    channel_->SetMethodCallHandler(nullptr);
  }
}

void AudioTranscoderChannel::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();
  if (method != "toM4a" && method != "toWav") {
    result->NotImplemented();
    return;
  }
  const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
  if (!args) {
    result->Error("argomenti", "Argomenti mancanti");
    return;
  }
  auto text = [args](const char* key) -> std::wstring {
    const auto it = args->find(flutter::EncodableValue(std::string(key)));
    if (it == args->end()) {
      return std::wstring();
    }
    const auto* v = std::get_if<std::string>(&it->second);
    return v ? Utf8ToWide(*v) : std::wstring();
  };
  auto number = [args](const char* key, UINT32 fallback) -> UINT32 {
    const auto it = args->find(flutter::EncodableValue(std::string(key)));
    if (it == args->end()) {
      return fallback;
    }
    if (const auto* v = std::get_if<int32_t>(&it->second)) {
      return *v > 0 ? static_cast<UINT32>(*v) : fallback;
    }
    if (const auto* v = std::get_if<int64_t>(&it->second)) {
      return *v > 0 ? static_cast<UINT32>(*v) : fallback;
    }
    return fallback;
  };
  const std::wstring input = text("input");
  const std::wstring output = text("output");
  if (input.empty() || output.empty()) {
    result->Error("argomenti", "File di ingresso o di uscita mancante");
    return;
  }
  const bool to_m4a = method == "toM4a";
  const UINT32 bit_rate = number("bitRate", 48000);
  const UINT32 rate = number("sampleRate", 16000);
  const UINT32 channels = number("channels", 1);

  AudioJob* job = new AudioJob();
  job->result = std::move(result);
  const HWND window = window_;
  std::thread([job, window, to_m4a, input, output, bit_rate, rate,
               channels]() {
    const HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    HRESULT hr = MFStartup(MF_VERSION, MFSTARTUP_LITE);
    if (SUCCEEDED(hr)) {
      hr = to_m4a ? TranscodeToAac(input, output, bit_rate)
                  : DecodeToWav(input, output, rate, channels);
      MFShutdown();
    }
    if (SUCCEEDED(com)) {
      CoUninitialize();
    }
    job->hr = hr;
    // Se la finestra non c'è più l'app si sta chiudendo: nessuna risposta.
    PostMessage(window, kAudioJobDoneMessage, 0,
                reinterpret_cast<LPARAM>(job));
  }).detach();
}

bool AudioTranscoderChannel::HandleMessage(UINT message, WPARAM wparam,
                                           LPARAM lparam) {
  if (message != kAudioJobDoneMessage) {
    return false;
  }
  AudioJob* job = reinterpret_cast<AudioJob*>(lparam);
  if (!job) {
    return true;
  }
  if (SUCCEEDED(job->hr)) {
    job->result->Success(flutter::EncodableValue(true));
  } else {
    char code[32];
    snprintf(code, sizeof(code), "0x%08lX",
             static_cast<unsigned long>(job->hr));
    job->result->Error("conversione",
                       std::string("Media Foundation non ha convertito "
                                   "l'audio (") +
                           code + ")");
  }
  delete job;
  return true;
}
