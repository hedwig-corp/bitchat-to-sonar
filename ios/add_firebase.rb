#!/usr/bin/env ruby
# Adds the firebase-ios-sdk SPM package and links FirebaseMessaging to bitchat_iOS.
# (The array-form shellScript was already string-fixed by add_nse_target.rb.)
require 'xcodeproj'

PROJ = 'bitchat.xcodeproj'
project = Xcodeproj::Project.open(PROJ)
app = project.targets.find { |t| t.name == 'bitchat_iOS' } or abort 'no bitchat_iOS'

if app.package_product_dependencies.any? { |d| d.product_name == 'FirebaseMessaging' }
  abort 'FirebaseMessaging already linked'
end

pkg = project.root_object.package_references.find do |r|
  r.respond_to?(:repositoryURL) && r.repositoryURL.to_s.include?('firebase-ios-sdk')
end
unless pkg
  pkg = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
  pkg.repositoryURL = 'https://github.com/firebase/firebase-ios-sdk.git'
  pkg.requirement = { 'kind' => 'upToNextMajorVersion', 'minimumVersion' => '11.0.0' }
  project.root_object.package_references << pkg
  puts '• added firebase-ios-sdk package (>= 11.0.0)'
end

dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
dep.product_name = 'FirebaseMessaging'
dep.package = pkg
app.package_product_dependencies << dep
bf = project.new(Xcodeproj::Project::Object::PBXBuildFile)
bf.product_ref = dep
app.frameworks_build_phase.files << bf
puts '• linked FirebaseMessaging to bitchat_iOS'

project.save
puts "DONE"
