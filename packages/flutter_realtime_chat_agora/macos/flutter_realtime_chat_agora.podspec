Pod::Spec.new do |s|
  s.name             = 'flutter_realtime_chat_agora'
  s.version          = '0.1.0'
  s.summary           = 'Agora Chat adapter for Flutter, including macOS WebKit transport.'
  s.description       = 'Agora Chat provider adapter with native mobile and WebKit-backed macOS support.'
  s.homepage          = 'https://github.com/lengsukq/multi-video'
  s.license           = { :type => 'Proprietary', :text => 'Not published.' }
  s.author            = { 'Project' => 'N/A' }
  s.source            = { :path => '.' }
  s.source_files      = 'flutter_realtime_chat_agora/Sources/flutter_realtime_chat_agora/**/*'
  s.dependency 'FlutterMacOS'
  s.frameworks        = 'WebKit'
  s.platform           = :osx, '12.0'
  s.swift_version      = '5.0'
  s.static_framework   = true
  s.resource_bundles = {
    'flutter_realtime_chat_agora_macos_assets' => [
      'Resources/agora_chat_macos.html',
      'Resources/agora_chat_macos.js'
    ]
  }
end
