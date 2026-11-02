Pod::Spec.new do |s|
  s.name = 'flutter_realtime_screen_annotation'
  s.version = '0.1.0'
  s.summary = 'SDK system annotation panels.'
  s.description = 'Provider-neutral system drawing windows for shared displays.'
  s.homepage = 'https://github.com/lengsukq/multi-video'
  s.license = { :type => 'MIT' }
  s.author = { 'Realtime SDK' => 'sdk@example.invalid' }
  s.source = { :path => '.' }
  s.source_files = 'flutter_realtime_screen_annotation/Sources/flutter_realtime_screen_annotation/**/*'
  s.dependency 'FlutterMacOS'
  s.platform = :osx, '10.14'
  s.frameworks = 'AppKit'
end
