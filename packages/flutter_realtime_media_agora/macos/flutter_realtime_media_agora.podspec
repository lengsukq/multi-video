Pod::Spec.new do |s|
  s.name = 'flutter_realtime_media_agora'
  s.version = '0.1.0'
  s.summary = 'Provider-owned processed video sink.'
  s.description = s.summary
  s.homepage = 'https://github.com/lengsukq/multi-video'
  s.license = { :type => 'MIT' }
  s.author = { 'OnePlusDream' => 'developers@oneplusdream.com' }
  s.source = { :path => '.' }
  s.source_files = 'flutter_realtime_media_agora/Sources/flutter_realtime_media_agora/**/*.{h,m,mm}'
  s.public_header_files = 'flutter_realtime_media_agora/Sources/flutter_realtime_media_agora/include/FlutterRealtimeMediaAgoraPlugin.h'
  s.private_header_files = 'flutter_realtime_media_agora/Sources/flutter_realtime_media_agora/Realtime*.h', 'flutter_realtime_media_agora/Sources/flutter_realtime_media_agora/agora/**/*.h'
  s.dependency 'FlutterMacOS'
  s.dependency 'flutter_realtime_processed_video'
  s.frameworks = 'CoreVideo'
  s.platform = :osx, '12.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'HEADER_SEARCH_PATHS' => '"$(PODS_TARGET_SRCROOT)/flutter_realtime_media_agora/Sources/flutter_realtime_media_agora/agora"', 'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17' }
end
