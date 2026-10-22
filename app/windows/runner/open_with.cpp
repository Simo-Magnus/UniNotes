#include "open_with.h"

#include <flutter/standard_method_codec.h>
#include <shlobj.h>

#include <string>
#include <variant>

namespace {

constexpr char kChannelName[] = "io.github.simomagnus.universitynotes/apri_con";

// Testo UTF-8 dagli argomenti, convertito per le API di Windows.
std::wstring ReadPath(const flutter::EncodableValue* arguments) {
  const auto* args = std::get_if<flutter::EncodableMap>(arguments);
  if (!args) return std::wstring();
  const auto it = args->find(flutter::EncodableValue("path"));
  if (it == args->end()) return std::wstring();
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

OpenWithChannel::OpenWithChannel(flutter::BinaryMessenger* messenger,
                                 HWND window)
    : window_(window) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, kChannelName, &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    HandleMethodCall(call, std::move(result));
  });
}

OpenWithChannel::~OpenWithChannel() {
  if (channel_) channel_->SetMethodCallHandler(nullptr);
}

void OpenWithChannel::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() != "openWith") {
    result->NotImplemented();
    return;
  }
  const std::wstring path = ReadPath(call.arguments());
  if (path.empty()) {
    result->Error("percorso", "Percorso mancante");
    return;
  }
  OPENASINFO info = {};
  info.pcszFile = path.c_str();
  info.pcszClass = nullptr;
  info.oaifInFlags = OAIF_ALLOW_REGISTRATION | OAIF_EXEC;
  // la finestra di Windows resta in primo piano su quella dell'app
  const HRESULT hr = SHOpenWithDialog(window_, &info);
  if (SUCCEEDED(hr)) {
    result->Success(flutter::EncodableValue("ok"));
  } else if (hr == HRESULT_FROM_WIN32(ERROR_CANCELLED)) {
    result->Success(flutter::EncodableValue("annullato"));
  } else {
    result->Success(flutter::EncodableValue("errore"));
  }
}
