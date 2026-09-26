# Generates QADriver.xcodeproj next to the given output dir: a stub host app
# (UI-test bundles need one) plus the QADriverUITests bundle, which drives the
# installed Sonar app by bundle id. Kept out of ios/bitchat.xcodeproj on
# purpose: the app project stays untouched and nothing here ships.
#
#   ruby gen.rb <build dir>   (needs the xcodeproj gem, as ios/add_nse_target.rb)
require 'fileutils'
require 'xcodeproj'

src = File.expand_path(__dir__)
out = File.expand_path(ARGV.fetch(0))
FileUtils.mkdir_p(out)
%w[QAHost QADriverUITests].each do |d|
  FileUtils.rm_rf(File.join(out, d))
  FileUtils.cp_r(File.join(src, d), out)
end
Dir.chdir(out)
FileUtils.rm_rf('QADriver.xcodeproj')
proj = Xcodeproj::Project.new('QADriver.xcodeproj')
app = proj.new_target(:application, 'QAHost', :ios, '16.0')
uit = proj.new_target(:ui_test_bundle, 'QADriverUITests', :ios, '16.0')
app.add_file_references([proj.new_group('QAHost', 'QAHost').new_reference('QAHostApp.swift')])
uit.add_file_references([proj.new_group('QADriverUITests', 'QADriverUITests').new_reference('QADriver.swift')])
uit.add_dependency(app)
common = {
  'SWIFT_VERSION' => '5.0', 'CODE_SIGN_IDENTITY' => '-', 'CODE_SIGN_STYLE' => 'Manual',
  'DEVELOPMENT_TEAM' => '', 'GENERATE_INFOPLIST_FILE' => 'YES', 'ARCHS' => 'arm64',
}
app.build_configurations.each do |c|
  c.build_settings.merge!(common)
  c.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'sh.hedwig.qahost'
  c.build_settings['INFOPLIST_KEY_UILaunchScreen_Generation'] = 'YES'
end
uit.build_configurations.each do |c|
  c.build_settings.merge!(common)
  c.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'sh.hedwig.qadriver'
  c.build_settings['TEST_TARGET_NAME'] = 'QAHost'
end
proj.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.add_test_target(uit)
scheme.set_launch_target(app)
scheme.save_as(proj.path, 'QADriver', true)
