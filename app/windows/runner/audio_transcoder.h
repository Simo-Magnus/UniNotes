#ifndef RUNNER_AUDIO_TRANSCODER_H_
#define RUNNER_AUDIO_TRANSCODER_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>
#include <string>

// Conversioni audio delle registrazioni con Media Foundation (di sistema,
// nessun programma da scaricare):
// - "toM4a": WAV -> .m4a AAC (formato finale delle registrazioni);
// - "toWav": qualsiasi audio leggibile da Windows (.m4a, .wav, .mp3, .flac
//   su Windows 10+) -> WAV PCM 16 bit a frequenza e canali scelti (16 kHz
//   mono per Whisper).
// Il lavoro gira in un thread separato; l'esito torna al thread della
// finestra con il messaggio kAudioJobDoneMessage (le risposte ai canali di
// Flutter vanno date dal thread della piattaforma).
constexpr UINT kAudioJobDoneMessage = WM_APP + 0x41;

class AudioTranscoderChannel {
 public:
  AudioTranscoderChannel(flutter::BinaryMessenger* messenger, HWND window);
  ~AudioTranscoderChannel();

  // Da chiamare dal gestore dei messaggi della finestra: true se il
  // messaggio era l'esito di una conversione.
  bool HandleMessage(UINT message, WPARAM wparam, LPARAM lparam);

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  HWND window_;
};

// WAV (o altro audio) -> MPEG-4 AAC mono con il formato offerto da Windows
// più vicino: frequenza uguale o subito superiore, bitrate più vicino a
// bit_rate.
HRESULT TranscodeToAac(const std::wstring& input, const std::wstring& output,
                       UINT32 bit_rate);

// Audio -> WAV PCM 16 bit, sample_rate Hz, channels canali.
HRESULT DecodeToWav(const std::wstring& input, const std::wstring& output,
                    UINT32 sample_rate, UINT32 channels);

#endif  // RUNNER_AUDIO_TRANSCODER_H_
