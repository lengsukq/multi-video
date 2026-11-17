disable_artc = ENV['FRSDK_IOS_DISABLE_ARTC'] == '1'

Pod::Spec.new do |s|
  s.name             = 'flutter_realtime_media_artc'
  s.version          = '0.1.0'
  s.summary          = 'Provider-neutral Flutter adapter for Alibaba Cloud ARTC.'
  s.description      = 'An optional Flutter adapter that maps Alibaba Cloud ARTC into flutter_realtime_media_core.'
  s.homepage         = 'https://github.com/lengsukq/multi-video'
  s.license          = { :type => 'MIT' }
  s.author           = { 'OnePlusDream' => 'developers@oneplusdream.com' }
  s.source           = { :path => '.' }
  s.source_files     = disable_artc ? 'Classes/FlutterRealtimeMediaArtcPlugin.swift' : 'Classes/**/*'
  s.dependency 'Flutter'
  s.dependency 'AliVCSDK_ARTC', '7.11.0' unless disable_artc
  s.platform = :ios, '15.0'
  s.swift_version = '5.0'
  s.static_framework = true
  conditions = ['$(inherited)']
  conditions << 'FRSDK_DISABLE_ARTC' if disable_artc
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS' => conditions.join(' '),
  }
end
