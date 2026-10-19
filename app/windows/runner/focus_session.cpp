#include "focus_session.h"

#include <flutter/standard_method_codec.h>
#include <roapi.h>
#include <windows.applicationmodel.h>
#include <wrl/wrappers/corewrappers.h>

#include <variant>

using ABI::Windows::ApplicationModel::ILimitedAccessFeatureRequestResult;
using ABI::Windows::ApplicationModel::ILimitedAccessFeaturesStatics;
using ABI::Windows::ApplicationModel::LimitedAccessFeatureStatus;
using ABI::Windows::UI::Shell::IFocusSession;
using ABI::Windows::UI::Shell::IFocusSessionManager;
using ABI::Windows::UI::Shell::IFocusSessionManagerStatics;
using Microsoft::WRL::ComPtr;
using Microsoft::WRL::Wrappers::HStringReference;

namespace {

constexpr char kChannelName[] = "io.github.simomagnus.universitynotes/focus";

// Funzione ad accesso limitato delle sessioni di concentrazione.
constexpr wchar_t kLafFeature[] = L"com.microsoft.windows.focussessionmanager.1";

// Differenza tra l'epoca di Windows (1601) e quella Unix (1970) in passi
// da 100 ns.
constexpr int64_t kUnixEpochTicks = 116444736000000000LL;

// Gestore delle sessioni, se il sistema le ha (Windows 11 recente).
HRESULT GetManager(ComPtr<IFocusSessionManager>* out) {
  ComPtr<IFocusSessionManagerStatics> statics;
  HRESULT hr = RoGetActivationFactory(
      HStringReference(RuntimeClass_Windows_UI_Shell_FocusSessionManager)
          .Get(),
      IID_PPV_ARGS(&statics));
  if (FAILED(hr)) return hr;
  boolean supported = false;
  hr = statics->get_IsSupported(&supported);
  if (FAILED(hr)) return hr;
  if (!supported) return E_NOTIMPL;
  return statics->GetDefault(out->ReleaseAndGetAddressOf());
}

// Sblocca la funzione ad accesso limitato con il token dato da Microsoft
// (vuoto = nessun token: si prova comunque, nel caso Windows la conceda).
void UnlockFeature(const std::wstring& token, const std::wstring& attestation) {
  if (token.empty()) return;
  ComPtr<ILimitedAccessFeaturesStatics> statics;
  if (FAILED(RoGetActivationFactory(
          HStringReference(
              RuntimeClass_Windows_ApplicationModel_LimitedAccessFeatures)
              .Get(),
          IID_PPV_ARGS(&statics)))) {
    return;
  }
  ComPtr<ILimitedAccessFeatureRequestResult> request;
  const HRESULT hr = statics->TryUnlockFeature(
      HStringReference(kLafFeature).Get(),
      HStringReference(token.c_str(), static_cast<UINT32>(token.size()))
          .Get(),
      HStringReference(attestation.c_str(),
                       static_cast<UINT32>(attestation.size()))
          .Get(),
      &request);
  if (FAILED(hr) || !request) return;
  LimitedAccessFeatureStatus status{};
  request->get_Status(&status);
}

// Numero dagli argomenti (int32 o int64 secondo il valore).
bool ReadInt64(const flutter::EncodableMap& args, const char* key,
               int64_t* out) {
  const auto it = args.find(flutter::EncodableValue(key));
  if (it == args.end()) return false;
  if (const auto* v = std::get_if<int64_t>(&it->second)) {
    *out = *v;
    return true;
  }
  if (const auto* v = std::get_if<int32_t>(&it->second)) {
    *out = *v;
    return true;
  }
  return false;
}

// Testo UTF-8 dagli argomenti, convertito per le API di Windows.
std::wstring ReadWide(const flutter::EncodableMap& args, const char* key) {
  const auto it = args.find(flutter::EncodableValue(key));
  if (it == args.end()) return std::wstring();
  const auto* v = std::get_if<std::string>(&it->second);
  if (!v || v->empty()) return std::wstring();
  const int size = MultiByteToWideChar(CP_UTF8, 0, v->data(),
                                       static_cast<int>(v->size()), nullptr, 0);
  if (size <= 0) return std::wstring();
  std::wstring out(static_cast<size_t>(size), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, v->data(), static_cast<int>(v->size()),
                      out.data(), size);
  return out;
}

}  // namespace

FocusSessionChannel::FocusSessionChannel(flutter::BinaryMessenger* messenger) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, kChannelName,
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        HandleMethodCall(call, std::move(result));
      });
}

FocusSessionChannel::~FocusSessionChannel() {
  // l'app si chiude: la sessione di Windows non resta aperta
  End();
  if (channel_) channel_->SetMethodCallHandler(nullptr);
}

bool FocusSessionChannel::Supported() {
  ComPtr<IFocusSessionManager> manager;
  return SUCCEEDED(GetManager(&manager));
}

std::string FocusSessionChannel::Start(int64_t end_ms,
                                       const std::wstring& token,
                                       const std::wstring& attestation) {
  End();
  ComPtr<IFocusSessionManager> manager;
  if (FAILED(GetManager(&manager))) return "non_supportato";
  UnlockFeature(token, attestation);
  ABI::Windows::Foundation::DateTime end{};
  end.UniversalTime = end_ms * 10000 + kUnixEpochTicks;
  ComPtr<IFocusSession> session;
  const HRESULT hr = manager->TryStartFocusSession2(end, &session);
  if (hr == E_ACCESSDENIED) return "negato";
  if (FAILED(hr) || !session) return "errore";
  session_ = session;
  return "ok";
}

bool FocusSessionChannel::Active() {
  if (!session_) return false;
  ComPtr<IFocusSessionManager> manager;
  if (FAILED(GetManager(&manager))) return false;
  boolean active = false;
  if (FAILED(manager->get_IsFocusActive(&active))) return false;
  return active != 0;
}

void FocusSessionChannel::End() {
  if (!session_) return;
  session_->End();
  session_.Reset();
}

void FocusSessionChannel::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();
  if (method == "winFocusSupported") {
    result->Success(flutter::EncodableValue(Supported()));
    return;
  }
  if (method == "winFocusStart") {
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    int64_t end_ms = 0;
    if (!args || !ReadInt64(*args, "endMs", &end_ms)) {
      result->Error("argomenti", "Manca la fine della sessione (endMs).");
      return;
    }
    result->Success(flutter::EncodableValue(
        Start(end_ms, ReadWide(*args, "lafToken"),
              ReadWide(*args, "lafAttestation"))));
    return;
  }
  if (method == "winFocusActive") {
    result->Success(flutter::EncodableValue(Active()));
    return;
  }
  if (method == "winFocusEnd") {
    End();
    result->Success();
    return;
  }
  result->NotImplemented();
}
