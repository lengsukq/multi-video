Pod::Spec.new do |s|
  s.name = 'flutter_realtime_media_livekit'
  s.version = '0.1.0'
  s.summary = 'LiveKit native processed-video input.'
  s.description = s.summary
  s.homepage = 'https://github.com/lengsukq/multi-video'
  s.license = { :type => 'MIT' }
  s.author = { 'OnePlusDream' => 'developers@oneplusdream.com' }
  s.source = { :path => '.' }
  s.source_files = 'flutter_realtime_media_livekit/Sources/flutter_realtime_media_livekit/**/*'
  s.dependency 'FlutterMacOS'
  s.platform = :osx, '12.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
