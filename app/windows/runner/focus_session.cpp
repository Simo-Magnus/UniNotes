#include "focus_session.h"

#include <flutter/standard_method_codec.h>
#include <roapi.h>
#include <wrl/wrappers/corewrappers.h>

#include <variant>

using ABI::Windows::UI::Shell::IFocusSession;
using ABI::Windows::UI::Shell::IFocusSessionManager;
using ABI::Windows::UI::Shell::IFocusSessionManagerStatics;
using Microsoft::WRL::ComPtr;
using Microsoft::WRL::Wrappers::HStringReference;

namespace {

constexpr char kChannelName[] = "io.github.simomagnus.universitynotes/focus";

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

bool FocusSessionChannel::Start(int64_t end_ms) {
  End();
  ComPtr<IFocusSessionManager> manager;
  if (FAILED(GetManager(&manager))) return false;
  ABI::Windows::Foundation::DateTime end{};
  end.UniversalTime = end_ms * 10000 + kUnixEpochTicks;
  ComPtr<IFocusSession> session;
  const HRESULT hr = manager->TryStartFocusSession2(end, &session);
  if (FAILED(hr) || !session) return false;
  session_ = session;
  return true;
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
    result->Success(flutter::EncodableValue(Start(end_ms)));
    return;
  }
  if (method == "winFocusEnd") {
    End();
    result->Success();
    return;
  }
  result->NotImplemented();
}
