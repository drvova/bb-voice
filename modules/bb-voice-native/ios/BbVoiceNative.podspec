Pod::Spec.new do |s|
  s.name           = 'BbVoiceNative'
  s.version        = '0.1.0'
  s.summary        = 'Background audio keep-alive and call routing for bb voice'
  s.author         = 'bb voice'
  s.homepage       = 'https://github.com/drvova/bb-voice'
  s.license        = 'MIT'
  s.platforms      = { :ios => '15.1' }
  s.source         = { git: '' }
  s.static_framework = true
  s.swift_version  = '5.9'

  s.dependency 'ExpoModulesCore'

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.source_files = '**/*.{h,m,swift}'
end
