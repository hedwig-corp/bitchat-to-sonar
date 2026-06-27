#!/usr/bin/env ruby
# Adds the SonarNotificationService app-extension target to bitchat.xcodeproj.
# Safe round-trip on objectVersion 90 verified; the array-form shellScript is
# converted to a string first so the xcodeproj gem can parse the project.
require 'xcodeproj'

PROJ = 'bitchat.xcodeproj'
PBX  = "#{PROJ}/project.pbxproj"
NSE_NAME = 'SonarNotificationService'
APP_TARGET = 'bitchat_iOS'
TEAM = 'ZQB239SHCM'
BREEZ_URL = 'https://github.com/breez/breez-sdk-liquid-swift'
BREEZ_VER = '0.12.4'

# 1) Make the objv90 array-form shellScript parseable by the gem (string form).
text = File.read(PBX)
if text.include?('shellScript = (')
  text = text.sub(/shellScript = \(\n(.*?)\n\t\t\t\);/m) do
    body = $1.split("\n").map { |l| l.strip.sub(/,\z/, '').gsub(/\A"/, '').gsub(/"\z/, '') }.join("\\n")
    "shellScript = \"#{body}\";"
  end
  File.write(PBX, text)
  puts '• converted array shellScript -> string'
end

project = Xcodeproj::Project.open(PROJ)
abort "NSE already exists" if project.targets.any? { |t| t.name == NSE_NAME }
app = project.targets.find { |t| t.name == APP_TARGET } or abort "no #{APP_TARGET}"

# 2) Create the app-extension target.
nse = project.new_target(:app_extension, NSE_NAME, :ios, '16.0', nil, :swift)
puts "• created target #{nse.name} (#{nse.product_type})"

# 3) Group + source file (paths are relative to the group, whose path is NSE_NAME).
grp = project.main_group.new_group(NSE_NAME, NSE_NAME)
src = grp.new_reference('NotificationService.swift')
grp.new_reference('Info.plist')
grp.new_reference("#{NSE_NAME}.entitlements")
nse.source_build_phase.add_file_reference(src)

# 4) Build settings on both configs.
nse.build_configurations.each do |c|
  s = c.build_settings
  s['PRODUCT_BUNDLE_IDENTIFIER'] = 'sh.hedwig.sonar.NotificationService'
  s['PRODUCT_NAME'] = '$(TARGET_NAME)'
  s['INFOPLIST_FILE'] = "#{NSE_NAME}/Info.plist"
  s['CODE_SIGN_ENTITLEMENTS'] = "#{NSE_NAME}/#{NSE_NAME}.entitlements"
  s['CODE_SIGN_STYLE'] = 'Automatic'
  s['DEVELOPMENT_TEAM'] = TEAM
  s['IPHONEOS_DEPLOYMENT_TARGET'] = '16.0'
  s['TARGETED_DEVICE_FAMILY'] = '1,2'
  s['SWIFT_VERSION'] = '5.0'
  s['GENERATE_INFOPLIST_FILE'] = 'NO'
  s['SKIP_INSTALL'] = 'YES'
  s['CLANG_ENABLE_MODULES'] = 'YES'
  s['SWIFT_EMIT_LOC_STRINGS'] = 'YES'
  s['CURRENT_PROJECT_VERSION'] = '1'
  s['MARKETING_VERSION'] = '1.0'
  s['ENABLE_USER_SCRIPT_SANDBOXING'] = 'NO'
end

# 5) Link BreezSDKLiquid (add the remote package + product dependency).
pkg = project.root_object.package_references.find do |r|
  r.respond_to?(:repositoryURL) && r.repositoryURL.to_s.include?('breez-sdk-liquid-swift')
end
unless pkg
  pkg = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
  pkg.repositoryURL = BREEZ_URL
  pkg.requirement = { 'kind' => 'exactVersion', 'version' => BREEZ_VER }
  project.root_object.package_references << pkg
  puts "• added remote package #{BREEZ_URL} @ #{BREEZ_VER}"
end
dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
dep.product_name = 'BreezSDKLiquid'
dep.package = pkg
nse.package_product_dependencies << dep
bf = project.new(Xcodeproj::Project::Object::PBXBuildFile)
bf.product_ref = dep
nse.frameworks_build_phase.files << bf
puts '• linked BreezSDKLiquid to NSE'

# 6) App depends on NSE + embeds it.
app.add_dependency(nse)
embed = app.copy_files_build_phases.find { |p| p.symbol_dst_subfolder_spec == :plug_ins } ||
        app.new_copy_files_build_phase('Embed Foundation Extensions').tap { |p| p.symbol_dst_subfolder_spec = :plug_ins }
appex_ref = nse.product_reference
ebf = embed.add_file_reference(appex_ref)
ebf.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
puts '• app depends on + embeds NSE'

project.save
puts "DONE: targets = #{project.targets.map(&:name).join(', ')}"
