Pod::Spec.new do |s|
  s.name = 'flutter_realtime_processed_video'
  s.version = '0.1.0'
  s.summary = 'Provider-neutral iOS processed-video frame hub.'
  s.description = s.summary
  s.homepage = 'https://github.com/lengsukq/multi-video'
  s.license = { :type => 'MIT' }
  s.author = { 'OnePlusDream' => 'developers@oneplusdream.com' }
  s.source = { :path => '.' }
  s.source_files = 'flutter_realtime_processed_video/Sources/flutter_realtime_processed_video/**/*.swift'
  s.dependency 'Flutter'
  s.frameworks = 'AVFoundation', 'CoreImage', 'CoreVideo', 'CoreMedia', 'ReplayKit'
  s.platform = :ios, '15.0'
  s.swift_version = '5.9'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
