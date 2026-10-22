#include "live_speech.h"

#include <flutter/standard_method_codec.h>
#include <roapi.h>
#include <windows.foundation.collections.h>
#include <windows.globalization.h>
#include <wrl/event.h>
#include <wrl/wrappers/corewrappers.h>

#include <cstdint>
#include <variant>

using ABI::Windows::Foundation::AsyncStatus;
using ABI::Windows::Foundation::IClosable;
using ABI::Windows::Foundation::IAsyncAction;
using ABI::Windows::Foundation::IAsyncActionCompletedHandler;
using ABI::Windows::Foundation::IAsyncOperation;
using ABI::Windows::Foundation::IAsyncOperationCompletedHandler;
using ABI::Windows::Foundation::ITypedEventHandler;
using ABI::Windows::Foundation::TimeSpan;
using ABI::Windows::Foundation::Collections::IVectorView;
using ABI::Windows::Globalization::ILanguage;
using ABI::Windows::Globalization::ILanguageFactory;
using ABI::Windows::Globalization::Language;
using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;
using Microsoft::WRL::FtmBase;
using Microsoft::WRL::Implements;
using Microsoft::WRL::RuntimeClassFlags;
using Microsoft::WRL::ClassicCom;
using Microsoft::WRL::Wrappers::HString;
using Microsoft::WRL::Wrappers::HStringReference;

namespace sr = ABI::Windows::Media::SpeechRecognition;

namespace {

constexpr char kChannelName[] = "io.github.simomagnus.universitynotes/speech";

// «Riconoscimento vocale online» disattivato (SPERR_SPEECH_PRIVACY_POLICY_NOT_ACCEPTED).
constexpr HRESULT kPrivacyNotAccepted = static_cast<HRESULT>(0x80045509L);

// Evento del riconoscitore portato al thread della finestra.
enum class EventKind {
  kHypothesis,  // testo provvisorio
  kResult,      // frase definitiva
  kCompleted,   // la sessione continua si è chiusa
  kCompiled,    // vincoli compilati (status)
  kStarted,     // StartAsync finito (hr)
};

struct SpeechEvent {
  int session = 0;
  EventKind kind = EventKind::kResult;
  std::string text;
  HRESULT hr = S_OK;
  int status = 0;
};

std::string ToUtf8(HSTRING h) {
  UINT32 len = 0;
  const wchar_t* raw = WindowsGetStringRawBuffer(h, &len);
  if (raw == nullptr || len == 0) return std::string();
  const int n = WideCharToMultiByte(CP_UTF8, 0, raw, static_cast<int>(len),
                                    nullptr, 0, nullptr, nullptr);
  if (n <= 0) return std::string();
  std::string out(static_cast<size_t>(n), '\0');
  WideCharToMultiByte(CP_UTF8, 0, raw, static_cast<int>(len), &out[0], n,
                      nullptr, nullptr);
  return out;
}

std::wstring ToWide(const std::string& s) {
  if (s.empty()) return std::wstring();
  const int n = MultiByteToWideChar(CP_UTF8, 0, s.data(),
                                    static_cast<int>(s.size()), nullptr, 0);
  if (n <= 0) return std::wstring();
  std::wstring w(static_cast<size_t>(n), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), &w[0],
                      n);
  return w;
}

void Post(HWND window, SpeechEvent* e) {
  if (!PostMessage(window, kLiveSpeechMessage, 0,
                   reinterpret_cast<LPARAM>(e))) {
    delete e;
  }
}

const std::string* ReadString(const flutter::EncodableMap& args,
                              const char* key) {
  const auto it = args.find(flutter::EncodableValue(key));
  if (it == args.end()) return nullptr;
  return std::get_if<std::string>(&it->second);
}

int ReadInt(const flutter::EncodableMap& args, const char* key, int fallback) {
  const auto it = args.find(flutter::EncodableValue(key));
  if (it == args.end()) return fallback;
  if (const auto* v = std::get_if<int32_t>(&it->second)) return *v;
  if (const auto* v = std::get_if<int64_t>(&it->second)) {
    return static_cast<int>(*v);
  }
  return fallback;
}

// Lingua di Windows (es. "it-IT").
HRESULT CreateLanguage(const std::string& tag, ComPtr<ILanguage>* out) {
  ComPtr<ILanguageFactory> factory;
  HRESULT hr = RoGetActivationFactory(
      HStringReference(RuntimeClass_Windows_Globalization_Language).Get(),
      IID_PPV_ARGS(&factory));
  if (FAILED(hr)) return hr;
  const std::wstring w = ToWide(tag);
  HString h;
  hr = h.Set(w.c_str(), static_cast<unsigned int>(w.size()));
  if (FAILED(hr)) return hr;
  return factory->CreateLanguage(h.Get(), out->ReleaseAndGetAddressOf());
}

// La dettatura di Windows supporta la lingua [tag] (anche solo la lingua
// senza regione, es. "it").
bool DictationSupports(const std::string& tag) {
  ComPtr<sr::ISpeechRecognizerStatics> statics;
  if (FAILED(RoGetActivationFactory(
          HStringReference(RuntimeClass_Windows_Media_SpeechRecognition_SpeechRecognizer)
              .Get(),
          IID_PPV_ARGS(&statics)))) {
    return false;
  }
  ComPtr<IVectorView<Language*>> langs;
  if (FAILED(statics->get_SupportedTopicLanguages(&langs)) || !langs) {
    return false;
  }
  UINT32 n = 0;
  langs->get_Size(&n);
  const std::string want = tag.substr(0, tag.find('-'));
  for (UINT32 i = 0; i < n; i++) {
    ComPtr<ILanguage> l;
    if (FAILED(langs->GetAt(i, &l)) || !l) continue;
    HString h;
    if (FAILED(l->get_LanguageTag(h.GetAddressOf()))) continue;
    const std::string have = ToUtf8(h.Get());
    if (_stricmp(have.c_str(), tag.c_str()) == 0) return true;
    if (_stricmp(have.substr(0, have.find('-')).c_str(), want.c_str()) == 0) {
      return true;
    }
  }
  return false;
}

// «Riconoscimento vocale online» (Impostazioni → Privacy e sicurezza → Voce)
// attivo: Windows lo scrive in HasAccepted = 1. Senza, la dettatura libera
// non parte (SPERR_SPEECH_PRIVACY_POLICY_NOT_ACCEPTED), anche se i
// riconoscitori offline della lingua sono installati: quelli servono solo
// ai comandi con una grammatica, non alla dettatura.
bool OnlineSpeechAccepted() {
  DWORD value = 0;
  DWORD size = sizeof(value);
  const LSTATUS st = RegGetValueW(
      HKEY_CURRENT_USER,
      L"Software\\Microsoft\\Speech_OneCore\\Settings\\OnlineSpeechPrivacy",
      L"HasAccepted", RRF_RT_REG_DWORD, nullptr, &value, &size);
  return st == ERROR_SUCCESS && value == 1;
}

}  // namespace

LiveSpeechChannel::LiveSpeechChannel(flutter::BinaryMessenger* messenger,
                                     HWND window)
    : window_(window) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, kChannelName, &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    HandleMethodCall(call, std::move(result));
  });
}

LiveSpeechChannel::~LiveSpeechChannel() {
  if (channel_) channel_->SetMethodCallHandler(nullptr);
  running_ = false;
  Release();
}

void LiveSpeechChannel::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<Result> result) {
  const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
  const std::string& method = call.method_name();
  if (method == "support") {
    const std::string* loc = args ? ReadString(*args, "locale") : nullptr;
    result->Success(Support(loc ? *loc : "it-IT"));
  } else if (method == "start") {
    const std::string* loc = args ? ReadString(*args, "locale") : nullptr;
    const int session = args ? ReadInt(*args, "session", session_ + 1)
                             : session_ + 1;
    Start(loc ? *loc : "it-IT", session, std::move(result));
  } else if (method == "feed") {
    // il riconoscitore ascolta il microfono da sé
    result->Success();
  } else if (method == "pause") {
    Pause();
    result->Success();
  } else if (method == "resume") {
    Resume();
    result->Success();
  } else if (method == "stop") {
    Stop();
    result->Success();
  } else {
    result->NotImplemented();
  }
}

flutter::EncodableValue LiveSpeechChannel::Support(const std::string& locale) {
  flutter::EncodableMap out;
  // lingua fra SupportedTopicLanguages (pacchetto vocale installato) e
  // opzione della privacy: si controllano a ogni registrazione, così
  // un'impostazione cambiata vale dalla registrazione successiva
  const bool language = DictationSupports(locale);
  const bool privacy = OnlineSpeechAccepted();
  const bool ok = language && privacy;
  out[flutter::EncodableValue("available")] = flutter::EncodableValue(ok);
  out[flutter::EncodableValue("onDevice")] = flutter::EncodableValue(false);
  out[flutter::EncodableValue("feedsAudio")] = flutter::EncodableValue(false);
  out[flutter::EncodableValue("engine")] = flutter::EncodableValue("windows");
  out[flutter::EncodableValue("languageOk")] = flutter::EncodableValue(language);
  if (!privacy) {
    out[flutter::EncodableValue("reason")] = flutter::EncodableValue("privacy");
  } else if (!language) {
    out[flutter::EncodableValue("reason")] = flutter::EncodableValue("locale");
  }
  return flutter::EncodableValue(out);
}

void LiveSpeechChannel::Start(const std::string& locale, int session,
                              std::unique_ptr<Result> result) {
  running_ = false;
  stopping_ = false;
  Release();
  ReplyStart(flutter::EncodableValue(false));
  session_ = session;
  restarts_ = 0;
  first_restart_ = 0;
  pending_start_ = std::move(result);

  ComPtr<ILanguage> language;
  ComPtr<sr::ISpeechRecognizerFactory> factory;
  HRESULT hr = CreateLanguage(locale, &language);
  if (SUCCEEDED(hr)) {
    hr = RoGetActivationFactory(
        HStringReference(RuntimeClass_Windows_Media_SpeechRecognition_SpeechRecognizer)
            .Get(),
        IID_PPV_ARGS(&factory));
  }
  if (SUCCEEDED(hr)) {
    hr = factory->Create(language.Get(), recognizer_.ReleaseAndGetAddressOf());
  }
  ComPtr<sr::ISpeechRecognizer2> recognizer2;
  if (SUCCEEDED(hr)) hr = recognizer_.As(&recognizer2);
  if (SUCCEEDED(hr)) {
    hr = recognizer2->get_ContinuousRecognitionSession(&continuous_);
  }
  if (FAILED(hr) || !continuous_) {
    Release();
    ReplyStart(flutter::EncodableValue("locale"));
    return;
  }
  const HWND window = window_;
  // testo provvisorio mentre si parla
  recognizer2->add_HypothesisGenerated(
      Callback<Implements<
          RuntimeClassFlags<ClassicCom>,
          ITypedEventHandler<sr::SpeechRecognizer*,
                             sr::SpeechRecognitionHypothesisGeneratedEventArgs*>,
          FtmBase>>(
          [window, session](sr::ISpeechRecognizer*,
                            sr::ISpeechRecognitionHypothesisGeneratedEventArgs*
                                args) -> HRESULT {
            ComPtr<sr::ISpeechRecognitionHypothesis> h;
            if (FAILED(args->get_Hypothesis(&h)) || !h) return S_OK;
            HString text;
            if (FAILED(h->get_Text(text.GetAddressOf()))) return S_OK;
            Post(window, new SpeechEvent{session, EventKind::kHypothesis,
                                         ToUtf8(text.Get())});
            return S_OK;
          })
          .Get(),
      &hypothesis_token_);
  // frase definitiva
  continuous_->add_ResultGenerated(
      Callback<Implements<
          RuntimeClassFlags<ClassicCom>,
          ITypedEventHandler<
              sr::SpeechContinuousRecognitionSession*,
              sr::SpeechContinuousRecognitionResultGeneratedEventArgs*>,
          FtmBase>>(
          [window, session](
              sr::ISpeechContinuousRecognitionSession*,
              sr::ISpeechContinuousRecognitionResultGeneratedEventArgs* args)
              -> HRESULT {
            ComPtr<sr::ISpeechRecognitionResult> r;
            if (FAILED(args->get_Result(&r)) || !r) return S_OK;
            sr::SpeechRecognitionResultStatus status;
            if (SUCCEEDED(r->get_Status(&status)) &&
                status != sr::SpeechRecognitionResultStatus_Success) {
              return S_OK;
            }
            HString text;
            if (FAILED(r->get_Text(text.GetAddressOf()))) return S_OK;
            Post(window, new SpeechEvent{session, EventKind::kResult,
                                         ToUtf8(text.Get())});
            return S_OK;
          })
          .Get(),
      &result_token_);
  continuous_->add_Completed(
      Callback<Implements<
          RuntimeClassFlags<ClassicCom>,
          ITypedEventHandler<sr::SpeechContinuousRecognitionSession*,
                             sr::SpeechContinuousRecognitionCompletedEventArgs*>,
          FtmBase>>(
          [window, session](
              sr::ISpeechContinuousRecognitionSession*,
              sr::ISpeechContinuousRecognitionCompletedEventArgs* args)
              -> HRESULT {
            sr::SpeechRecognitionResultStatus status =
                sr::SpeechRecognitionResultStatus_Unknown;
            args->get_Status(&status);
            Post(window, new SpeechEvent{session, EventKind::kCompleted, "",
                                         S_OK, static_cast<int>(status)});
            return S_OK;
          })
          .Get(),
      &completed_token_);
  // niente stop automatico nei silenzi (lezioni con pause lunghe)
  TimeSpan day;
  day.Duration = 24LL * 3600 * 10000000;
  continuous_->put_AutoStopSilenceTimeout(day);

  // nessun vincolo: dettatura libera
  ComPtr<IAsyncOperation<sr::SpeechRecognitionCompilationResult*>> op;
  hr = recognizer_->CompileConstraintsAsync(&op);
  if (FAILED(hr) || !op) {
    Release();
    ReplyStart(flutter::EncodableValue(false));
    return;
  }
  op->put_Completed(
      Callback<Implements<
          RuntimeClassFlags<ClassicCom>,
          IAsyncOperationCompletedHandler<sr::SpeechRecognitionCompilationResult*>,
          FtmBase>>(
          [window, session](
              IAsyncOperation<sr::SpeechRecognitionCompilationResult*>* done,
              AsyncStatus) -> HRESULT {
            ComPtr<sr::ISpeechRecognitionCompilationResult> r;
            HRESULT res = done->GetResults(&r);
            sr::SpeechRecognitionResultStatus status =
                sr::SpeechRecognitionResultStatus_Unknown;
            if (SUCCEEDED(res) && r) r->get_Status(&status);
            Post(window, new SpeechEvent{session, EventKind::kCompiled, "", res,
                                         static_cast<int>(status)});
            return S_OK;
          })
          .Get());
}

void LiveSpeechChannel::StartContinuous() {
  if (!continuous_) return;
  ComPtr<IAsyncAction> action;
  HRESULT hr = continuous_->StartAsync(&action);
  if (FAILED(hr) || !action) {
    Post(window_, new SpeechEvent{session_, EventKind::kStarted, "",
                                  FAILED(hr) ? hr : E_FAIL});
    return;
  }
  const HWND window = window_;
  const int session = session_;
  action->put_Completed(
      Callback<Implements<RuntimeClassFlags<ClassicCom>,
                          IAsyncActionCompletedHandler, FtmBase>>(
          [window, session](IAsyncAction* done, AsyncStatus) -> HRESULT {
            const HRESULT res = done->GetResults();
            Post(window,
                 new SpeechEvent{session, EventKind::kStarted, "", res});
            return S_OK;
          })
          .Get());
}

void LiveSpeechChannel::Pause() {
  if (!continuous_ || !running_) return;
  ComPtr<IAsyncAction> action;
  continuous_->PauseAsync(&action);
}

void LiveSpeechChannel::Resume() {
  if (!continuous_ || !running_) return;
  continuous_->Resume();
}

void LiveSpeechChannel::Stop() {
  if (!continuous_) {
    Send("ended", {});
    return;
  }
  running_ = false;
  stopping_ = true;
  // l'ultimo testo arriva con ResultGenerated, poi Completed
  ComPtr<IAsyncAction> action;
  if (FAILED(continuous_->StopAsync(&action))) {
    stopping_ = false;
    Release();
    // un «start» ancora in attesa riceve la risposta (non resta appeso)
    ReplyStart(flutter::EncodableValue(false));
    Send("ended", {});
  }
}

void LiveSpeechChannel::Release() {
  if (continuous_) {
    if (running_) {
      ComPtr<IAsyncAction> action;
      continuous_->CancelAsync(&action);
    }
    continuous_->remove_ResultGenerated(result_token_);
    continuous_->remove_Completed(completed_token_);
  }
  if (recognizer_) {
    ComPtr<sr::ISpeechRecognizer2> recognizer2;
    if (SUCCEEDED(recognizer_.As(&recognizer2))) {
      recognizer2->remove_HypothesisGenerated(hypothesis_token_);
    }
    ComPtr<IClosable> closable;
    if (SUCCEEDED(recognizer_.As(&closable))) closable->Close();
  }
  continuous_.Reset();
  recognizer_.Reset();
}

void LiveSpeechChannel::ReplyStart(const flutter::EncodableValue& value) {
  if (!pending_start_) return;
  pending_start_->Success(value);
  pending_start_.reset();
}

void LiveSpeechChannel::Send(const char* method, flutter::EncodableMap args) {
  if (!channel_) return;
  args[flutter::EncodableValue("session")] = flutter::EncodableValue(session_);
  channel_->InvokeMethod(
      method, std::make_unique<flutter::EncodableValue>(std::move(args)));
}

void LiveSpeechChannel::Fail(const std::string& message) {
  running_ = false;
  Release();
  flutter::EncodableMap args;
  args[flutter::EncodableValue("message")] = flutter::EncodableValue(message);
  args[flutter::EncodableValue("fatal")] = flutter::EncodableValue(true);
  Send("error", std::move(args));
}

bool LiveSpeechChannel::HandleMessage(UINT message, WPARAM wparam,
                                      LPARAM lparam) {
  if (message != kLiveSpeechMessage) return false;
  std::unique_ptr<SpeechEvent> e(reinterpret_cast<SpeechEvent*>(lparam));
  if (!e || e->session != session_) return true;
  switch (e->kind) {
    case EventKind::kHypothesis:
      if (running_ && !e->text.empty()) {
        flutter::EncodableMap args;
        args[flutter::EncodableValue("text")] = flutter::EncodableValue(e->text);
        Send("partial", std::move(args));
      }
      break;
    case EventKind::kResult:
      if (!e->text.empty()) {
        flutter::EncodableMap args;
        args[flutter::EncodableValue("text")] = flutter::EncodableValue(e->text);
        Send("result", std::move(args));
      }
      break;
    case EventKind::kCompiled:
      // «stop» arrivato mentre si preparava la dettatura: non si avvia più
      // (altrimenti il microfono restava in ascolto a registrazione finita)
      if (stopping_) {
        stopping_ = false;
        Release();
        ReplyStart(flutter::EncodableValue(false));
        Send("ended", {});
        break;
      }
      if (FAILED(e->hr) ||
          e->status != sr::SpeechRecognitionResultStatus_Success) {
        Release();
        ReplyStart(flutter::EncodableValue(
            e->hr == kPrivacyNotAccepted ? "privacy" : "locale"));
        break;
      }
      StartContinuous();
      break;
    case EventKind::kStarted:
      if (FAILED(e->hr)) {
        if (pending_start_) {
          Release();
          ReplyStart(flutter::EncodableValue(
              e->hr == kPrivacyNotAccepted ? "privacy" : "microphone"));
        } else {
          Fail("Il riconoscimento vocale di Windows non è ripartito.");
        }
        break;
      }
      running_ = true;
      ReplyStart(flutter::EncodableValue(true));
      break;
    case EventKind::kCompleted:
      if (stopping_) {
        stopping_ = false;
        Release();
        Send("ended", {});
        break;
      }
      if (!running_) break;
      // la sessione si è chiusa da sola (microfono, rete…): si riparte, ma
      // non all'infinito
      {
        const ULONGLONG now = GetTickCount64();
        if (now - first_restart_ > 60000) {
          first_restart_ = now;
          restarts_ = 0;
        }
        if (++restarts_ > 5) {
          Fail("Il riconoscimento vocale di Windows si è fermato.");
          break;
        }
        running_ = false;
        StartContinuous();
      }
      break;
  }
  return true;
}
