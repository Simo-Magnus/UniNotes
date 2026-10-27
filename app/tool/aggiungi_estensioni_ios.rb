# frozen_string_literal: true

# Estensione WidgetKit «WidgetUniNotes» nel progetto Xcode dell'app per
# iPhone e iPad (ios/Runner.xcodeproj): i due widget della schermata Home e la
# Live Activity della registrazione, nella stessa estensione (WidgetBundle in
# ios/WidgetUniNotes/UniNotesWidgets.swift). docs/widget.md.
#
# Gira nella build automatica (job «testflight» di .github/workflows/app.yml)
# dopo «flutter build ios --config-only» e prima di «xcodebuild archive». Il
# project.pbxproj del repository resta senza estensioni: la build non
# firmata, flutter run e la ricaduta della build automatica (se l'aggiunta,
# l'archivio o la firma non riescono) restano quelli di prima.
#
# Cosa aggiunge (una seconda esecuzione non aggiunge nulla):
# - gruppo e target «WidgetUniNotes» (app extension, bundle ID
#   io.github.simomagnus.universitynotes.WidgetUniNotes, iOS 15.6, firma
#   automatica, stessi file xcconfig di Flutter di Runner: versione e numero
#   di build dell'app, FLUTTER_BUILD_NAME e FLUTTER_BUILD_NUMBER);
# - RecordingIntents.swift anche in Runner (pulsanti della Live Activity
#   eseguiti nel processo dell'app);
# - in Runner la dipendenza dall'estensione, la fase «Embed Foundation
#   Extensions» (PlugIns) prima di «Thin Binary» di Flutter (dopo darebbe
#   «Cycle inside Runner») e Runner/Runner.entitlements (App Group).
# Alla fine rilegge il progetto salvato e controlla target, fasi,
# impostazioni, Info.plist ed entitlement: se qualcosa non torna si ferma con
# un messaggio chiaro (codice d'uscita 1) e la build ricade senza estensioni.
#
# Uso (dalla cartella app/): ruby tool/aggiungi_estensioni_ios.rb
# Serve la gemma xcodeproj nella versione qui sotto (la installa il job).

XCODEPROJ_VERSIONE = '1.28.1'

def errore(messaggio)
  warn "Estensioni iOS: #{messaggio}"
  exit 1
end

begin
  gem 'xcodeproj', XCODEPROJ_VERSIONE
  require 'xcodeproj'
rescue LoadError => e
  errore("gemma xcodeproj #{XCODEPROJ_VERSIONE} non disponibile (#{e.message})")
end

IOS = File.expand_path('../ios', __dir__)
PROGETTO = File.join(IOS, 'Runner.xcodeproj')
NOME = 'WidgetUniNotes'
BUNDLE_APP = 'io.github.simomagnus.universitynotes'
BUNDLE_ESTENSIONE = "#{BUNDLE_APP}.#{NOME}"
APP_GROUP = 'group.io.github.simomagnus.universitynotes'
DEPLOYMENT = '15.6'
TIPO_ESTENSIONE = 'com.apple.product-type.app-extension'
FASE_EMBED = 'Embed Foundation Extensions'
FASE_FLUTTER = 'Thin Binary'
ENTITLEMENT_RUNNER = 'Runner/Runner.entitlements'
ENTITLEMENT_ESTENSIONE = "#{NOME}/#{NOME}.entitlements"
INFO_ESTENSIONE = "#{NOME}/Info.plist"
# compilati nell'estensione; RecordingIntents.swift anche in Runner
SWIFT = %w[
  UniNotesWidgets.swift
  RecordingLiveActivity.swift
  RecordingActivityAttributes.swift
  RecordingIntents.swift
].freeze
SWIFT_ANCHE_IN_RUNNER = %w[RecordingIntents.swift].freeze
RISORSE = %w[PrivacyInfo.xcprivacy].freeze
ALTRI = %w[Info.plist WidgetUniNotes.entitlements].freeze
TIPI_FILE = {
  '.swift' => 'sourcecode.swift',
  '.plist' => 'text.plist.xml',
  '.entitlements' => 'text.plist.entitlements',
  '.xcprivacy' => 'text.xml',
}.freeze

# Comando senza shell; uscita e stato.
def esegui(*comando)
  uscita = IO.popen(comando, err: %i[child out], &:read)
  [uscita, $?.success?]
rescue SystemCallError => e
  ["#{comando.first}: #{e.message}", false]
end

def valore_plist(file, chiave)
  uscita, ok = esegui('/usr/libexec/PlistBuddy', '-c', "Print :#{chiave}", file)
  ok ? uscita.strip : nil
end

def riferimento(gruppo, nome)
  ref = gruppo.files.find { |f| f.path == nome }
  return ref if ref

  ref = gruppo.new_reference(nome)
  tipo = TIPI_FILE[File.extname(nome)]
  ref.last_known_file_type = tipo if tipo
  ref
end

def gruppo_figlio(padre, nome)
  padre.children.find do |c|
    c.isa == 'PBXGroup' && (c.path == nome || c.name == nome)
  end
end

# --- file che servono ------------------------------------------------------

cartella = File.join(IOS, NOME)
(SWIFT + RISORSE + ALTRI).each do |f|
  errore("manca ios/#{NOME}/#{f}") unless File.file?(File.join(cartella, f))
end
errore("manca ios/#{ENTITLEMENT_RUNNER}") unless File.file?(File.join(IOS, ENTITLEMENT_RUNNER))
errore("manca #{PROGETTO}") unless File.directory?(PROGETTO)

# --- progetto ---------------------------------------------------------------

progetto = Xcodeproj::Project.open(PROGETTO)
runner = progetto.native_targets.find { |t| t.name == 'Runner' }
errore('target Runner assente nel progetto') unless runner

config_runner = runner.build_configuration_list.build_configurations.to_h { |c| [c.name, c] }
%w[Debug Release Profile].each do |n|
  errore("configurazione #{n} di Runner assente") unless config_runner[n]
end
config_progetto = progetto.build_configuration_list.build_configurations.to_h { |c| [c.name, c] }

gruppo = gruppo_figlio(progetto.main_group, NOME) || progetto.main_group.new_group(NOME, NOME)
riferimenti = (SWIFT + RISORSE + ALTRI).to_h { |f| [f, riferimento(gruppo, f)] }
gruppo_runner = gruppo_figlio(progetto.main_group, 'Runner')
errore('gruppo Runner assente nel progetto') unless gruppo_runner
riferimento(gruppo_runner, File.basename(ENTITLEMENT_RUNNER))

# Target dell'estensione (creato a mano, non con new_target: niente
# Foundation.framework con il percorso di un SDK fisso)
estensione = progetto.native_targets.find { |t| t.name == NOME }
unless estensione
  estensione = progetto.new(Xcodeproj::Project::Object::PBXNativeTarget)
  estensione.name = NOME
  estensione.product_name = NOME
  estensione.product_type = TIPO_ESTENSIONE
  lista = progetto.new(Xcodeproj::Project::Object::XCConfigurationList)
  lista.default_configuration_name = 'Release'
  lista.default_configuration_is_visible = '0'
  estensione.build_configuration_list = lista
  prodotto = progetto.products_group.new_reference("#{NOME}.appex", :built_products)
  prodotto.explicit_file_type = 'wrapper.app-extension'
  prodotto.last_known_file_type = nil
  prodotto.include_in_index = '0'
  estensione.product_reference = prodotto
  progetto.targets << estensione
end
errore("#{NOME} esiste ma non è un'estensione") unless estensione.product_type == TIPO_ESTENSIONE

# fasi: Sources, Frameworks, Resources (trovate o create, in quest'ordine)
estensione.source_build_phase
estensione.frameworks_build_phase
estensione.resources_build_phase

swift_runner = config_runner['Release'].build_settings['SWIFT_VERSION'] || '5.0'
famiglia = config_runner['Release'].build_settings['TARGETED_DEVICE_FAMILY'] ||
           config_progetto['Release']&.build_settings&.dig('TARGETED_DEVICE_FAMILY') || '1,2'

config_runner.each do |nome_config, cfg_runner|
  cfg = estensione.build_configuration_list.build_configurations.find { |c| c.name == nome_config }
  unless cfg
    cfg = progetto.new(Xcodeproj::Project::Object::XCBuildConfiguration)
    cfg.name = nome_config
    cfg.build_settings = {}
    estensione.build_configuration_list.build_configurations << cfg
  end
  # Debug.xcconfig / Release.xcconfig di Flutter come Runner: FLUTTER_BUILD_NAME
  # e FLUTTER_BUILD_NUMBER (versione dell'app) e il collegamento facoltativo di
  # ActivityKit e AppIntents
  cfg.base_configuration_reference = cfg_runner.base_configuration_reference
  impostazioni = {
    'PRODUCT_NAME' => '$(TARGET_NAME)',
    'PRODUCT_BUNDLE_IDENTIFIER' => BUNDLE_ESTENSIONE,
    'INFOPLIST_FILE' => INFO_ESTENSIONE,
    'GENERATE_INFOPLIST_FILE' => 'NO',
    'CODE_SIGN_ENTITLEMENTS' => ENTITLEMENT_ESTENSIONE,
    'CODE_SIGN_STYLE' => 'Automatic',
    'IPHONEOS_DEPLOYMENT_TARGET' => DEPLOYMENT,
    'SDKROOT' => 'iphoneos',
    'SWIFT_VERSION' => swift_runner,
    'TARGETED_DEVICE_FAMILY' => famiglia,
    'MARKETING_VERSION' => '$(FLUTTER_BUILD_NAME)',
    'CURRENT_PROJECT_VERSION' => '$(FLUTTER_BUILD_NUMBER)',
    'VERSIONING_SYSTEM' => 'apple-generic',
    'SKIP_INSTALL' => 'YES',
    'APPLICATION_EXTENSION_API_ONLY' => 'YES',
    'CLANG_ENABLE_MODULES' => 'YES',
    'ENABLE_BITCODE' => 'NO',
    'SWIFT_EMIT_LOC_STRINGS' => 'YES',
    'LD_RUNPATH_SEARCH_PATHS' => [
      '$(inherited)',
      '@executable_path/Frameworks',
      '@executable_path/../../Frameworks',
    ],
  }
  if nome_config == 'Debug'
    impostazioni['SWIFT_OPTIMIZATION_LEVEL'] = '-Onone'
    impostazioni['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = 'DEBUG'
  else
    impostazioni['SWIFT_OPTIMIZATION_LEVEL'] = '-O'
    impostazioni['SWIFT_COMPILATION_MODE'] = 'wholemodule'
  end
  cfg.build_settings.merge!(impostazioni)
  # App Group anche per l'app
  cfg_runner.build_settings['CODE_SIGN_ENTITLEMENTS'] = ENTITLEMENT_RUNNER
end

SWIFT.each { |f| estensione.source_build_phase.add_file_reference(riferimenti[f], true) }
RISORSE.each { |f| estensione.resources_build_phase.add_file_reference(riferimenti[f], true) }
SWIFT_ANCHE_IN_RUNNER.each { |f| runner.source_build_phase.add_file_reference(riferimenti[f], true) }

unless runner.dependencies.any? { |d| d.target && d.target.uuid == estensione.uuid }
  runner.add_dependency(estensione)
end

embed = runner.copy_files_build_phases.find { |p| p.name == FASE_EMBED } ||
        runner.new_copy_files_build_phase(FASE_EMBED)
embed.symbol_dst_subfolder_spec = :plug_ins
embed.dst_path = ''
file_embed = embed.files.find { |f| f.file_ref == estensione.product_reference } ||
             embed.add_file_reference(estensione.product_reference)
file_embed.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }

# «Embed Foundation Extensions» subito prima di «Thin Binary» di Flutter
indice_flutter = runner.build_phases.index { |p| p.display_name == FASE_FLUTTER }
errore("fase «#{FASE_FLUTTER}» di Flutter assente in Runner") unless indice_flutter
indice_embed = runner.build_phases.index(embed)
runner.build_phases.move(embed, indice_flutter) if indice_embed > indice_flutter

progetto.save

# --- verifica del progetto salvato -----------------------------------------

problemi = []
salvato = Xcodeproj::Project.open(PROGETTO)
r = salvato.native_targets.find { |t| t.name == 'Runner' }
e = salvato.native_targets.find { |t| t.name == NOME }
if r.nil? || e.nil?
  problemi << 'target Runner o WidgetUniNotes assente dopo il salvataggio'
else
  problemi << "#{NOME}: tipo #{e.product_type}" unless e.product_type == TIPO_ESTENSIONE
  problemi << "#{NOME}: prodotto non .appex" unless e.product_reference&.path == "#{NOME}.appex"
  fasi = r.build_phases.map(&:display_name)
  i_embed = fasi.index(FASE_EMBED)
  i_flutter = fasi.index(FASE_FLUTTER)
  unless i_embed && i_flutter && i_embed < i_flutter
    problemi << "Runner: «#{FASE_EMBED}» deve stare prima di «#{FASE_FLUTTER}» (fasi: #{fasi.join(', ')})"
  end
  fase = r.copy_files_build_phases.find { |p| p.name == FASE_EMBED }
  unless fase && fase.dst_subfolder_spec == '13' &&
         fase.files.any? { |f| f.file_ref&.path == "#{NOME}.appex" }
    problemi << "Runner: #{NOME}.appex non è nella fase «#{FASE_EMBED}» (PlugIns)"
  end
  unless r.dependencies.any? { |d| d.target&.name == NOME }
    problemi << "Runner: manca la dipendenza da #{NOME}"
  end
  sorgenti = e.source_build_phase.files.map { |f| f.file_ref&.path }.compact.sort
  problemi << "#{NOME}: sorgenti #{sorgenti.join(', ')}" unless sorgenti == SWIFT.sort
  sorgenti_runner = r.source_build_phase.files.map { |f| f.file_ref&.path }
  SWIFT_ANCHE_IN_RUNNER.each do |f|
    problemi << "Runner: manca #{f} tra i sorgenti" unless sorgenti_runner.include?(f)
  end
  risorse = e.resources_build_phase.files.map { |f| f.file_ref&.path }
  RISORSE.each { |f| problemi << "#{NOME}: manca la risorsa #{f}" unless risorse.include?(f) }
  e.build_configuration_list.build_configurations.each do |c|
    s = c.build_settings
    {
      'PRODUCT_BUNDLE_IDENTIFIER' => BUNDLE_ESTENSIONE,
      'IPHONEOS_DEPLOYMENT_TARGET' => DEPLOYMENT,
      'CODE_SIGN_ENTITLEMENTS' => ENTITLEMENT_ESTENSIONE,
      'CODE_SIGN_STYLE' => 'Automatic',
      'INFOPLIST_FILE' => INFO_ESTENSIONE,
      'MARKETING_VERSION' => '$(FLUTTER_BUILD_NAME)',
      'CURRENT_PROJECT_VERSION' => '$(FLUTTER_BUILD_NUMBER)',
    }.each do |k, v|
      problemi << "#{NOME} (#{c.name}): #{k} = #{s[k].inspect}, atteso #{v}" unless s[k] == v
    end
    problemi << "#{NOME} (#{c.name}): senza i file xcconfig di Flutter" unless c.base_configuration_reference
  end
  nomi_config = e.build_configuration_list.build_configurations.map(&:name).sort
  problemi << "#{NOME}: configurazioni #{nomi_config.join(', ')}" unless nomi_config == %w[Debug Profile Release]
  r.build_configuration_list.build_configurations.each do |c|
    unless c.build_settings['CODE_SIGN_ENTITLEMENTS'] == ENTITLEMENT_RUNNER
      problemi << "Runner (#{c.name}): CODE_SIGN_ENTITLEMENTS non è #{ENTITLEMENT_RUNNER}"
    end
  end
end

# Info.plist, entitlement e manifest della privacy leggibili e coerenti
plist_estensione = File.join(IOS, INFO_ESTENSIONE)
[plist_estensione, File.join(IOS, ENTITLEMENT_ESTENSIONE), File.join(IOS, ENTITLEMENT_RUNNER),
 File.join(cartella, 'PrivacyInfo.xcprivacy'), File.join(IOS, 'Runner/Info.plist')].each do |f|
  uscita, ok = esegui('plutil', '-lint', f)
  problemi << "plutil: #{uscita.strip}" unless ok
end
punto = valore_plist(plist_estensione, 'NSExtension:NSExtensionPointIdentifier')
problemi << "Info.plist dell'estensione: NSExtensionPointIdentifier = #{punto.inspect}" unless punto == 'com.apple.widgetkit-extension'
%w[CFBundleShortVersionString CFBundleVersion].each do |k|
  v = valore_plist(plist_estensione, k)
  problemi << "Info.plist dell'estensione: #{k} = #{v.inspect}" unless v == valore_plist(File.join(IOS, 'Runner/Info.plist'), k)
end
live = valore_plist(File.join(IOS, 'Runner/Info.plist'), 'NSSupportsLiveActivities')
problemi << "Runner/Info.plist: NSSupportsLiveActivities = #{live.inspect}" unless live == 'true'
[ENTITLEMENT_ESTENSIONE, ENTITLEMENT_RUNNER].each do |f|
  g = valore_plist(File.join(IOS, f), 'com.apple.security.application-groups:0')
  problemi << "#{f}: App Group #{g.inspect}, atteso #{APP_GROUP}" unless g == APP_GROUP
end
# stesso App Group nel codice dell'app e dei widget; l'app cerca questa estensione
delegate = File.read(File.join(IOS, 'Runner/AppDelegate.swift'))
widget = File.read(File.join(cartella, 'UniNotesWidgets.swift'))
problemi << 'AppDelegate.swift: App Group diverso' unless delegate.include?(%(appGroup = "#{APP_GROUP}"))
problemi << 'UniNotesWidgets.swift: App Group diverso' unless widget.include?(%(appGroup = "#{APP_GROUP}"))
problemi << "AppDelegate.swift: non cerca #{NOME}.appex" unless delegate.include?(%("#{NOME}.appex"))
problemi << "nei sorgenti dell'estensione serve un solo @main" unless SWIFT.sum { |f| File.read(File.join(cartella, f)).scan(/^@main\b/).size } == 1

# Xcode vede il target
elenco, ok = esegui('xcodebuild', '-list', '-project', PROGETTO)
problemi << "xcodebuild -list non riuscito: #{elenco.strip}" unless ok
problemi << "xcodebuild -list non mostra il target #{NOME}" unless ok && elenco.lines.any? { |l| l.strip == NOME }

unless problemi.empty?
  problemi.each { |p| warn "- #{p}" }
  errore("progetto con l'estensione non valido (#{problemi.size} problemi)")
end

puts "Estensione #{NOME} (#{BUNDLE_ESTENSIONE}, iOS #{DEPLOYMENT}) nel progetto: " \
     "widget e Live Activity, App Group #{APP_GROUP}, «#{FASE_EMBED}» prima di «#{FASE_FLUTTER}»."
puts elenco
