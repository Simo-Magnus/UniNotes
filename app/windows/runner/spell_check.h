#ifndef RUNNER_SPELL_CHECK_H_
#define RUNNER_SPELL_CHECK_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>
#include <spellcheck.h>
#include <wrl/client.h>

#include <map>
#include <memory>
#include <string>
#include <vector>

// Controllo ortografico di Windows (ISpellChecker, spellcheck.h) per i
// campi di testo dell'app: trascrizione dal vivo, note e appunti (vedi
// lib/features/notes/spell_check.dart). Canale
// "io.github.simomagnus.universitynotes/spellcheck":
// - "languages" → {it: bool, en: bool}: lingue con il controllo ortografico
//   installato in Windows (ISpellCheckerFactory::IsSupported);
// - "check" {texts: [String], languages: ["it", "en"]} → per ogni testo
//   [[inizio, fine, [suggerimenti]]] (indici UTF-16, come le stringhe di
//   Dart). Una parola è errata solo se nessuna delle lingue installate la
//   riconosce; i suggerimenti arrivano dalla prima lingua che ne ha.
// Le lingue non installate non contano (nessuna sottolineatura per loro).
class SpellCheckChannel {
 public:
  explicit SpellCheckChannel(flutter::BinaryMessenger* messenger);
  ~SpellCheckChannel();

 private:
  using Result = flutter::MethodResult<flutter::EncodableValue>;

  void HandleMethodCall(const flutter::MethodCall<flutter::EncodableValue>& call,
                        std::unique_ptr<Result> result);

  // Il correttore della lingua ("it", "en"); nullptr se non è installata.
  ISpellChecker* Checker(const std::string& language);
  flutter::EncodableValue Check(const std::wstring& text,
                                const std::vector<ISpellChecker*>& checkers);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  Microsoft::WRL::ComPtr<ISpellCheckerFactory> factory_;
  bool factory_failed_ = false;
  // correttori già creati (nullptr = lingua non installata)
  std::map<std::string, Microsoft::WRL::ComPtr<ISpellChecker>> checkers_;
};

#endif  // RUNNER_SPELL_CHECK_H_
