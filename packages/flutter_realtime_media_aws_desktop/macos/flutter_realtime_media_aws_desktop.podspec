Pod::Spec.new do |s|
  s.name             = 'flutter_realtime_media_aws_desktop'
  s.version          = '0.1.0'
  s.summary          = 'Internal AWS realtime media transport for Flutter macOS.'
  s.description      = 'WebKit-backed Amazon Chime, IVS media, and IVS Chat transport used by flutter_realtime_sdk.'
  s.homepage         = 'https://github.com/lengsukq/multi-video'
  s.license          = { :type => 'MIT' }
  s.author           = { 'OnePlusDream' => 'developers@oneplusdream.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'flutter_realtime_media_aws_desktop/Sources/flutter_realtime_media_aws_desktop/**/*'
  s.dependency 'FlutterMacOS'
  s.frameworks       = 'WebKit', 'AVFoundation', 'AppKit'
  s.platform         = :osx, '12.0'
  s.swift_version    = '5.0'
  s.static_framework = true
  s.resource_bundles = {
    'flutter_realtime_media_aws_desktop_assets' => [
      'Resources/aws_desktop_runtime.js'
    ]
  }
end
