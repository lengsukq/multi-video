#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint flutter_aws_chime.podspec` to validate before publishing.
#
disable_chime = ENV['FRSDK_IOS_DISABLE_CHIME'] == '1'

Pod::Spec.new do |s|
  s.name             = 'flutter_aws_chime'
  s.version          = '3.0.0'
  s.summary          = 'Flutter client package for Amazon Chime SDK meetings on iOS and Android.'
  s.description      = <<-DESC
A Flutter client package for Amazon Chime SDK meetings. Meeting creation and attendee credentials are provided by the application backend.
                       DESC
  s.homepage         = 'https://github.com/lengsukq/multi-video'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = { 'lengsukq' => 'liyijia428@gmail.com' }
  s.source           = { :git => 'https://github.com/lengsukq/multi-video.git', :tag => s.version.to_s }
  s.source_files     = disable_chime ? 'flutter_aws_chime/Sources/flutter_aws_chime/FlutterAwsChimePlugin.swift' : 'flutter_aws_chime/Sources/flutter_aws_chime/**/*.swift'
  s.dependency 'Flutter'
  s.platform = :ios, '15.0'
  s.static_framework = true

  # Allow hosts that also link standalone WebRTC/ARTC to omit Chime's bundled
  # WebRTC symbols via ENV['FRSDK_IOS_DISABLE_CHIME'] = '1' in ios/Podfile.
  s.dependency 'AmazonChimeSDK', '= 0.27.4' unless disable_chime
  s.dependency 'AmazonChimeSDKMedia', '= 0.25.4' unless disable_chime
  s.dependency 'AmazonChimeSDKMachineLearning', '= 0.3.3' unless disable_chime

  conditions = ['$(inherited)']
  conditions << 'FRSDK_DISABLE_CHIME' if disable_chime
  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS' => conditions.join(' '),
  }
  s.swift_version = '5.0'
end
