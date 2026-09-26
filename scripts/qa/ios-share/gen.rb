# Generates QAShare.xcodeproj in the given build dir: the QA share host app
# (stands in for any third-party app that shares a document) plus the
# QAShareUITests bundle that drives the host, the Files app, the share sheet
# and the installed Sonar app. Kept out of ios/bitchat.xcodeproj on purpose:
# the app project stays untouched and nothing here ships.
#
#   ruby gen.rb <build dir>   (needs the xcodeproj gem, as ios/add_nse_target.rb)
require 'fileutils'
require 'xcodeproj'

src = File.expand_path(__dir__)
out = File.expand_path(ARGV.fetch(0))
FileUtils.mkdir_p(out)
%w[QAShareHost QAShareUITests].each do |d|
  FileUtils.rm_rf(File.join(out, d))
  FileUtils.cp_r(File.join(src, d), out)
end
Dir.chdir(out)
FileUtils.rm_rf('QAShare.xcodeproj')
proj = Xcodeproj::Project.new('QAShare.xcodeproj')
host = proj.new_target(:application, 'QAShareHost', :ios, '16.0')
uit = proj.new_target(:ui_test_bundle, 'QAShareUITests', :ios, '16.0')
host.add_file_references([proj.new_group('QAShareHost', 'QAShareHost').new_reference('QAShareHostApp.swift')])
uit.add_file_references([proj.new_group('QAShareUITests', 'QAShareUITests').new_reference('QAShareDriver.swift')])
uit.add_dependency(host)
common = {
  'SWIFT_VERSION' => '5.0', 'CODE_SIGN_IDENTITY' => '-', 'CODE_SIGN_STYLE' => 'Manual',
  'DEVELOPMENT_TEAM' => '', 'GENERATE_INFOPLIST_FILE' => 'YES', 'ARCHS' => 'arm64',
}
host.build_configurations.each do |c|
  c.build_settings.merge!(common)
  c.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'sh.hedwig.qasharehost'
  c.build_settings['INFOPLIST_KEY_UILaunchScreen_Generation'] = 'YES'
  c.build_settings['INFOPLIST_KEY_CFBundleDisplayName'] = 'QA Share Host'
end
uit.build_configurations.each do |c|
  c.build_settings.merge!(common)
  c.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'sh.hedwig.qashareuitests'
  c.build_settings['TEST_TARGET_NAME'] = 'QAShareHost'
end
proj.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(host)
scheme.add_test_target(uit)
scheme.set_launch_target(host)
scheme.save_as(proj.path, 'QAShare', true)
