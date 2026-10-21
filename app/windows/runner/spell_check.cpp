#include "spell_check.h"

#include <flutter/standard_method_codec.h>
#include <objbase.h>

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using Microsoft::WRL::ComPtr;

constexpr char kChannel[] = "io.github.simomagnus.universitynotes/spellcheck";

// Al massimo tanti suggerimenti per parola (il menu resta corto).
constexpr int kMaxSuggestions = 5;

std::wstring Wide(const std::string& s) {
  if (s.empty()) return std::wstring();
  int n = ::MultiByteToWideChar(CP_UTF8, 0, s.data(),
                                static_cast<int>(s.size()), nullptr, 0);
  std::wstring out(n, L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()),
                        out.data(), n);
  return out;
}

std::string Narrow(const std::wstring& s) {
  if (s.empty()) return std::string();
  int n = ::WideCharToMultiByte(CP_UTF8, 0, s.data(),
                                static_cast<int>(s.size()), nullptr, 0,
                                nullptr, nullptr);
  std::string out(n, '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, s.data(), static_cast<int>(s.size()),
                        out.data(), n, nullptr, nullptr);
  return out;
}

// Varianti della lingua da provare, dalla più comune.
std::vector<std::wstring> Tags(const std::string& language) {
  if (language == "it") return {L"it-IT", L"it-CH"};
  if (language == "en") return {L"en-US", L"en-GB", L"en-AU", L"en-CA"};
  return {Wide(language)};
}

// La parola [word] è giusta per [checker] (nessun errore).
bool Accepts(ISpellChecker* checker, const std::wstring& word) {
  ComPtr<IEnumSpellingError> errors;
  if (FAILED(checker->Check(word.c_str(), &errors)) || !errors) return false;
  ComPtr<ISpellingError> error;
  return errors->Next(&error) != S_OK;
}

void AddSuggestions(ISpellChecker* checker, const std::wstring& word,
                    EncodableList& out) {
  ComPtr<IEnumString> list;
  if (FAILED(checker->Suggest(word.c_str(), &list)) || !list) return;
  while (static_cast<int>(out.size()) < kMaxSuggestions) {
    LPOLESTR s = nullptr;
    ULONG fetched = 0;
    if (list->Next(1, &s, &fetched) != S_OK || fetched == 0) break;
    if (s != nullptr) {
      out.push_back(EncodableValue(Narrow(s)));
      ::CoTaskMemFree(s);
    }
  }
}

}  // namespace

SpellCheckChannel::SpellCheckChannel(flutter::BinaryMessenger* messenger) {
  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, kChannel, &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    HandleMethodCall(call, std::move(result));
  });
}

SpellCheckChannel::~SpellCheckChannel() {
  if (channel_) channel_->SetMethodCallHandler(nullptr);
}

ISpellChecker* SpellCheckChannel::Checker(const std::string& language) {
  auto found = checkers_.find(language);
  if (found != checkers_.end()) return found->second.Get();
  ComPtr<ISpellChecker> checker;
  if (!factory_ && !factory_failed_) {
    // il thread della piattaforma è già in un apartment COM (main.cpp)
    if (FAILED(::CoCreateInstance(__uuidof(SpellCheckerFactory), nullptr,
                                  CLSCTX_INPROC_SERVER,
                                  IID_PPV_ARGS(&factory_)))) {
      factory_failed_ = true;
    }
  }
  if (factory_) {
    for (const auto& tag : Tags(language)) {
      BOOL supported = FALSE;
      if (SUCCEEDED(factory_->IsSupported(tag.c_str(), &supported)) &&
          supported &&
          SUCCEEDED(factory_->CreateSpellChecker(tag.c_str(), &checker))) {
        break;
      }
      checker.Reset();
    }
  }
  checkers_[language] = checker;
  return checker.Get();
}

EncodableValue SpellCheckChannel::Check(
    const std::wstring& text, const std::vector<ISpellChecker*>& checkers) {
  EncodableList out;
  if (checkers.empty() || text.empty()) return EncodableValue(out);
  ISpellChecker* first = checkers.front();
  ComPtr<IEnumSpellingError> errors;
  if (FAILED(first->Check(text.c_str(), &errors)) || !errors) {
    return EncodableValue(out);
  }
  while (true) {
    ComPtr<ISpellingError> error;
    if (errors->Next(&error) != S_OK || !error) break;
    ULONG start = 0, length = 0;
    CORRECTIVE_ACTION action = CORRECTIVE_ACTION_NONE;
    error->get_StartIndex(&start);
    error->get_Length(&length);
    error->get_CorrectiveAction(&action);
    // parole ripetute («il il»): non sono errori di ortografia
    if (action == CORRECTIVE_ACTION_DELETE || action == CORRECTIVE_ACTION_NONE ||
        length == 0 || start + length > text.size()) {
      continue;
    }
    const std::wstring word = text.substr(start, length);
    bool known = false;
    for (size_t i = 1; i < checkers.size() && !known; i++) {
      known = Accepts(checkers[i], word);
    }
    if (known) continue;
    EncodableList suggestions;
    if (action == CORRECTIVE_ACTION_REPLACE) {
      LPWSTR replacement = nullptr;
      if (SUCCEEDED(error->get_Replacement(&replacement)) && replacement) {
        suggestions.push_back(EncodableValue(Narrow(replacement)));
        ::CoTaskMemFree(replacement);
      }
    }
    for (ISpellChecker* c : checkers) {
      if (!suggestions.empty()) break;
      AddSuggestions(c, word, suggestions);
    }
    out.push_back(EncodableValue(EncodableList{
        EncodableValue(static_cast<int>(start)),
        EncodableValue(static_cast<int>(start + length)),
        EncodableValue(suggestions),
    }));
  }
  return EncodableValue(out);
}

void SpellCheckChannel::HandleMethodCall(
    const flutter::MethodCall<EncodableValue>& call,
    std::unique_ptr<Result> result) {
  const auto* args = std::get_if<EncodableMap>(call.arguments());
  if (call.method_name() == "languages") {
    result->Success(EncodableValue(EncodableMap{
        {EncodableValue("it"), EncodableValue(Checker("it") != nullptr)},
        {EncodableValue("en"), EncodableValue(Checker("en") != nullptr)},
    }));
    return;
  }
  if (call.method_name() == "check") {
    std::vector<ISpellChecker*> checkers;
    EncodableList texts;
    if (args) {
      auto langs = args->find(EncodableValue("languages"));
      if (langs != args->end()) {
        if (const auto* list = std::get_if<EncodableList>(&langs->second)) {
          for (const auto& l : *list) {
            if (const auto* s = std::get_if<std::string>(&l)) {
              if (ISpellChecker* c = Checker(*s)) checkers.push_back(c);
            }
          }
        }
      }
      auto t = args->find(EncodableValue("texts"));
      if (t != args->end()) {
        if (const auto* list = std::get_if<EncodableList>(&t->second)) {
          texts = *list;
        }
      }
    }
    EncodableList out;
    for (const auto& t : texts) {
      const auto* s = std::get_if<std::string>(&t);
      out.push_back(s ? Check(Wide(*s), checkers) : EncodableValue(EncodableList{}));
    }
    result->Success(EncodableValue(out));
    return;
  }
  result->NotImplemented();
}
