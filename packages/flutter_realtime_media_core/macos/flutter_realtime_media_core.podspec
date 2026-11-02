Pod::Spec.new do |s|
  s.name             = 'flutter_realtime_media_core'
  s.version          = '0.1.0'
  s.summary          = 'Provider-neutral macOS media permission bridge.'
  s.description      = 'Queries and requests macOS camera/microphone privacy permission for Flutter realtime SDK.'
  s.homepage         = 'https://github.com/lengsukq/multi-video'
  s.license          = { :type => 'MIT' }
  s.author           = { 'Flutter Realtime SDK' => 'developers@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'flutter_realtime_media_core/Sources/flutter_realtime_media_core/**/*'
  s.dependency 'FlutterMacOS'
  s.frameworks       = 'AVFoundation', 'AppKit'
  s.platform         = :osx, '12.0'
  s.swift_version    = '5.0'
end
