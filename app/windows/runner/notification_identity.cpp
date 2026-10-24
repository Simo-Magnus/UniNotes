#include "notification_identity.h"

#include <appmodel.h>
#include <flutter/standard_method_codec.h>
#include <roapi.h>
#include <shobjidl.h>
#include <windows.ui.notifications.h>
#include <wrl/client.h>
#include <wrl/wrappers/corewrappers.h>

#include <variant>

using ABI::Windows::Foundation::Collections::IVectorView;
using ABI::Windows::UI::Notifications::IScheduledToastNotification;
using ABI::Windows::UI::Notifications::IToastNotificationHistory;
using ABI::Windows::UI::Notifications::IToastNotificationManagerStatics;
using ABI::Windows::UI::Notifications::IToastNotificationManagerStatics2;
using ABI::Windows::UI::Notifications::IToastNotifier;
using ABI::Windows::UI::Notifications::ScheduledToastNotification;
using Microsoft::WRL::ComPtr;
using Microsoft::WRL::Wrappers::HStringReference;

const wchar_t kUniNotesAumid[] = L"SimoMagnus.UniNotes";

namespace {

constexpr char kChannelName[] =
    "io.github.simomagnus.universitynotes/notifiche";

// Toglie i toast pianificati e la cronologia dell'AUMID [aumid]; numero dei
// toast pianificati tolti.
int RemoveToasts(const std::wstring& aumid) {
  ComPtr<IToastNotificationManagerStatics> statics;
  if (FAILED(RoGetActivationFactory(
          HStringReference(
              RuntimeClass_Windows_UI_Notifications_ToastNotificationManager)
              .Get(),
          IID_PPV_ARGS(&statics)))) {
    return 0;
  }
  const HStringReference id(aumid.c_str(), static_cast<UINT32>(aumid.size()));
  int removed = 0;
  ComPtr<IToastNotifier> notifier;
  if (SUCCEEDED(statics->CreateToastNotifierWithId(id.Get(), &notifier)) &&
      notifier) {
    ComPtr<IVectorView<ScheduledToastNotification*>> scheduled;
    if (SUCCEEDED(notifier->GetScheduledToastNotifications(&scheduled)) &&
        scheduled) {
      unsigned int size = 0;
      if (FAILED(scheduled->get_Size(&size))) size = 0;
      for (unsigned int i = 0; i < size; ++i) {
        ComPtr<IScheduledToastNotification> toast;
        if (FAILED(scheduled->GetAt(i, &toast)) || !toast) continue;
        if (SUCCEEDED(notifier->RemoveFromSchedule(toast.Get()))) ++removed;
      }
    }
  }
  // toast già mostrati, ancora nel Centro notifiche
  ComPtr<IToastNotificationManagerStatics2> statics2;
  if (SUCCEEDED(statics.As(&statics2))) {
    ComPtr<IToastNotificationHistory> history;
    if (SUCCEEDED(statics2->get_History(&history)) && history) {
      history->ClearWithId(id.Get());
    }
  }
  return removed;
}

// Chiavi del registro dell'AUMID [aumid]: nome e icona dei toast (scritte
// da flutter_local_notifications), registrazione delle notifiche e voce
// nelle impostazioni delle notifiche di Windows.
void DeleteRegistryKeys(const std::wstring& aumid) {
  const std::wstring keys[] = {
      L"Software\\Classes\\AppUserModelId\\" + aumid,
      L"Software\\Microsoft\\Windows\\CurrentVersion\\PushNotifications\\"
      L"Backup\\" + aumid,
      L"Software\\Microsoft\\Windows\\CurrentVersion\\Notifications\\"
      L"Settings\\" + aumid,
  };
  for (const auto& key : keys) {
    ::RegDeleteTreeW(HKEY_CURRENT_USER, key.c_str());
  }
}

// AUMID vecchio dagli argomenti: non vuoto, senza «\» (è un pezzo di
// percorso del registro) e diverso da quello attuale.
std::wstring ReadLegacyAumid(const flutter::EncodableValue* arguments) {
  const auto* args = std::get_if<flutter::EncodableMap>(arguments);
  if (!args) return std::wstring();
  const auto it = args->find(flutter::EncodableValue("vecchio"));
  if (it == args->end()) return std::wstring();
  const auto* v = std::get_if<std::string>(&it->second);
  if (!v || v->empty() || v->size() > 128) return std::wstring();
  const int size = MultiByteToWideChar(CP_UTF8, 0, v->data(),
                                       static_cast<int>(v->size()), nullptr, 0);
  if (size <= 0) return std::wstring();
  std::wstring out(static_cast<size_t>(size), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, v->data(), static_cast<int>(v->size()),
                      out.data(), size);
  if (out.find(L'\\') != std::wstring::npos ||
      out.find(L'/') != std::wstring::npos || out == kUniNotesAumid) {
    return std::wstring();
  }
  return out;
}

}  // namespace

bool HasPackageIdentity() {
  UINT32 length = 0;
  return ::GetCurrentPackageFullName(&length, nullptr) !=
         APPMODEL_ERROR_NO_PACKAGE;
}

void ApplyProcessAumid() {
  if (HasPackageIdentity()) return;
  ::SetCurrentProcessExplicitAppUserModelID(kUniNotesAumid);
}

NotificationIdentityChannel::NotificationIdentityChannel(
    flutter::BinaryMessenger* messenger) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, kChannelName,
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    HandleMethodCall(call, std::move(result));
  });
}

NotificationIdentityChannel::~NotificationIdentityChannel() {
  if (channel_) channel_->SetMethodCallHandler(nullptr);
}

void NotificationIdentityChannel::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() != "migraAumid") {
    result->NotImplemented();
    return;
  }
  flutter::EncodableMap reply;
  if (HasPackageIdentity()) {
    reply[flutter::EncodableValue("pacchetto")] = flutter::EncodableValue(true);
    reply[flutter::EncodableValue("rimossi")] = flutter::EncodableValue(0);
    result->Success(flutter::EncodableValue(reply));
    return;
  }
  const std::wstring legacy = ReadLegacyAumid(call.arguments());
  if (legacy.empty()) {
    result->Error("argomenti", "AUMID vecchio mancante o non valido.");
    return;
  }
  // prima i toast (il notificatore dell'AUMID vecchio), poi il registro
  const int removed = RemoveToasts(legacy);
  DeleteRegistryKeys(legacy);
  reply[flutter::EncodableValue("pacchetto")] = flutter::EncodableValue(false);
  reply[flutter::EncodableValue("rimossi")] = flutter::EncodableValue(removed);
  result->Success(flutter::EncodableValue(reply));
}
