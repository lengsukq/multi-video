#!/usr/bin/env ruby
# frozen_string_literal: true
# encoding: utf-8

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

# Install the native ReplayKit Upload Extension required by LiveKit's iOS
# cross-application screen capture. Run from the host Flutter project:
#   ruby /path/to/sdk/scripts/setup_ios_broadcast_extension.rb ios
# For a published SDK, use the copy under tool/ in the hosted package.
#
# Requires the xcodeproj Ruby gem (already installed with CocoaPods).
# The Apple Developer team must authorize the SAME App Group for both targets.
# This script is safe to run repeatedly and never runs pub.dev publish.
require 'fileutils'
require 'xcodeproj'

ios = File.expand_path(ARGV.fetch(0, 'ios'))
project_path = File.join(ios, 'Runner.xcodeproj')
abort "Missing Xcode project: #{project_path}" unless File.directory?(project_path)

source = File.expand_path('templates/ios_broadcast_extension', __dir__)
unless File.directory?(source)
  source = File.expand_path('../ios/BroadcastExtensionTemplate', __dir__)
end
abort "Missing ReplayKit template: #{source}" unless File.directory?(source)

project = Xcodeproj::Project.open(project_path)
app = project.targets.find { |target| target.name == 'Runner' }
abort 'Missing Runner target' unless app
config = app.build_configurations.find { |entry| entry.name == 'Debug' } ||
         app.build_configurations.first
bundle = ENV.fetch('IOS_BROADCAST_APP_BUNDLE', config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'].to_s)
abort 'Runner bundle identifier missing' if bundle.empty?
group = ENV.fetch('IOS_BROADCAST_APP_GROUP', "group.#{bundle}")
extension_bundle = ENV.fetch('IOS_BROADCAST_EXTENSION_BUNDLE', "#{bundle}.broadcast")
team = ENV.fetch('IOS_BROADCAST_DEVELOPMENT_TEAM', config.build_settings['DEVELOPMENT_TEAM'].to_s)

name = 'BroadcastUpload'
folder = File.join(ios, name)
FileUtils.mkdir_p(folder)
swift_files = %w[SampleHandler.swift SampleUploader.swift SocketConnection.swift DarwinNotificationCenter.swift Atomic.swift]
swift_files.each do |file|
  path = File.join(folder, file)
  FileUtils.cp(File.join(source, file), path) unless File.exist?(path)
end

extension_info = {
  'RTCAppGroupIdentifier' => group,
  'NSExtension' => {
    'NSExtensionPointIdentifier' => 'com.apple.broadcast-services-upload',
    'NSExtensionPrincipalClass' => '$(PRODUCT_MODULE_NAME).SampleHandler',
    'RPBroadcastProcessMode' => 'RPBroadcastProcessModeSampleBuffer'
  }
}
Xcodeproj::Plist.write_to_path(extension_info, File.join(folder, 'Info.plist'))

app_info_path = File.join(ios, 'Runner/Info.plist')
app_info = Xcodeproj::Plist.read_from_path(app_info_path)
app_info['RTCAppGroupIdentifier'] = group
app_info['RTCScreenSharingExtension'] = extension_bundle
# LiveKit's RTC transport must remain able to publish while Safari/WeChat is
# foregrounded. This is appropriate only while an actual RTC audio session
# is active; App Store reviewers will evaluate real background behavior.
background_modes = Array(app_info['UIBackgroundModes'])
background_modes << 'audio' unless background_modes.include?('audio')
app_info['UIBackgroundModes'] = background_modes
Xcodeproj::Plist.write_to_path(app_info, app_info_path)

entitlements = { 'com.apple.security.application-groups' => [group] }
app_entitlements = File.join(ios, 'Runner/Runner.entitlements')
extension_entitlements = File.join(folder, 'BroadcastUpload.entitlements')
[app_entitlements, extension_entitlements].each do |path|
  existing = File.exist?(path) ? Xcodeproj::Plist.read_from_path(path) : {}
  existing['com.apple.security.application-groups'] = [group]
  Xcodeproj::Plist.write_to_path(existing, path)
end

extension = project.targets.find { |target| target.name == name }
extension ||= project.new_target(:app_extension, name, :ios, '15.0')
group_ref = project.main_group.find_subpath(name, true)
group_ref.set_source_tree('<group>')
group_ref.set_path(name)
(swift_files + %w[Info.plist BroadcastUpload.entitlements]).each do |filename|
  ref = group_ref.files.find { |file| file.path == filename }
  ref ||= group_ref.new_file(filename)
  if filename.end_with?('.swift') &&
     !extension.source_build_phase.files_references.include?(ref)
    extension.source_build_phase.add_file_reference(ref)
  end
end

app.build_configurations.each do |build|
  build.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'Runner/Runner.entitlements'
end
extension.build_configurations.each do |build|
  settings = build.build_settings
  settings['PRODUCT_BUNDLE_IDENTIFIER'] = extension_bundle
  settings['CODE_SIGN_ENTITLEMENTS'] = "#{name}/BroadcastUpload.entitlements"
  settings['DEVELOPMENT_TEAM'] = team unless team.empty?
  settings['CODE_SIGN_STYLE'] = 'Automatic'
  settings['SWIFT_VERSION'] = '5.0'
  settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
  settings['TARGETED_DEVICE_FAMILY'] = '1,2'
  settings['INFOPLIST_FILE'] = "#{name}/Info.plist"
  settings['GENERATE_INFOPLIST_FILE'] = 'YES'
  settings['APPLICATION_EXTENSION_API_ONLY'] = 'YES'
  settings['SKIP_INSTALL'] = 'YES'
  settings['PRODUCT_NAME'] = '$(TARGET_NAME)'
  settings['LD_RUNPATH_SEARCH_PATHS'] = ['$(inherited)', '@executable_path/Frameworks', '@executable_path/../../Frameworks']
end

project.root_object.attributes['TargetAttributes'] ||= {}
project.root_object.attributes['TargetAttributes'][extension.uuid] ||= {}
project.root_object.attributes['TargetAttributes'][extension.uuid]['ProvisioningStyle'] = 'Automatic'
project.root_object.attributes['TargetAttributes'][extension.uuid]['DevelopmentTeam'] = team unless team.empty?

unless app.dependencies.any? { |dep| dep.target == extension }
  app.add_dependency(extension)
end
embed_phase = app.build_phases.find { |phase| phase.respond_to?(:name) && phase.name == 'Embed App Extensions' }
unless embed_phase
  embed_phase = project.new(Xcodeproj::Project::Object::PBXCopyFilesBuildPhase)
  embed_phase.name = 'Embed App Extensions'
  embed_phase.dst_subfolder_spec = '13'
  app.build_phases << embed_phase
end
unless embed_phase.files_references.include?(extension.product_reference)
  file = embed_phase.add_file_reference(extension.product_reference, true)
  file.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
end

# Flutter's Thin Binary script and CocoaPods embed scripts both touch
# Runner.app. Xcode's new build system detects a dependency cycle if
# extension embedding is appended after them; position the copy phase before
# Thin Binary, as in Xcode's own Broadcast Upload Extension template.
phases = app.build_phases
phases.delete(embed_phase)
thin_index = phases.index { |phase| phase.respond_to?(:name) && phase.name == 'Thin Binary' }
phases.insert(thin_index || phases.length, embed_phase)

project.save
puts "Installed #{name}.appex (#{extension_bundle}) into #{project_path}"
puts "App Group: #{group}; signing team: #{team.empty? ? '(not configured)' : team}"
puts 'Register the App Group and extension bundle in Apple Developer, then verify both provisioning profiles.'
