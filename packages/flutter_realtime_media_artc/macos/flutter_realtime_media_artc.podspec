Pod::Spec.new do |s|
  s.name             = 'flutter_realtime_media_artc'
  s.version          = '0.1.0'
  s.summary          = 'Provider-neutral Flutter adapter for Alibaba Cloud ARTC on macOS.'
  s.description      = 'ARTC macOS bridge with runtime discovery of the official Alibaba Cloud framework.'
  s.homepage         = 'https://github.com/lengsukq/multi-video'
  s.license          = { :type => 'MIT' }
  s.author           = { 'OnePlusDream' => 'developers@oneplusdream.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'flutter_realtime_media_artc/Sources/flutter_realtime_media_artc/**/*'
  s.dependency 'FlutterMacOS'
  s.frameworks       = 'AVFoundation', 'AppKit'
  s.platform         = :osx, '12.0'
  s.static_framework = true

  bundled = Dir[File.join(__dir__, 'Frameworks', '*.framework')].map do |path|
    "Frameworks/#{File.basename(path)}"
  end
  s.vendored_frameworks = bundled unless bundled.empty?
end
