# Called explicitly from the application's post_integrate hook. This does not
# replace its own hooks or alter any vendor SDK's files or dependency versions.
module FlutterRealtimeSdk
  module PodfileIntegration
    # The CocoaPods-only host resolves both Agora RTC and Agora Chat.
    # AgoraInfra_iOS (1.3.5) and ShengwangInfra_iOS (1.3.16) each vendor
    # aosl.xcframework. CocoaPods rejects duplicate framework basenames.
    # Retain only the highest-version framework's vendored declaration.
    # Do not delete or replace either vendor binary.
    # This is invoked before CocoaPods validates duplicate framework names.
    def self.prepare_agora_infrastructure!(installer)
      pod_targets = installer.pod_targets
      agora = pod_targets.find { |target| target.pod_name == 'AgoraInfra_iOS' }
      shengwang = pod_targets.find { |target| target.pod_name == 'ShengwangInfra_iOS' }
      return unless agora && shengwang

      require 'rubygems/version'
      agora_version = Gem::Version.new(agora.specs.first.version.to_s)
      shengwang_version = Gem::Version.new(shengwang.specs.first.version.to_s)
      keep = agora_version > shengwang_version ? agora : shengwang
      omit = keep.equal?(agora) ? shengwang : agora
      omit.specs.each do |spec|
        spec.attributes_hash.delete('vendored_frameworks')
        spec.attributes_hash.delete('weak_frameworks')
      end
      Pod::UI.puts("flutter_realtime_sdk: use #{keep.pod_name} as the only aosl framework provider")
    end

    def self.deduplicate_agora_frameworks!(installer)
      ios = installer.config.installation_root.to_s
      package = File.join(ios, 'Flutter', 'ephemeral', 'Packages',
                          'FlutterGeneratedPluginSwiftPackage', 'Package.swift')
      # Chat alone needs its CocoaPods aosl. Remove its embed only when RTC's
      # SwiftPM product supplies aosl to this same app.
      return unless File.file?(package) && File.read(package).include?('name: "agora-rtc-engine"')

      support = File.join(installer.sandbox.root.to_s, 'Target Support Files')
      Dir.glob(File.join(support, 'Pods-*')).each do |target|
        scripts = Dir.glob(File.join(target, '*-frameworks.sh'))
        scripts.each do |script|
          next unless File.read(script).include?('/ShengwangInfra_iOS/aosl.framework')

          rewrite_without(script) { |line| line.include?('/ShengwangInfra_iOS/aosl.framework') }
          Dir.glob(File.join(target, '*-frameworks-*-input-files.xcfilelist')).each do |path|
            rewrite_without(path) { |line| line.include?('/ShengwangInfra_iOS/aosl.framework/') }
          end
          Dir.glob(File.join(target, '*-frameworks-*-output-files.xcfilelist')).each do |path|
            rewrite_without(path) do |line|
              line.strip == '${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}/aosl.framework'
            end
          end
        end
      end
    end

    def self.rewrite_without(path)
      original = File.read(path)
      modified = original.lines.reject { |line| yield(line) }.join
      File.write(path, modified) if modified != original
    end
  end
end
